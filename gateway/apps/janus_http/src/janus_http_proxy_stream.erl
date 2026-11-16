%%%-------------------------------------------------------------------
%%% @doc Mid-stream drain reason text for the data-plane proxy.
%%% Extracted from `janus_http_proxy` so OCR can scan the orchestrator
%%% under the line budget. Native and translate paths must keep the
%%% same client sentences (macros below).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy_stream).

-define(UPSTREAM_STALLED_MSG, <<"upstream stopped sending data mid-stream">>).
%% Shared by BOTH renderers (stream_failure_text/1 on the native path and
%% sanitize_stream_reason/1 on the translate path). A macro rather than two
%% literals so the agreement is structural: the whole point of the
%% reason-text tests is that these two cannot drift, and every other shared
%% sentence is already centralized.
-define(UNEXPECTED_FRAME_MSG, <<"upstream sent an unexpected stream frame">>).
%% An internal-hop inflate failure is OUR wire, not the provider's. Written
%% from two exits (the committed native path and the uncommitted reply), so
%% it is a macro: two literals are exactly how "one cause, one sentence"
%% silently breaks.
-define(INTERNAL_INFLATE_FAIL_MSG, <<"internal wire inflate failed">>).
-define(STREAM_TIMEOUT_MSG, <<"upstream stream exceeded the total time budget">>).
-define(IS_WIRE_ENC_ABORT(R),
    ((R) =:= wire_enc_inflate_fail orelse
        (is_tuple(R) andalso tuple_size(R) >= 1 andalso
            element(1, R) =:= wire_enc_inflate_fail))
).

-export([
    drain_detail_text/3,
    sse_failure_notice/1,
    stream_failure_text/1,
    sanitize_stream_reason/1,
    body_failure_text/1
]).

%% Usage-row detail for a local-path upstream failure: the DRAIN reason when it
%% is specific enough to be useful, else the client-facing text. Kept a binary
%% because the row reader guards on is_binary.
drain_detail_text(Status, Reason, Fallback) ->
    Detailed =
        case {Status, Reason} of
            %% A 504 is the FIRST-BYTE budget and the client text already says
            %% so. Every 504-shaped reason maps here, including
            %% {await, timeout} — error_http_status/1 turns that tuple into 504
            %% unconditionally, so there is no 502/await-timeout state to
            %% distinguish and no need for a branch for one.
            {504, _} ->
                undefined;
            %% timeout is a STALL, not a generic body error — the same
            %% distinction both renderers make, so the row matches the client.
            {_, {body, timeout}} ->
                ?UPSTREAM_STALLED_MSG;
            {_, {body, R}} ->
                body_failure_text(R);
            {_, {await, no_progress}} ->
                ?UPSTREAM_STALLED_MSG;
            %% Internal-hop inflate failure is OUR wire, not the provider's
            %% (native_stream_fail skips benching for exactly this reason).
            %% Without this clause the row falls back to a provider-blaming
            %% sentence, and the sibling uncommitted branch already records
            %% the honest "internal wire inflate failed" for the same
            %% condition — one cause must not produce two different rows.
            {_, R} when ?IS_WIRE_ENC_ABORT(R) ->
                ?INTERNAL_INFLATE_FAIL_MSG;
            %% Delegated, never re-worded: one condition, one sentence. The
            %% guard keeps an UNKNOWN shape out of stream_failure_text/1 (whose
            %% catch-all is the vague "upstream error") so an unrecognised
            %% reason still falls back to the status-derived client text.
            %% Only the shapes not already handled above: `body` has its two
            %% clauses, so listing it here would be dead.
            {_, R} when
                is_tuple(R) andalso tuple_size(R) >= 1 andalso
                    (element(1, R) =:= content_encoding orelse
                        element(1, R) =:= unexpected_body)
            ->
                stream_failure_text(R);
            _ ->
                undefined
        end,
    case Detailed of
        undefined -> Fallback;
        Bin -> Bin
    end.

%% Human-readable, single-line, SSE-safe reason for a mid-stream close.
sse_failure_notice(closed) ->
    <<>>;
sse_failure_notice(Reason) ->
    Text = stream_failure_text(Reason),
    iolist_to_binary([<<": janus stream failed - ">>, Text, <<"\n\n">>]).

