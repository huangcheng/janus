%% Client-visible text for a mid-stream failure reason (2026-11-11).
%%
%% Live: a 147s glm-5.3 stream died on the LOCAL execution path (the worker
%% was unavailable, so the master drained the provider directly) and the
%% client received `api_error: body` — a bare Erlang atom, no information.
%%
%% Two renderers exist for a drain reason and they had drifted apart:
%%
%%   stream_failure_text/1      native/verbatim path, SSE comment frame
%%   sanitize_stream_reason/1   translate path, the error event
%%
%% The native one knew about {body, _}; the translate one did not, so the
%% tuple fell through to sanitize_upstream_error/1, whose {Tag, _} -> Tag
%% clause strips the sub-reason and returns the atom `body`. Both renderers
%% must name the same conditions in the same words, and neither may ever put
%% an Erlang term on the wire.
-module(janus_stream_reason_text_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STALLED, <<"upstream stopped sending data mid-stream">>).
-define(TOTAL, <<"upstream stream exceeded the total time budget">>).

%% Every reason a drain can hand the proxy, with the text it must produce.
%% Kept in one table because the whole point is that the two renderers agree.
reasons() ->
    [
        {{await, no_progress}, ?STALLED},
        {{await, timeout}, ?TOTAL},
        %% The regression: a body-side stall is a stall, and says so.
        {{body, timeout}, ?STALLED},
        %% A body that ended for any other reason is still an upstream body
        %% failure — never the atom `body`.
        {{body, closed}, <<"upstream body closed">>},
        {{body, {content_encoding, inflate_incomplete}}, <<"upstream body decompression error">>},
        {{body, {content_encoding, {violation, <<"br">>}}},
            <<"upstream sent an unsupported content-encoding">>},
        {{body, econnreset}, <<"upstream body closed">>},
        {{body, too_large}, <<"upstream response body exceeds size limit">>},
        {{unexpected_body, closed}, <<"upstream sent an unexpected stream frame">>}
    ].

%% The translate path must yield a BINARY for every reason, because it fills
%% the Msg slot of {error, upstream, Msg} and the client renders that
%% verbatim. An atom here becomes `api_error: body` on the wire.
translate_path_is_a_readable_binary_test() ->
    lists:foreach(
        fun({Reason, Expected}) ->
            Got = janus_http_proxy:sanitize_stream_reason(Reason),
            ?assertEqual({Reason, Expected}, {Reason, Got})
        end,
        reasons()
    ).

%% The native path renders the same conditions in the same words. Comparing
%% the two renderers is what stops them drifting again.
renderers_agree_test() ->
    lists:foreach(
        fun({Reason, Expected}) ->
            ?assertEqual(
                {Reason, Expected},
                {Reason, janus_http_proxy:stream_failure_text(Reason)}
            )
        end,
        reasons()
    ).

%% No reason may reach the client as an Erlang term. `~w` output would carry
%% braces, quotes or a bare lowercase atom; every expected text is prose.
never_an_erlang_term_test() ->
    lists:foreach(
        fun({Reason, _}) ->
            Bin = janus_http_proxy:sanitize_stream_reason(Reason),
            ?assert(is_binary(Bin)),
            ?assert(binary:match(Bin, <<"{">>) =:= nomatch),
            ?assert(binary:match(Bin, <<"\"">>) =:= nomatch),
            %% A single bare word is the failure mode being removed.
            ?assert(byte_size(Bin) > 12)
        end,
        reasons()
    ).

%% A 502 row must say WHY. The local execution path's failure exit computed
%% the client text but never stashed the drain reason, so every such row was
%% written with error_detail NULL — a body-side stall looked identical to any
%% other upstream failure. The live 2026-11-11 case (147s glm-5.3 stream,
%% `api_error: body`) left no trace in the row at all.
drain_detail_names_the_body_failure_test() ->
    ?assertEqual(
        <<"upstream body closed">>,
        janus_http_proxy:drain_detail_text(502, {body, closed}, <<"upstream request failed">>)
    ),
    ?assertEqual(
        ?STALLED,
        janus_http_proxy:drain_detail_text(502, {body, timeout}, <<"upstream request failed">>)
    ),
    ?assertEqual(
        <<"upstream body decompression error">>,
        janus_http_proxy:drain_detail_text(
            502, {content_encoding, inflate_incomplete}, <<"upstream request failed">>
        )
    ).

