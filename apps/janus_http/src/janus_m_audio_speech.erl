%%%-------------------------------------------------------------------
%%% @doc TTS plugin (spec M2.1, A5/A6/A8): canonical
%%% `POST /v1/audio/speech` `{model, input, voice?, response_format?,
%%% speed?}` translated to the mimo chat-completions TTS dialect.
%%%
%%% Upstream reality (captured probe mimo_tts_chat2.json): the provider
%%% IS an OpenAI chat endpoint — `{model, messages: [{role: "user",
%%% content: "read this aloud"}, {role: "assistant", content: TEXT}]}`,
%%% and the reply carries base64 WAV in
%%% `choices[0].message.audio.data` (a user-role message is REQUIRED
%%% alongside the assistant one).
%%%
%%% Spend discipline (A6): COMMIT = upstream ACCEPT (2xx); the input
%%% character cap is enforced BEFORE any upstream spend (400). The
%%% whole call is buffered: nothing reaches the client until a fully
%%% decodable reply exists, and v1 does NO failover — a single
%%% upstream attempt per request (pre-accept retry across same-mode
%%% routes is the follow-up once the shared loop is parameterized;
%%% retrying after accept would double-bill generated audio).
%%%
%%% Billing = INPUT CHARACTERS (byte_size of `input`) recorded from
%%% accept regardless of output; never invent output seconds.
%%% Binary/audio bytes are never logged (A8).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_audio_speech).

-export([
    modality/0,
    max_body/0,
    process/5,
    max_input_chars/0,
    validate/1,
    translate_request/2,
    extract_audio/1,
    speech_content_type/1
]).

%% Input cap (spec Contracts): knob `tts_max_input_chars` (settings →
%% persistent_term, direct-PT convention), default 5000. Over the cap
%% → 400 BEFORE any upstream spend.
-define(MAX_INPUT_CHARS, 5000).

%% The JSON envelope is tiny (model + <=5000-char input + a few
%% params); 64KiB is a generous parse guard.
-define(SPEECH_BODY_CAP, 64 * 1024).

-define(DEFAULT_AUDIO_CT, <<"audio/wav">>).

modality() ->
    <<"tts">>.

max_body() ->
    ?SPEECH_BODY_CAP.

