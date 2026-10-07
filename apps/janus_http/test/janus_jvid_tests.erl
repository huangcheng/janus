%%%-------------------------------------------------------------------
%%% @doc EUnit for the stateless video job id codec (spec A5/M3.1).
%%%
%%% Written BEFORE the implementation (AGENTS.md rule 1). Fixtures are
%%% production shapes: upstream job ids and listing names carry the
%%% dots/slashes/underscores real catalogs ship (`ZHIPU/GLM-5.3-FlashX`,
%%% dashscope `job.001_x`-style ids), provider/agent-key ids are the
%%% Postgres BIGINT integers the catalog ETS hands out, and the secret
%%% rides persistent_term exactly like the settings distribution
%%% writes it. Every tamper case decodes a segment, MUTATES the value
%%% and re-encodes — the naive byte-flip variant keeps encoding length,
%%% the re-encode variant does not.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_jvid_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PT_SECRET, {janus, jvid_secret}).
-define(TEST_SECRET, <<"gate-test-secret-0123456789abcdef">>).

%%%-------------------------------------------------------------------
%%% Setup: snapshot + isolate the persistent_term secret per test
%%%-------------------------------------------------------------------

jvid_test_() ->
    {foreach,
        fun() ->
            Save = persistent_term:get(?PT_SECRET, '$unset'),
            persistent_term:erase(?PT_SECRET),
            Save
        end,
        fun(Save) ->
            case Save of
                '$unset' -> persistent_term:erase(?PT_SECRET);
                _ -> persistent_term:put(?PT_SECRET, Save)
            end
        end,
        [fun roundtrip_dot_bearing_ids_test/0,
         fun roundtrip_binary_ids_test/0,
         fun encode_shape_test/0,
         {timeout, 10, fun fresh_node_dev_secret_roundtrip_test/0},
         fun dev_secret_deterministic_test/0,
         fun explicit_secret_used_verbatim_test/0,
         fun invalid_secret_fails_closed_test/0,
         fun tamper_each_segment_reencoded_test/0,
         fun tamper_each_segment_byte_flip_test/0,
         fun expiry_test/0,
         fun unknown_keyid_test/0,
         fun bad_prefix_test/0,
         fun bad_segment_count_test/0,
         fun trailing_empty_segment_test/0,
         fun bad_b64_chars_test/0,
         fun non_integer_exp_test/0,
         fun parse_non_binary_test/0]}.

%%%-------------------------------------------------------------------
%%% Roundtrip
%%%-------------------------------------------------------------------

roundtrip_dot_bearing_ids_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    UpId = <<"job.001_x/wan2.5-t2v">>,
    Listing = <<"ZHIPU/GLM-5.3-FlashX">>,
    Exp = exp_future(),
    {ok, Id} = janus_jvid:encode(UpId, 17, Listing, 42, Exp),
    {ok, Parsed} = janus_jvid:parse(Id),
    ?assertEqual(
        #{
            upstream_id => UpId,
            provider_id => <<"17">>,
            listing => Listing,
            agent_key_id => <<"42">>,
            exp => Exp,
            keyid => <<"k0">>
        },
        Parsed
    ).

%% Binary-valued provider/agent-key ids roundtrip verbatim too (the
%% codec never assumes the id is an integer).
roundtrip_binary_ids_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"u">>, <<"pg-east">>, <<"seedance-pro">>, <<"k_9">>, exp_future()),
    ?assertMatch(
        {ok, #{provider_id := <<"pg-east">>, agent_key_id := <<"k_9">>}},
        janus_jvid:parse(Id)
    ).

encode_shape_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"u1">>, 1, <<"m">>, 2, exp_future()),
    ?assertMatch(<<"jvid_v1.", _/binary>>, Id),
    <<"jvid_v1.", Rest/binary>> = Id,
    ?assertEqual(7, length(binary:split(Rest, <<".">>, [global]))),
    %% The raw id contains ONLY base64url alphabet between the dots —
    %% no plus, slash, equals, and no literal dots inside a segment.
    ?assertEqual(nomatch, binary:match(Rest, [<<"+">>, <<"/">>, <<"=">>])).

%%%-------------------------------------------------------------------
%%% Secret lifecycle (v1 deviation: cookie-derived dev mint)
%%%-------------------------------------------------------------------

%% A "fresh node" has no secret: encode mints the deterministic dev
%% secret, a second fresh node mints the SAME one (node cookie is
%% shared inside a release) and verifies the id.
with_dev_secret(F) ->
    os:putenv("JANUS_JVID_DEV_SECRET", "1"),
    persistent_term:erase({janus, jvid_secret_placeholder_for_test}),
    try
        F()
    after
        os:unsetenv("JANUS_JVID_DEV_SECRET")
    end.