%% Every 504 is the first-byte budget, and error_http_status/1 maps
%% {await, timeout} to 504 unconditionally — so that tuple must NOT be given
%% the total-budget wording in the row, because the client was told
%% "first-byte timeout". The 504 branch keeps the status-derived client text
%% instead of inventing a sentence the caller never saw.
drain_detail_keeps_the_client_text_on_a_504_test() ->
    ?assertEqual(
        <<"upstream first-byte timeout">>,
        janus_http_proxy:drain_detail_text(504, {await, timeout}, <<"upstream first-byte timeout">>)
    ),
    ?assertEqual(
        <<"upstream first-byte timeout">>,
        janus_http_proxy:drain_detail_text(504, {await, {timeout, x}}, <<"upstream first-byte timeout">>)
    ).

%% A running-stream stall still gets its own sentence, so the 504 gate does
%% not swallow the no-progress case.
drain_detail_names_a_running_stream_stall_test() ->
    ?assertEqual(
        ?STALLED,
        janus_http_proxy:drain_detail_text(502, {await, no_progress}, <<"upstream request failed">>)
    ).

%% One condition, one sentence: the row and the wire must not describe the
%% decompression failure two different ways.
drain_detail_agrees_with_the_renderers_test() ->
    %% Compare against the renderer the CLIENT actually reads. Asserting
    %% against body_failure_text/1 would compare the row with its own helper
    %% and pass even if sanitize_stream_reason/1 were never consulted — the
    %% very drift this is meant to catch.
    CE = {content_encoding, inflate_incomplete},
    ?assertEqual(
        janus_http_proxy:sanitize_stream_reason(CE),
        janus_http_proxy:drain_detail_text(502, CE, <<"fallback">>)
    ).

%% The row must agree with the WIRE for every shape the wire names. This is
%% the invariant that makes the three knowledge sites (two renderers plus
%% drain_detail_text/3's guard) safe without collapsing them: adding a shape
%% to only one renderer fails here instead of silently degrading the row.
%% (A full single-table refactor is worth doing, but not on top of an
%% already-substantial fix.)
row_agrees_with_wire_for_every_named_shape_test() ->
    Shapes = [
        {body, timeout},
        {body, closed},
        {body, too_large},
        {body, {content_encoding, inflate_incomplete}},
        {content_encoding, {violation, <<"br">>}},
        {unexpected_body, closed},
        {await, no_progress}
    ],
    lists:foreach(
        fun(Reason) ->
            Wire = janus_http_proxy:sanitize_stream_reason(Reason),
            ?assert(is_binary(Wire)),
            %% Only 502-shaped reasons are compared: a 504 deliberately keeps
            %% the status-derived client text (first-byte timeout).
            ?assertEqual(
                {Reason, Wire},
                {Reason, janus_http_proxy:drain_detail_text(502, Reason, <<"FALLBACK">>)}
            )
        end,
        Shapes
    ).

%% A reason with nothing extra to say falls back to the client text rather
%% than writing NULL — a row that says "upstream request failed" still beats
%% one that says nothing.
drain_detail_falls_back_never_null_test() ->
    ?assertEqual(
        <<"upstream request failed">>,
        janus_http_proxy:drain_detail_text(502, some_unmapped_reason, <<"upstream request failed">>)
    ).

%% An internal-hop inflate failure is OUR wire, not the provider's — the
%% native path deliberately skips provider benching for it — so the row must
%% not blame the upstream. The uncommitted branch already records this exact
%% sentence; one cause must not produce two different rows.
internal_inflate_failure_is_not_a_provider_fault_test() ->
    ?assertEqual(
        <<"internal wire inflate failed">>,
        janus_http_proxy:drain_detail_text(
            502, {wire_enc_inflate_fail, x}, <<"upstream error">>
        )
    ).

%% An empty tuple must not crash the delegating guard (element/2 on {}).
empty_tuple_reason_falls_back_test() ->
    ?assertEqual(
        <<"fallback">>,
        janus_http_proxy:drain_detail_text(502, {}, <<"fallback">>)
    ).