stream_failure_text({body, timeout}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text({body, Reason}) -> body_failure_text(Reason);
stream_failure_text({await, timeout}) -> ?STREAM_TIMEOUT_MSG;
stream_failure_text({await, no_progress}) -> ?UPSTREAM_STALLED_MSG;
stream_failure_text({unexpected_body, _}) -> ?UNEXPECTED_FRAME_MSG;
%% Top-level shape: janus_providers_http surfaces a decode failure on the
%% decoded drain as {content_encoding, _} rather than nesting it under body.
stream_failure_text({content_encoding, _}) -> body_failure_text({content_encoding, x});
%% Internal-hop inflate failure: same words as drain_detail_text/3. Without
%% this clause the catch-all returns "upstream error" (native path) while
%% sanitize_stream_reason/1 would fall through to sanitize_upstream_error/1
%% and put the bare atom `wire_enc_inflate_fail` on the translate wire.
stream_failure_text(R) when ?IS_WIRE_ENC_ABORT(R) -> ?INTERNAL_INFLATE_FAIL_MSG;
stream_failure_text(closed) -> <<"client disconnected">>;
stream_failure_text(_) -> <<"upstream error">>.

%% Upstream silence in the middle of a stream (janus_worker_wire:
%% stream_inactivity_timeout_ms/0). The worker client reports it as
%% {await, no_progress}; sanitize_upstream_error/1 would keep it a
%% tuple and the client would read an Erlang term. Name it in words a
%% human can act on — this is the gateway saying "the upstream stalled",
%% which is precisely what the generic 502 used to hide.

%% NOTE: this fills the Msg slot of {error, upstream, Msg}, so it must
%% yield a BINARY. Returning {stalled, Binary} here would fall through
%% wire_reason/1's non-binary clause, which renders with ~w — the client
%% would read an Erlang term again, the exact leak this removes.
sanitize_stream_reason({await, no_progress}) -> ?UPSTREAM_STALLED_MSG;
%% The sibling budget: without this clause the tuple falls through to
%% wire_reason's ~w rendering and the client reads an Erlang term.
sanitize_stream_reason({await, timeout}) -> ?STREAM_TIMEOUT_MSG;
%% Body-side failures, same words as stream_failure_text/1. This clause was
%% MISSING and it was the live 2026-11-11 bug: the local execution path
%% (janus_providers_http drains the provider directly when no worker is
%% available) reports a silent body as {body, timeout}, which fell through to
%% sanitize_upstream_error/1 — whose {Tag, _} -> Tag clause returns the bare
%% atom `body`, so the client was told `api_error: body` after a 147s stream.
sanitize_stream_reason({body, timeout}) -> ?UPSTREAM_STALLED_MSG;
sanitize_stream_reason({body, Reason}) -> body_failure_text(Reason);
%% The sibling drain shape: a frame arrived where none was expected. Named
%% like the two above so it cannot fall through to sanitize_upstream_error/1
%% and reach the client as the bare atom `unexpected_body`.
sanitize_stream_reason({unexpected_body, _}) -> ?UNEXPECTED_FRAME_MSG;
%% Top-level decode failure (janus_providers_http's decoded drain). Without
%% this clause it fell through to sanitize_upstream_error/1, which returns the
%% bare atom `content_encoding` — the same leak as `body`, one shape over.
sanitize_stream_reason({content_encoding, _}) ->
    body_failure_text({content_encoding, x});
%% Same internal-hop sentence as drain_detail_text/3 / stream_failure_text/1.
%% Falling through to sanitize_upstream_error/1 returns the atom
%% `wire_enc_inflate_fail`, which is exactly the Erlang-term-on-the-wire
%% failure these clauses exist to prevent.
sanitize_stream_reason(R) when ?IS_WIRE_ENC_ABORT(R) -> ?INTERNAL_INFLATE_FAIL_MSG;
sanitize_stream_reason(Other) -> janus_http_proxy:sanitize_upstream_error(Other).

%% A body that stopped for a reason other than silence. Still names the body
%% (that is where it broke and it is what an operator greps for) but never
%% echoes an Erlang term.
%% Reasons that mean the connection ENDED, in gun's vocabulary. Grouped so
%% an operator sees "closed" for a reset rather than a vaguer "error".
body_failure_text(closed) -> <<"upstream body closed">>;
body_failure_text(econnreset) -> <<"upstream body closed">>;
body_failure_text(closed_by_peer) -> <<"upstream body closed">>;
%% A HEADERS-level contract violation (janus_wire_enc:classify_content_encoding/1
%% rejected the provider's Content-Encoding) is not a decompression failure —
%% nothing was ever decompressed. "Unsupported encoding" is the honest
%% sentence, and this text now reaches both the SSE comment and the usage row,
%% so the distinction is worth a clause.
body_failure_text({content_encoding, {violation, _}}) ->
    <<"upstream sent an unsupported content-encoding">>;
body_failure_text({content_encoding, _}) -> <<"upstream body decompression error">>;
%% A size cap is a distinct, greppable cause (janus_providers_http:
%% collect_body/5 crosses ?MAX_BODY_BYTES) and the decisions face already has
%% its own sentence for it. Reported as a generic body error it reads like a
%% transport fault and sends an operator looking in the wrong place.
body_failure_text(too_large) -> <<"upstream response body exceeds size limit">>;
body_failure_text(_) -> <<"upstream body error">>.

