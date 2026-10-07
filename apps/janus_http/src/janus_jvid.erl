%%%-------------------------------------------------------------------
%%% @doc Stateless self-routing video job id codec (spec A5 / M3.1).
%%%
%%% External id layout:
%%%
%%%   jvid_v1.<upstream_job_id>.<provider_id>.<listing>.<agent_key_id>.
%%%   <exp_unix>.<keyid>.<hmac16>
%%%
%%% EVERY segment after the literal `jvid_v1.` prefix is base64url
%%% (RFC 4648 §5, no padding), so upstream job ids and listing names
%%% that contain dots, slashes or underscores (`ZHIPU/GLM-5.3-FlashX`,
%%% dashscope `job.001_x`) survive verbatim and the dot-anchored parse
%%% is unambiguous. `hmac16` = base64url(HMAC-SHA256(secret, Prefix)
%%% truncated to 16 raw bytes) where Prefix is the id's UTF-8 bytes up
%%% to — but excluding — the final dot: the VERBATIM wire bytes, never
%%% re-encoded.
%%%
%%% Verification order: format (prefix/segment count/base64url/integer
%%% exp) -> HMAC -> keyid -> expiry. No step may raise (all decode and
%%% integer parsing is caught); fail-closed on every error.
%%%
%%% Secret: settings-driven via persistent_term `{janus, jvid_secret}`
%%% (a non-empty binary). DEVIATION from spec M3.1b (documented): the
%%% single-writer leader bootstrap is deferred to the follow-up — when
%%% the key is ABSENT the codec mints ONE deterministic dev secret
%%% derived from the node cookie (idempotent persistent_term put, so
%%% every node of a v1 deployment sharing the cookie verifies ids
%%% identically; local single-node E2E is the target). An EXPLICITLY
%%% set but invalid value (non-binary / empty) fails CLOSED with
%%% `{error, no_secret}` — it is never minted over and never accepted.
%%%
%%% v1 keyid is the constant <<"k0">>; dual-key rotation (M3.1b) lands
%%% with the leader bootstrap. Correctly-signed ids carrying any other
%%% keyid answer `{error, unknown_keyid}`.
%%%
%%% encode/5 returns the COMPLETE external id (the `jvid_v1.` prefix
%%% included — callers never concatenate it themselves); parse/1
%%% accepts exactly that form.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_jvid).

-export([
    encode/5,
    parse/1,
    secret/0,
    b64url_encode/1,
    b64url_decode/1
]).

-define(PREFIX, <<"jvid_v1.">>).
-define(SEGMENT_COUNT, 7).
-define(KEYID, <<"k0">>).
-define(PT_SECRET, {janus, jvid_secret}).
-define(HMAC_BYTES, 16).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------

%% UpstreamId/Listing are binaries; ProviderId/AgentKeyId are the
%% catalog's integers or binaries (normalized); ExpUnix is a unix
%% second. Returns {ok, CompleteIdBinary} — never a partial id.
-spec encode(binary(), integer() | binary(), binary(), integer() | binary(), integer()) ->
    {ok, binary()} | {error, no_secret | bad_args}.
encode(UpstreamId, ProviderId, Listing, AgentKeyId, ExpUnix) when
    is_binary(UpstreamId),
    is_binary(Listing),
    is_integer(ExpUnix),
    ExpUnix > 0
->
    case secret() of
        {ok, Sec} ->
            Segs = [
                b64url_encode(UpstreamId),
                b64url_encode(to_bin(ProviderId)),
                b64url_encode(Listing),
                b64url_encode(to_bin(AgentKeyId)),
                b64url_encode(integer_to_binary(ExpUnix)),
                b64url_encode(?KEYID)
            ],
            Prefix = iolist_to_binary([?PREFIX | intersperse(Segs)]),
            Mac = hmac16(Sec, Prefix),
            {ok, <<Prefix/binary, ".", Mac/binary>>};
        {error, _} = Err ->
            Err
    end;
encode(_, _, _, _, _) ->
    {error, bad_args}.

%% Fail-closed parse: format (prefix/segment count/base64url) -> HMAC
%% -> exp integer -> keyid -> expiry, in that order — the signature is
%% checked BEFORE the payload is interpreted, so every tampered id
%% (byte-flip or decode-modify-reencode, ANY segment) uniformly answers
%% bad_hmac. Never raises on any input.
-spec parse(term()) ->
    {ok, #{
        upstream_id := binary(),
        provider_id := binary(),
        listing := binary(),
        agent_key_id := binary(),
        exp := integer(),
        keyid := binary()
    }}
    | {error, bad_format | bad_hmac | unknown_keyid | job_expired | no_secret}.
parse(Id) when is_binary(Id), byte_size(Id) > byte_size(?PREFIX) ->
    PrefixLen = byte_size(?PREFIX),
    case Id of
        <<Prefix:PrefixLen/binary, Rest/binary>> when Prefix =:= ?PREFIX ->
            case binary:split(Rest, <<".">>, [global]) of
                Segs when length(Segs) =:= ?SEGMENT_COUNT ->
                    verify(Id, Segs);
                _ ->
                    {error, bad_format}
            end;
        _ ->
            {error, bad_format}
    end;
