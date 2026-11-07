%%%-------------------------------------------------------------------
%%% @doc The single mapping table for every OpenTelemetry attribute
%%% name this gateway emits.
%%%
%%% ## Why one module
%%%
%%% The GenAI semantic conventions are at stability **Development** and
%%% renamed four times in the two days this feature was designed: the
%%% provider attribute became `gen_ai.provider.name', the token-usage
%%% histogram was replaced by per-direction counters, the inference
%%% duration instrument was displaced, and `cache_creation' became
%%% `cache_write'. A name spread across call sites is a name that gets
%%% half-renamed, and a half-renamed attribute is silently IGNORED by
%%% every backend — it looks like working telemetry that reports
%%% nothing super.
%%%
%%% So every name lives here, and a rename is one edit in one file.
%%%
%%% ## The pin
%%%
%%% `semconv_pin/0' returns the exact upstream commit the names were read
%%% at. It is a COMMIT SHA, not a version or a date, because this tree
%%% has no tagged releases: two files in the same repository disagreed on
%%% the same enum value on the same day, so a date cannot identify what
%%% was read. Every release re-checks the pin (see the OTel alignment
%%% spec, drift gate).
%%%
%%% ## Attribute vs instrument namespaces
%%%
%%% These are DIFFERENT and are easy to conflate:
%%%
%%%   * a span attribute is `gen_ai.usage.input_tokens'
%%%   * a metric instrument is `gen_ai.client.inference.usage.input_tokens'
%%%
%%% Emitting one where the other belongs produces a key no consumer
%%% reads. Both namespaces are represented here so the distinction is
%%% visible in one place.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_attr).

-export([
    semconv_pin/0,
    operation_name/1,
    span_name/2,
    provider_name/1,
    status/2,
    error_type/1,
    sanitize_value/1,
    is_attr/1,
    all_names/0
]).

%% Upstream semantic-conventions-genai commit the names below were read
%% at. Re-verify before each release; a name that no longer exists
%% upstream is a silently-dropped attribute, which is worse than a build
%% break because it looks like success.
-define(SEMCONV_PIN, <<"e6658f14">>).

%% ------------------------------------------------------------------
%% Span names
%% ------------------------------------------------------------------

%% @doc The GenAI operation for a Janus client protocol. The semconv
%% requires `gen_ai.operation.name', and the span name is
%% `{operation} {model}', so this drives both.
-spec operation_name(atom() | binary()) -> binary().
operation_name(openai_chat) -> <<"chat">>;
operation_name(openai_responses) -> <<"chat">>;
operation_name(anthropic_messages) -> <<"chat">>;
operation_name(openai_decisions) -> <<"chat">>;
operation_name(embeddings) -> <<"embeddings">>;
operation_name(image) -> <<"generate_content">>;
operation_name(audio_speech) -> <<"generate_content">>;
operation_name(audio_asr) -> <<"generate_content">>;
operation_name(video) -> <<"generate_content">>;
operation_name(P) when is_binary(P) ->
    %% Callers pass the protocol as a binary on some paths; map the few
    %% known shapes and fall back to `chat', which is what the gateway
    %% overwhelmingly serves. Never invent an enum value the semconv
    %% does not define.
    case P of
        <<"openai_chat">> -> <<"chat">>;
        <<"openai_responses">> -> <<"chat">>;
        <<"anthropic_messages">> -> <<"chat">>;
        <<"openai_decisions">> -> <<"chat">>;
        <<"embeddings">> -> <<"embeddings">>;
        <<"image">> -> <<"generate_content">>;
        <<"audio_speech">> -> <<"generate_content">>;
        <<"audio_asr">> -> <<"generate_content">>;
        <<"video">> -> <<"generate_content">>;
        _ -> <<"chat">>
    end;
operation_name(_) ->
    <<"chat">>.

%% @doc `{gen_ai.operation.name} {gen_ai.request.model}', per the
%% semconv's span-name rule. A missing model degrades to the bare
%% operation rather than rendering "chat <null>".
-spec span_name(binary(), binary() | undefined) -> binary().
span_name(Op, undefined) -> Op;
span_name(Op, Model) when is_binary(Model), Model =/= <<>> -> <<Op/binary, " ", Model/binary>>;
span_name(Op, _) -> Op.