fresh_node_dev_secret_roundtrip_test() ->
    with_dev_secret(fun() ->
        persistent_term:erase(?PT_SECRET),
        {ok, Id} = janus_jvid:encode(<<"u1">>, 1, <<"m">>, 2, exp_future()),
        persistent_term:erase(?PT_SECRET),
        ?assertMatch({ok, #{upstream_id := <<"u1">>}}, janus_jvid:parse(Id))
    end).

dev_secret_deterministic_test() ->
    with_dev_secret(fun() ->
        persistent_term:erase(?PT_SECRET),
        {ok, A} = janus_jvid:secret(),
        ?assert(is_binary(A) andalso byte_size(A) > 0),
        persistent_term:erase(?PT_SECRET),
        {ok, B} = janus_jvid:secret(),
        ?assertEqual(A, B),
        %% Minting puts the value: the second read must not recompute.
        ?assertEqual({ok, A}, janus_jvid:secret())
    end).

%% ocr hardening: with the dev opt-in ABSENT the codec fails closed.
no_secret_fails_closed_test() ->
    os:unsetenv("JANUS_JVID_DEV_SECRET"),
    persistent_term:erase(?PT_SECRET),
    ?assertEqual({error, no_secret}, janus_jvid:secret()).

explicit_secret_used_verbatim_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    ?assertEqual({ok, ?TEST_SECRET}, janus_jvid:secret()).

%% An explicitly-set but invalid secret fails CLOSED on both faces —
%% never minted over, never accepted.
invalid_secret_fails_closed_test() ->
    persistent_term:put(?PT_SECRET, 12345),
    ?assertEqual({error, no_secret}, janus_jvid:secret()),
    ?assertEqual(
        {error, no_secret},
        janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, exp_future())
    ),
    persistent_term:put(?PT_SECRET, <<>>),
    ?assertEqual({error, no_secret}, janus_jvid:secret()).

%%%-------------------------------------------------------------------
%%% Tamper — each segment decode-modify-reencoded AND byte-flipped
%%% (same length). The 7th segment IS the hmac itself: mutating it
%%% must fail too.
%%%-------------------------------------------------------------------

tamper_each_segment_reencoded_test() ->
    with_secret_tamper(fun mutate_decoded_value/1).

tamper_each_segment_byte_flip_test() ->
    with_secret_tamper(fun flip_first_char/1).

with_secret_tamper(Mut) ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"job.001_x">>, 7, <<"ZHIPU/GLM-5.3-FlashX">>, 42, exp_future()),
    <<"jvid_v1.", Rest/binary>> = Id,
    Segs = binary:split(Rest, <<".">>, [global]),
    ?assertEqual(7, length(Segs)),
    [
        begin
            Tampered = replace_nth(Segs, I, Mut(Seg)),
            ?assertEqual(
                {error, bad_hmac},
                janus_jvid:parse(rebuild(Tampered)),
                {segment, I, Mut}
            )
        end
     || {I, Seg} <- indexed(Segs)
    ].

%%%-------------------------------------------------------------------
%%% Expiry
%%%-------------------------------------------------------------------

expiry_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Past} = janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, exp_past()),
    ?assertEqual({error, job_expired}, janus_jvid:parse(Past)),
    Exp = exp_future(),
    {ok, Future} = janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, Exp),
    ?assertMatch({ok, #{exp := Exp}}, janus_jvid:parse(Future)).

%%%-------------------------------------------------------------------
%%% Unknown keyid (v1: only k0 exists; rotation lands with M3.1b)
%%%-------------------------------------------------------------------

unknown_keyid_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    Segs = [
        janus_jvid:b64url_encode(<<"u1">>),
        janus_jvid:b64url_encode(<<"1">>),
        janus_jvid:b64url_encode(<<"m">>),
        janus_jvid:b64url_encode(<<"2">>),
        janus_jvid:b64url_encode(integer_to_binary(exp_future())),
        janus_jvid:b64url_encode(<<"k9">>)
    ],
    Prefix = rebuild(Segs),
    Mac = hmac16(?TEST_SECRET, Prefix),
    ?assertEqual({error, unknown_keyid}, janus_jvid:parse(<<Prefix/binary, ".", Mac/binary>>)),
    %% The k0 twin with the correctly computed hmac verifies.
    K0 = sub_all(<<"k9">>, <<"k0">>, Segs, [fun janus_jvid:b64url_encode/1]),
    Prefix0 = rebuild(K0),
    Mac0 = hmac16(?TEST_SECRET, Prefix0),
    ?assertMatch({ok, _}, janus_jvid:parse(<<Prefix0/binary, ".", Mac0/binary>>)).

%%%-------------------------------------------------------------------
%%% Malformed ids (never a crash)
%%%-------------------------------------------------------------------

bad_prefix_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, exp_future()),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<"jvid_v2.", Id/binary>>)),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<"v1.", Id/binary>>)),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<"jvid_v1">>)),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<>>)).

