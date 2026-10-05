%% Shared SSE-translate state: the handler (janus_http_proxy) and the
%% eunit suite include this so the record can never drift.
-define(SSE_LEFTOVER_CAP, 1024 * 1024).

-record(sse_st, {
    %% Incomplete SSE tail owned by the handler; copied here each fold step.
    leftover = <<>> :: binary(),
    %% Client-face envelope state.
    role_sent = false :: boolean(),
    %% Next Anthropic content-block index (monotonic; text <-> thinking).
    next_block = 0 :: non_neg_integer(),
    block = undefined :: undefined | non_neg_integer(),
    block_kind = undefined :: undefined | text | thinking,
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
    terminal_sent = false :: boolean()
}).