%% ------------------------------------------------------------------
%% Provider names
%% ------------------------------------------------------------------

%% @doc Map the operator-defined catalog provider name to the semconv's
%% `gen_ai.provider.name' well-known value.
%%
%% This CANNOT be a naive pass-through: the catalog name is free-form
%% and set by the operator (`dashscope', `aliyun', `openai-compatible'),
%% so it will not match a well-known value. Emitting an invented
%% well-known value is worse than emitting a custom one, because
%% `gen_ai.provider.name' is the discriminator a backend uses to choose
%% the right attribute flavour — claiming `openai' for a non-OpenAI
%% endpoint mis-attributes the whole span.
%%
%% A custom value is explicitly legal ("otherwise a custom value MAY be
%% used"), so unmapped providers pass through verbatim.
-spec provider_name(binary() | undefined) -> binary().
provider_name(undefined) ->
    <<"unknown">>;
provider_name(Name) when is_binary(Name), Name =/= <<>> ->
    case string:lowercase(Name) of
        <<"openai">> -> <<"openai">>;
        <<"azure-openai">> -> <<"azure.ai.openai">>;
        <<"azure.openai">> -> <<"azure.ai.openai">>;
        <<"anthropic">> -> <<"anthropic">>;
        <<"claude">> -> <<"anthropic">>;
        <<"deepseek">> -> <<"deepseek">>;
        <<"mistral">> -> <<"mistral">>;
        <<"moonshot">> -> <<"moonshot_ai">>;
        <<"kimi">> -> <<"moonshot_ai">>;
        <<"ollama">> -> <<"ollama">>;
        <<"groq">> -> <<"groq">>;
        <<"perplexity">> -> <<"perplexity">>;
        <<"xai">> -> <<"x_ai">>;
        <<"x-ai">> -> <<"x_ai">>;
        <<"cohere">> -> <<"cohere">>;
        <<"gemini">> -> <<"gcp.gemini">>;
        <<"vertex">> -> <<"gcp.vertex_ai">>;
        <<"bedrock">> -> <<"aws.bedrock">>;
        %% No well-known value applies: pass the operator's name through
        %% as a custom value, preserving its original spelling.
        _ -> Name
    end;
provider_name(_) ->
    <<"unknown">>.

%% ------------------------------------------------------------------
%% Status
%% ------------------------------------------------------------------

%% @doc OTel status code for one span: `{code, message}' where code is
%% `<<"UNSET">>', `<<"OK">>' or `<<"ERROR">>'.
%%
%% The semconv follows the general recording-errors document: 5xx is
%% ERROR, 4xx is ERROR on a CLIENT span (the client asked for something
%% the server refused) but UNSET on a SERVER span (the client is at
%% fault, not this service), 1xx-3xx is UNSET.
%%
%% `message' is deliberately NOT the provider's free text: that routinely
%% echoes request content back. It is a short closed-enum-ish code; the
%% operator-visible provider sentence stays in the existing redacted
%% usage_events.error_detail channel.
-spec status(server | client, pos_integer() | undefined) -> {binary(), binary()}.
status(_Kind, undefined) ->
    {<<"UNSET">>, <<>>};
status(server, S) when S >= 500 ->
    {<<"ERROR">>, <<>>};
status(server, _S) ->
    %% Includes 4xx: a SERVER span's error means "this service failed".
    {<<"UNSET">>, <<>>};
status(client, S) when S >= 400 ->
    {<<"ERROR">>, <<>>};
status(client, _S) ->
    {<<"UNSET">>, <<>>}.

%% @doc `error.type' for a failed operation. Low cardinality by
%% construction: an HTTP status rendered as a string, or one of a small
%% closed set of transport classes. Never a sentence.
-spec error_type(non_neg_integer() | atom() | binary() | undefined) -> binary() | undefined.
error_type(undefined) ->
    undefined;
error_type(S) when is_integer(S), S >= 400 ->
    integer_to_binary(S);
error_type(S) when is_integer(S) ->
    undefined;