bad_segment_count_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, exp_future()),
    <<"jvid_v1.", Rest/binary>> = Id,
    Six = lists:droplast(binary:split(Rest, <<".">>, [global])),
    ?assertEqual({error, bad_format}, janus_jvid:parse(rebuild_raw(Six))),
    Eight = [<<"dXU">> | binary:split(Rest, <<".">>, [global])],
    ?assertEqual({error, bad_format}, janus_jvid:parse(rebuild_raw(Eight))).

trailing_empty_segment_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    {ok, Id} = janus_jvid:encode(<<"u">>, 1, <<"m">>, 2, exp_future()),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<Id/binary, ".">>)).

bad_b64_chars_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    %% Standard-alphabet and padding bytes are invalid in urlsafe
    %% no-padding segments; the codec must answer, not raise.
    ?assertEqual({error, bad_b64}, janus_jvid:b64url_decode(<<"ab+d">>)),
    ?assertEqual({error, bad_b64}, janus_jvid:b64url_decode(<<"ab/d">>)),
    ?assertEqual({error, bad_b64}, janus_jvid:b64url_decode(<<"abcd=">>)),
    ?assertEqual({error, bad_b64}, janus_jvid:b64url_decode(<<"a">>)),
    ?assertEqual({ok, <<"ab">>}, janus_jvid:b64url_decode(<<"YWI">>)).

non_integer_exp_test() ->
    persistent_term:put(?PT_SECRET, ?TEST_SECRET),
    Segs = [
        janus_jvid:b64url_encode(<<"u1">>),
        janus_jvid:b64url_encode(<<"1">>),
        janus_jvid:b64url_encode(<<"m">>),
        janus_jvid:b64url_encode(<<"2">>),
        janus_jvid:b64url_encode(<<"not-a-number">>),
        janus_jvid:b64url_encode(<<"k0">>)
    ],
    Prefix = rebuild(Segs),
    Mac = hmac16(?TEST_SECRET, Prefix),
    ?assertEqual({error, bad_format}, janus_jvid:parse(<<Prefix/binary, ".", Mac/binary>>)).

parse_non_binary_test() ->
    ?assertEqual({error, bad_format}, janus_jvid:parse(atom)),
    ?assertEqual({error, bad_format}, janus_jvid:parse(42)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

exp_future() ->
    erlang:system_time(second) + 3600.

exp_past() ->
    erlang:system_time(second) - 3600.

indexed(List) ->
    lists:zip(lists:seq(1, length(List)), List).

replace_nth([_ | Rest], 1, V) -> [V | Rest];
replace_nth([H | T], N, V) -> [H | replace_nth(T, N - 1, V)].

%% Replace every segment whose ENCODED form encodes From with one
%% encoding To (used to swap the keyid segment k9 -> k0).
sub_all(From, To, Segs, [Enc]) ->
    Want = Enc(From),
    New = Enc(To),
    [case Seg of Want -> New; S -> S end || Seg <- Segs].

rebuild(Segs) ->
    rebuild_raw(Segs).

rebuild_raw(Segs) ->
    iolist_to_binary([<<"jvid_v1.">> | intersperse_dots(Segs)]).

intersperse_dots([S]) -> [S];
intersperse_dots([S | Rest]) -> [S, <<".">> | intersperse_dots(Rest)];
intersperse_dots([]) -> [].

%% Decode-modify-reencode: the mutated value re-encodes to a possibly
%% different length — the HMAC covers the verbatim prefix bytes, so any
%% change fails.
mutate_decoded_value(Seg) ->
    {ok, Bin} = janus_jvid:b64url_decode(Seg),
    First = binary:at(Bin, 0),
    MutFirst = <<((First rem 255) + 1)>>,
    NewBin = <<MutFirst/binary, (binary:part(Bin, 1, byte_size(Bin) - 1))/binary>>,
    janus_jvid:b64url_encode(NewBin).

%% Naive byte flip on the ENCODED segment: same length, valid alphabet.
flip_first_char(Seg) ->
    First = binary:at(Seg, 0),
    Flipped =
        case First of
            $a -> $b;
            _ -> $a
        end,
    <<Flipped, (binary:part(Seg, 1, byte_size(Seg) - 1))/binary>>.

%% The hmac16 layout computed independently of the codec (shared
%% layout check: HMAC-SHA256 over the verbatim prefix, 16 raw bytes,
%% base64url no padding).
hmac16(Secret, Prefix) ->
    Mac = crypto:mac(hmac, sha256, Secret, Prefix),
    janus_jvid:b64url_encode(binary:part(Mac, 0, 16)).