parse(_) ->
    {error, bad_format}.

secret() ->
    case persistent_term:get(?PT_SECRET, undefined) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            {ok, Bin};
        undefined ->
            case dev_secret() of
                undefined ->
                    %% Fail closed — no silent predictable signing key
                    %% (ocr high: cookie-derived mint was forgeable).
                    {error, no_secret};
                Dev ->
                    persistent_term:put(?PT_SECRET, Dev),
                    {ok, Dev}
            end;
        _ ->
            {error, no_secret}
    end.

%%%-------------------------------------------------------------------
%%% base64url (RFC 4648 §5, no padding) — non-raising decode
%%%-------------------------------------------------------------------

-spec b64url_encode(binary()) -> binary().
b64url_encode(Bin) when is_binary(Bin) ->
    base64:encode(Bin, #{padding => false, mode => urlsafe}).

-spec b64url_decode(binary()) -> {ok, binary()} | {error, bad_b64}.
b64url_decode(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try
        {ok, base64:decode(Bin, #{padding => false, mode => urlsafe})}
    catch
        _:_ -> {error, bad_b64}
    end;
b64url_decode(_) ->
    {error, bad_b64}.

%%%-------------------------------------------------------------------
%%% Internals
%%%-------------------------------------------------------------------

verify(Id, [UpSeg, PidSeg, ListSeg, AkeySeg, ExpSeg, KeySeg, HmacSeg]) ->
    case [b64url_decode(S) || S <- [UpSeg, PidSeg, ListSeg, AkeySeg, ExpSeg, KeySeg]] of
        [{ok, Up}, {ok, Pid}, {ok, List}, {ok, Akey}, {ok, ExpB}, {ok, Key}] ->
            check_hmac(Id, HmacSeg, {Up, Pid, List, Akey, ExpB, Key});
        _ ->
            {error, bad_format}
    end.

check_hmac(Id, HmacSeg, {Up, Pid, List, Akey, ExpB, Key}) ->
    %% HMAC over the verbatim wire bytes of everything before the
    %% final dot (the raw hmac segment is the tail after that dot).
    PrefixLen = byte_size(Id) - byte_size(HmacSeg) - 1,
    Prefix = binary:part(Id, 0, PrefixLen),
    case secret() of
        {ok, Sec} ->
            case crypto:hash_equals(hmac16(Sec, Prefix), HmacSeg) of
                true ->
                    check_exp({Up, Pid, List, Akey, ExpB, Key});
                false ->
                    {error, bad_hmac}
            end;
        {error, _} = Err ->
            Err
    end.

check_exp({Up, Pid, List, Akey, ExpB, Key}) ->
    case catch binary_to_integer(ExpB) of
        Exp when is_integer(Exp), Exp > 0 ->
            check_keyid({Up, Pid, List, Akey, Exp, Key});
        _ ->
            {error, bad_format}
    end.

check_keyid({Up, Pid, List, Akey, Exp, Key}) ->
    case Key of
        ?KEYID ->
            check_expiry({Up, Pid, List, Akey, Exp, Key});
        _ ->
            {error, unknown_keyid}
    end.

check_expiry({Up, Pid, List, Akey, Exp, Key}) ->
    case Exp =< erlang:system_time(second) of
        true ->
            {error, job_expired};
        false ->
            {ok, #{
                upstream_id => Up,
                provider_id => Pid,
                listing => List,
                agent_key_id => Akey,
                exp => Exp,
                keyid => Key
            }}
    end.

hmac16(Secret, Prefix) ->
    Mac = crypto:mac(hmac, sha256, Secret, Prefix),
    b64url_encode(binary:part(Mac, 0, ?HMAC_BYTES)).

%% Deterministic per-release dev secret: every node sharing the
%% distributed cookie mints the same bytes, so v1 ids verify
%% cross-node without the leader bootstrap.
%% ocr hardening: a node running with the default 'nocookie' made the
%% cookie-derived dev secret predictable (forgeable jvids). Mint only
%% behind an explicit opt-in env; otherwise the caller fails closed.
dev_secret() ->
    case os:getenv("JANUS_JVID_DEV_SECRET") of
        "1" ->
            logger:warning(#{
                what => janus_jvid_dev_secret,
                note => <<"cookie-derived jvid secret — opt-in, local E2E only">>
            }),
            Cookie = atom_to_binary(erlang:get_cookie(), utf8),
            b64url_encode(crypto:hash(sha256, <<"janus-jvid-dev-v1:", Cookie/binary>>));
        _ ->
            undefined
    end.

to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(B) when is_binary(B) -> B.

intersperse([S]) -> [S];
intersperse([S | Rest]) -> [S, <<".">> | intersperse(Rest)];
intersperse([]) -> [].