error_type(transport) ->
    <<"transport_error">>;
error_type(timeout) ->
    <<"timeout">>;
error_type(worker_lost) ->
    <<"worker_lost">>;
error_type(cancelled) ->
    <<"cancelled">>;
error_type(auth) ->
    <<"401">>;
error_type(deny) ->
    <<"403">>;
error_type(upstream_5xx) ->
    <<"502">>;
error_type(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 64 ->
    %% A provider-native code. Bounded and never a sentence; the guard
    %% keeps an unexpected shape out rather than shipping arbitrary
    %% provider text as an attribute.
    case looks_like_code(B) of
        true -> B;
        false -> undefined
    end;
error_type(_) ->
    undefined.

%% A provider error code is a short token: no whitespace, no sentence
%% punctuation. Anything else is prose and must not become a metric
%% dimension.
looks_like_code(B) ->
    byte_size(B) =< 64 andalso
        not lists:any(
            fun(C) -> C =:= $\s orelse C =:= $. orelse C =:= $, orelse C =:= $\n end,
            binary_to_list(B)
        ).

%% ------------------------------------------------------------------
%% Value hygiene
%% ------------------------------------------------------------------

%% @doc Clamp an attribute value to the bounded length the span layer
%% enforces. Truncation happens at a UTF-8 boundary so the OTLP encoder
%% never receives invalid bytes.
-spec sanitize_value(binary()) -> binary().
sanitize_value(B) when is_binary(B) ->
    Max = 1024,
    case byte_size(B) =< Max of
        true ->
            B;
        false ->
            truncate_utf8(B, Max)
    end;
sanitize_value(Other) ->
    sanitize_value(iolist_to_binary(io_lib:format("~0p", [Other]))).

truncate_utf8(B, Max) ->
    %% Cut at byte `Max', then walk BACK while the byte at the cut point
    %% is a UTF-8 continuation byte (10xxxxxx) — that byte belongs to a
    %% codepoint that started before the cut, so including it would split
    %% the character and emit invalid UTF-8 to the OTLP encoder.
    truncate_utf8_back(B, Max).

truncate_utf8_back(_B, Max) when Max =< 0 ->
    <<>>;
truncate_utf8_back(B, Max) ->
    case binary:at(B, Max) of
        C when C band 16#C0 =:= 16#80 -> truncate_utf8_back(B, Max - 1);
        _ -> binary:part(B, 0, Max)
    end.

%% ------------------------------------------------------------------
%% Introspection
%% ------------------------------------------------------------------

%% @doc Every attribute name this module can emit. Used by the drift
%% gate: a name that vanishes upstream is a silent data loss.
-spec all_names() -> [binary()].
all_names() ->
    [
        <<"gen_ai.operation.name">>,
        <<"gen_ai.provider.name">>,
        <<"gen_ai.request.model">>,
        <<"gen_ai.request.stream">>,
        <<"gen_ai.response.model">>,
        <<"gen_ai.response.finish_reasons">>,
        <<"gen_ai.response.time_to_first_chunk">>,
        <<"gen_ai.usage.input_tokens">>,
        <<"gen_ai.usage.output_tokens">>,
        <<"gen_ai.usage.cache_read.input_tokens">>,
        <<"gen_ai.usage.cache_write.input_tokens">>,
        <<"error.type">>,
        <<"http.request.method">>,
        <<"http.response.status_code">>,
        <<"http.route">>,
        <<"url.path">>,
        <<"url.scheme">>,
        <<"server.address">>,
        <<"server.port">>,
        <<"network.protocol.version">>,
        <<"janus.attempt">>,
        <<"janus.outcome">>,
        <<"janus.agent_key.id">>,
        <<"janus.model.requested">>
    ].

%% @doc True when this module owns the name (used to reject ad-hoc
%% attribute keys at the span boundary).
-spec is_attr(binary()) -> boolean().
is_attr(Name) when is_binary(Name) ->
    lists:member(Name, all_names());
is_attr(_) ->
    false.

%% @doc The pinned upstream commit.
-spec semconv_pin() -> binary().
semconv_pin() ->
    ?SEMCONV_PIN.