%% Exported knob getter (module constant default).
-spec max_input_chars() -> pos_integer().
max_input_chars() ->
    case persistent_term:get({janus, tts_max_input_chars}, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?MAX_INPUT_CHARS
    end.

%%%===================================================================
%%% Entry (janus_modality:run/3 has authed + read the capped body)
%%%===================================================================

process(Req, State, Agent, Body, _Meta) ->
    Started = erlang:monotonic_time(millisecond),
    case janus_modality:parse_json(Body) of
        {ok, Map} ->
            case validate(Map) of
                {ok, Model, Input} ->
                    put(janus_req_model, Model),
                    case janus_modality:check_modality(<<"tts">>, Model) of
                        ok ->
                            route(Req, State, Agent, Model, Input, Started);
                        {error, Why} ->
                            reject(Req, State, Agent, #{}, 400, wrong_modality, Why, Started)
                    end;
                {error, Code} ->
                    reject(Req, State, Agent, #{}, 400, Code, message_for(Code), Started)
            end;
        {error, bad_json} ->
            reject(
                Req, State, Agent, #{}, 400, bad_json, <<"request body is not valid JSON">>, Started
            )
    end.

route(Req, State, Agent, Model, Input, Started) ->
    case janus_modality:pick_route(Model) of
        {ok, Route} ->
            speak(Req, State, Agent, Route, Model, Input, Started);
        {error, no_route} ->
            reject(Req, State, Agent, #{}, 404, no_route, <<"no route for model">>, Started);
        {error, Reason} ->
            logger:warning(#{what => janus_tts_no_route, reason => Reason}),
            reject(
                Req,
                State,
                Agent,
                #{},
                503,
                service_unavailable,
                <<"no usable upstream for model">>,
                Started
            )
    end.

%%%===================================================================
%%% Upstream call (single attempt — see module doc, A6)
%%%===================================================================

speak(Req, State, Agent, Route, Model, Input, Started) ->
    UpReq = translate_request(Model, Input),
    case janus_modality:upstream_post(Route, <<"/chat/completions">>, UpReq) of
        {ok, Status, Headers, RespBody} when Status >= 200, Status < 300 ->
            accepted(Req, State, Agent, Route, Input, Headers, RespBody, Started);
        {ok, Status, _Headers, RespBody} ->
            %% Pre-accept upstream failure: nothing generated, nothing
            %% billed (units stay NULL); status relays upstream.
            Msg = upstream_message(RespBody),
            reject(Req, State, Agent, Route, Status, upstream_error, Msg, Started);
        {error, Reason} ->
            logger:warning(#{what => janus_tts_upstream_error, reason => Reason}),
            reject(
                Req,
                State,
                Agent,
                Route,
                502,
                upstream_unreachable,
                <<"upstream request failed">>,
                Started
            )
    end.

%% Upstream ACCEPTED (2xx): input characters are consumed from here
%% (billed regardless of what the reply contains).
accepted(Req, State, Agent, Route, Input, Headers, RespBody, Started) ->
    Chars = byte_size(Input),
    case janus_modality:parse_json(RespBody) of
        {ok, RMap} ->
            case extract_audio(RMap) of
                {ok, B64} ->
                    case safe_b64decode(B64) of
                        {ok, Audio} ->
                            record(
                                Agent, Route, 200, Chars, completed, Started
                            ),
                            janus_modality:reply_bytes(
                                Req, State, 200, speech_content_type(Headers), Audio
                            );
                        error ->
                            accepted_but_unusable(
                                Req, State, Agent, Route, Chars, <<"audio data is not valid base64">>, Started
                            )
                    end;
                error ->
                    accepted_but_unusable(
                        Req, State, Agent, Route, Chars, <<"upstream 2xx reply carries no audio data">>, Started
                    )
            end;
        {error, bad_json} ->
            accepted_but_unusable(
                Req, State, Agent, Route, Chars, <<"upstream 2xx reply is not JSON">>, Started
            )
    end.

accepted_but_unusable(Req, State, Agent, Route, Chars, Msg, Started) ->
    %% Accept happened — the characters WERE consumed upstream (units
    %% recorded), but the reply cannot become audio: canonical 502.
    logger:warning(#{what => janus_tts_bad_upstream_reply, detail => Msg}),
    reject(Req, State, Agent, Route, 502, upstream_bad_reply, Msg, Started, Chars).

%%%===================================================================
%%% Pure request/reply shaping
%%%===================================================================

%% Canonical → mimo chat dialect (see module doc). `voice`, `speed`
%% and `response_format` have no mimo-side parameter (the capture
%% always answers WAV) and are accepted-but-dropped in v1.
-spec translate_request(binary(), binary()) -> map().
translate_request(Model, Input) when is_binary(Model), is_binary(Input) ->
    #{
        <<"model">> => Model,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"read this aloud">>},
            #{<<"role">> => <<"assistant">>, <<"content">> => Input}
        ]
    }.

%% {ok, Base64Audio} from a decoded upstream chat reply; `error` when
%% any hop is missing (incl. the ASR capture's `audio: null`).
-spec extract_audio(map()) -> {ok, binary()} | error.
extract_audio(Map) when is_map(Map) ->
    case maps:get(<<"choices">>, Map, undefined) of
        [Choice | _] ->
            case maps:get(<<"message">>, Choice, undefined) of
                #{<<"audio">> := #{<<"data">> := B64}} when is_binary(B64), byte_size(B64) > 0 ->
                    {ok, B64};
                _ ->
                    error
            end;
        _ ->
            error
    end;
extract_audio(_) ->
    error.

%% The chat envelope arrives as application/json — the default
%% carries (mimo emits WAV per capture); an explicit audio/* reply
%% header (params stripped) wins when a provider sets one.
-spec speech_content_type(map()) -> binary().
speech_content_type(Headers) when is_map(Headers) ->
    case maps:get(<<"content-type">>, Headers, undefined) of
        CT when is_binary(CT), byte_size(CT) > 6 ->
            case binary:split(CT, <<";">>) of
                [MaybeAudio | _] ->
                    Norm = string:trim(string:lowercase(MaybeAudio), both, " \t"),
                    case Norm of
                        <<"audio/", _/binary>> -> Norm;
                        _ -> ?DEFAULT_AUDIO_CT
                    end
            end;
        _ ->
            ?DEFAULT_AUDIO_CT
    end;
speech_content_type(_) ->
    ?DEFAULT_AUDIO_CT.

%% Request validation, all BEFORE any upstream spend.
-spec validate(map()) -> {ok, binary(), binary()} | {error, atom()}.
validate(Map) when is_map(Map) ->
    Model = janus_modality:model_of(Map),
    Input = maps:get(<<"input">>, Map, undefined),
    case {Model, Input} of
        {undefined, _} ->
            {error, missing_model};
        {_, undefined} ->
            {error, missing_input};
        {_, I} when not is_binary(I) ->
            {error, invalid_input};
        {M, I} ->
            case byte_size(I) > max_input_chars() of
                true -> {error, input_too_long};
                false -> {ok, M, I}
            end
    end;
validate(_) ->
    {error, bad_json}.

%%%===================================================================
%%% Errors + usage
%%%===================================================================

reject(Req, State, Agent, Route, Status, Code, Msg, Started) ->
    reject(Req, State, Agent, Route, Status, Code, Msg, Started, null).

reject(Req, State, Agent, Route, Status, Code, Msg, Started, Units) ->
    record(Agent, Route, Status, Units, failed, Started),
    reply_error(Req, State, Status, Code, Msg).

reply_error(Req, State, Status, Code, Msg) ->
    janus_modality:reply_json(Req, State, Status, #{
        error => #{message => Msg, type => <<"janus_error">>, code => code_bin(Code)}
    }).

code_bin(Code) when is_binary(Code) -> Code;
code_bin(Code) when is_atom(Code) -> atom_to_binary(Code, utf8).

message_for(input_too_long) ->
    iolist_to_binary([
        <<"input exceeds tts_max_input_chars (">>,
        integer_to_binary(max_input_chars()),
        <<")">>
    ]);
message_for(missing_model) -> <<"you must provide a model parameter">>;
message_for(missing_input) -> <<"you must provide an input parameter">>;
message_for(invalid_input) -> <<"input must be a string">>.

%% Usage row: modality tts, units = input characters (bytes) from
%% accept, NULL for pre-spend rejects.
record(Agent, Route, Status, Units, Outcome, Started) ->
    janus_modality:record_usage(
        #{
            ts => erlang:system_time(second),
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null),
            protocol => openai_chat,
            stream => false,
            status => Status,
            latency_ms => erlang:monotonic_time(millisecond) - Started,
            modality => <<"tts">>,
            units => Units,
            outcome => Outcome
        },
        Route
    ).

%% Best-effort upstream error message (never relayed raw HTML bodies).
upstream_message(Body) ->
    case janus_modality:parse_json(Body) of
        {ok, #{<<"error">> := #{<<"message">> := M}}} when is_binary(M) -> M;
        {ok, #{<<"error">> := M}} when is_binary(M) -> M;
        _ -> <<"upstream request failed">>
    end.

safe_b64decode(B64) ->
    try
        {ok, base64:decode(B64)}
    catch
        _:_ -> error
    end.
