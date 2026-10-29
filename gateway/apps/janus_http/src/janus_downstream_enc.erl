%%%-------------------------------------------------------------------
%%% @doc Downstream REST JSON gzip reply helper (spec
%%% 2026-10-12-wire-compression G3/F6/D8 — PR3; maturity batch H2).
%%%
%%% The ONE choke point every unary (non-stream) client reply goes
%%% through. /v1/chat/completions, /v1/responses, /v1/messages (and
%%% /v1/decisions) serve stream AND non-stream from a single route —
%%% the `stream' body flag decides at runtime — so a per-ROUTE Cowboy
%%% compress option would capture SSE (F6's original finding; Cowboy
%%% 2.12 offers no per-reply compress flag anyway). The pinned
%%% mechanism is therefore MANUAL gzip at the reply site, where
%%% non-stream is already known. Streaming replies
%%% (cowboy_req:stream_reply) NEVER pass through this module, and the
%%% :8090 admin plane never calls it (D8).
%%%
%%% Compression happens only when janus_wire_enc:downstream_gzip_decide/3
%%% says so (gate JANUS_DOWNSTREAM_ENC default off, RFC 7231
%%% Accept-Encoding q-value selection, content-type in
%%% {application/json, text/*} \ {text/event-stream}, body >=
%%% JANUS_WIRE_ENC_MIN_BYTES). On gzip: zlib:gzip/1 (RFC 1952),
%%% `Content-Encoding: gzip', and Cowboy computes Content-Length from
%%% the compressed body we hand it (a stale identity length is
%%% impossible by construction). Identity fallback — never expands,
%%% never 500s: gate off / client not selecting / SSE or binary
%%% content type / below threshold / gzip not strictly smaller / zlib
%%% error. `Vary: Accept-Encoding' rides every NEGOTIABLE reply (gate
%%% on + compressible type + above threshold), not only the actually
%%% gzipped one (RFC 7231 §7.1.4): the identity reply a non-gzip
%%% client gets is a different representation of the same URL, and a
%%% cache must not replay one for the other (ocr review).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_downstream_enc).

%% The reply seam: unary reply sites swap cowboy_req:reply/4 for this.
-export([reply/4]).
%% The header/body transform (eunit seam; reply/4 reads the client's
%% Accept-Encoding header and calls this).
-export([maybe_gzip/3]).

%% The unary reply seam (F6/D8). Status and Req pass through
%% untouched; only the header map and body can transform.
-spec reply(cowboy:http_status(), map(), binary(), cowboy_req:req()) ->
    cowboy_req:req().
reply(Status, Headers, Body, Req) when is_map(Headers), is_binary(Body) ->
    AE = cowboy_req:header(<<"accept-encoding">>, Req),
    {Headers2, Body2} = maybe_gzip(AE, Headers, Body),
    cowboy_req:reply(Status, Headers2, Body2, Req);
reply(Status, Headers, Body, Req) ->
    cowboy_req:reply(Status, Headers, Body, Req).

%% Pure-ish transform (the only effect is a warning log on zlib
%% failure): returns the headers+body to reply with.
-spec maybe_gzip(undefined | binary(), map(), binary()) -> {map(), binary()}.
maybe_gzip(AE, Headers, Body) when is_map(Headers), is_binary(Body) ->
    Ct = maps:get(<<"content-type">>, Headers, undefined),
    case janus_wire_enc:downstream_gzip_decide(AE, Ct, byte_size(Body)) of
        gzip ->
            try zlib:gzip(Body) of
                Gz when byte_size(Gz) < byte_size(Body) ->
                    %% Drop any caller-supplied content-length with the
                    %% body it described: Cowboy derives Content-Length
                    %% only when absent, so a stale identity length
                    %% would be advertised alongside gzip bytes (client
                    %% truncation). No current caller sends one — the
                    %% seam enforces the invariant locally instead of
                    %% relying on caller discipline (ocr review).
                    H1 = maps:remove(<<"content-length">>, Headers),
                    {vary_accept_encoding(H1#{<<"content-encoding">> => <<"gzip">>}), Gz};
                _WouldExpand ->
                    %% No expansion on the wire (the PR1 codec rule):
                    %% an incompressible body above the threshold
                    %% stays identity rather than growing every reply.
                    %% Still a negotiable URL — Vary stays attached.
                    {vary_accept_encoding(Headers), Body}
            catch
                Class:Reason ->
                    %% Never 500 a reply over a transport encoding: a
                    %% failing zlib port degrades to identity (the
                    %% D7 worker-side precedent). Still negotiable.
                    warn_once(#{
                        what => janus_downstream_gzip_failed,
                        class => Class,
                        reason => Reason
                    }),
                    {vary_accept_encoding(Headers), Body}
            end;
        identity ->
            %% An identity reply to a non-gzip (or below-threshold)
            %% client is still a representation that varies with
            %% Accept-Encoding whenever the gate would compress —
            %% attach Vary on the negotiable paths only, so the
            %% knob-off default stays byte-identical to today.
            case janus_wire_enc:downstream_enc_negotiable(Ct, byte_size(Body)) of
                true -> {vary_accept_encoding(Headers), Body};
                false -> {Headers, Body}
            end
    end;
maybe_gzip(_AE, Headers, Body) ->
    %% Non-binary body (callers today always pass binaries; iolists
    %% would need a size+rebuild) or a non-map header term: pass
    %% through untouched rather than guessing.
    {Headers, Body}.

%% Vary: Accept-Encoding — APPEND to an existing Vary (replacing it
%% would un-cache every other varying dimension), never duplicate the
%% token when it is already there. The existing value is REBUILT from
%% its parsed, non-empty comma tokens before the append (ocr r4: a
%% trailing comma in the incoming value must not leak a double comma)
%% and the RFC 9110 special form `Vary: *' stands ALONE — appending to
%% it would produce a value outside the grammar, and `*' already
%% subsumes Accept-Encoding. A non-binary Vary value (cowboy header
%% values may be iodata) is normalized first; an empty/whitespace/
%% unnormalizable value is treated as absent (an empty existing value
%% would otherwise produce a leading comma; ocr r3).
vary_accept_encoding(Headers) ->
    case maps:get(<<"vary">>, Headers, undefined) of
        V0 ->
            case vary_normalize(V0) of
                <<>> ->
                    Headers#{<<"vary">> => <<"accept-encoding">>};
                <<"*">> ->
                    Headers;
                V ->
                    case vary_has_accept_encoding(V) of
                        true ->
                            Headers;
                        false ->
                            Toks = [
                                string:trim(T)
                             || T <- binary:split(V, <<",">>, [global]), string:trim(T) =/= <<>>
                            ],
                            Headers#{
                                <<"vary">> =>
                                    iolist_to_binary(
                                        lists:join(<<", ">>, Toks ++ [<<"accept-encoding">>])
                                    )
                            }
                    end
            end
    end.

vary_normalize(V) when is_binary(V); is_list(V) ->
    try
        string:trim(iolist_to_binary(V))
    catch
        _:_ -> <<>>
    end;
vary_normalize(_) ->
    <<>>.

vary_has_accept_encoding(Vary) ->
    Tokens = [
        string:trim(string:lowercase(T))
     || T <- binary:split(Vary, <<",">>, [global])
    ],
    lists:member(<<"accept-encoding">>, Tokens).

%% Log dedup for the (near-impossible) systematic zlib failure —
%% the D7 worker-side warn_once precedent (janus_wire_enc keeps its
%% copy private; same idiom, local): this seam sits on the master's
%% unary reply hot path, so a systematically failing zlib must fire
%% ONE incident line, not one per JSON reply. UNLIKE the one-way
%% latch, the flag carries a timestamp and RE-ARMS after one hour
%% (ocr r4: a permanent latch would swallow the incident line for the
%% node's whole lifetime after one transient hiccup). Reached ONLY on
%% a zlib failure, so the put is not on the per-reply hot path. A
%% benign persistent_term race can emit the warning twice; never per
%% reply.
-define(GZIP_FAIL_WARN_WINDOW_S, 3600).

warn_once(Event) ->
    Now = erlang:monotonic_time(second),
    try
        case persistent_term:get({?MODULE, gzip_fail_warned}, undefined) of
            {Ts, true} when Now - Ts < ?GZIP_FAIL_WARN_WINDOW_S ->
                ok;
            _ ->
                persistent_term:put({?MODULE, gzip_fail_warned}, {Now, true}),
                logger:warning(Event)
        end
    catch
        _:_ -> ok
    end.
