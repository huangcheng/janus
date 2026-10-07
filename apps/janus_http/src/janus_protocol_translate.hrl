%% Shared SSE-translate state: the handler (janus_http_proxy) and the
%% eunit suite include this so the record can never drift.
-define(SSE_LEFTOVER_CAP, 1024 * 1024).

%% Phase-1 tool-call caps (C5): 256KiB args per call id, 64 calls per
%% stream, 1MiB total args per stream. Exceeding any cap fails the fold
%% with {error, tool_args_cap, St}; for this phase the caller terminates
%% the stream on that tuple (the 1.9 ship unit wires the full C2 error
%% frames). The existing 1MiB ?SSE_LEFTOVER_CAP bounds ONE event, not
%% cross-event accumulation — these bound the accumulators.
-define(TOOL_ARGS_PER_CALL_CAP, 256 * 1024).
-define(TOOL_CALLS_PER_STREAM_CAP, 64).
-define(TOOL_ARGS_TOTAL_CAP, 1024 * 1024).

%% Phase-2 →responses face (C5): 4MiB total accumulated content per
%% stream (text + tool argument bytes) bounding the terminal-event
%% output reconstruction. Exceeding takes the C2 error path.
-define(STREAM_CONTENT_CAP, 4 * 1024 * 1024).

%% One accumulated tool call. `args` holds argument fragments as a
%% reversed iolist; `block` is the anthropic content_block index on the
%% chat-upstream face, `chat_index` the chat tool_calls ordinal on the
%% anthropic-upstream face — two index/id spaces that never mix (C5).
-record(tool_acc, {
    id :: binary(),
    name :: binary(),
    args = [] :: [binary()],
    args_bytes = 0 :: non_neg_integer(),
    block = undefined :: undefined | non_neg_integer(),
    chat_index = undefined :: undefined | non_neg_integer(),
    header_sent = false :: boolean(),
    closed = false :: boolean(),
    %% Phase-2 →responses face: item_id is the synthesized responses
    %% output-item id (jitem_…), resp_index the responses output_index —
    %% neither ever reuses the chat tool index nor the anthropic block
    %% index (C5: four separate index/id spaces). `id` holds the CALL id
    %% (upstream call_/tool_ id passes through; jfc_… when synthesized).
    item_id = undefined :: undefined | binary(),
    resp_index = undefined :: undefined | non_neg_integer()
}).

-record(sse_st, {
    %% Incomplete SSE tail owned by the handler; copied here each fold step.
    leftover = <<>> :: binary(),
    %% Client-face envelope state.
    role_sent = false :: boolean(),
    %% Next Anthropic content-block index (monotonic; counts ALL blocks
    %% incl. tool_use — never reuse a chat tool index here, C5).
    next_block = 0 :: non_neg_integer(),
    block = undefined :: undefined | non_neg_integer(),
    block_kind = undefined :: undefined | text | thinking | tool_use,
    %% OpenAI id/model copied from the provider when present. `created`
    %% is ALWAYS the gateway clock on the Chat client face (Anthropic
    %% message_start has no created field).
    msg_id = undefined :: undefined | binary(),
    model = undefined :: undefined | binary(),
    created = undefined :: undefined | non_neg_integer(),
    %% Anthropic usage merge (in = input/prompt, out = output/completion).
    in_tokens = undefined :: undefined | non_neg_integer(),
    out_tokens = undefined :: undefined | non_neg_integer(),
    stop_reason = undefined :: undefined | binary(),
    finish_reason = undefined :: undefined | binary(),
    usage_sent = false :: boolean(),
    finish_sent = false :: boolean(),
    terminal_sent = false :: boolean(),
    %% Phase-1 tool-call state (C5). tools maps a wire-local key — the
    %% chat tool_calls index on the chat-upstream face, the anthropic
    %% content_block index on the anthropic-upstream face — to a
    %% #tool_acc{} (one direction per state, the keys never mix).
    %% open_tool is the key of the single wire-open call; deferred holds
    %% [{Kind, Bin}] (reversed) text deferred under C5 interleaving;
    %% tool_seq is the chat tool_calls ordinal counter for the
    %% anthropic-upstream face; total_args counts accumulated argument
    %% bytes across the whole stream.
    tools = #{} :: map(),
    open_tool = undefined :: undefined | non_neg_integer(),
    deferred = [] :: list(),
    tool_seq = 0 :: non_neg_integer(),
    total_args = 0 :: non_neg_integer(),
    %% Phase-2 →responses face (C1/C5). resp_id = the synthesized
    %% response id (jresp_…); item_seq allocates responses output_index
    %% values (their own index space — never a chat tool index nor an
    %% anthropic block index); msg_item = the open message output item
    %% (#{id, index, text (reversed binaries)}); items = finished output
    %% items (reversed) for the terminal response.output reconstruction;
    %% content_bytes bounds total accumulated content (text + args)
    %% against ?STREAM_CONTENT_CAP.
    resp_id = undefined :: undefined | binary(),
    item_seq = 0 :: non_neg_integer(),
    msg_item = undefined :: undefined | map(),
    items = [] :: list(),
    content_bytes = 0 :: non_neg_integer()
}).
