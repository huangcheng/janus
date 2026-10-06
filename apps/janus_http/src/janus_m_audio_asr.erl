%%%-------------------------------------------------------------------
%%% @doc ASR plugin (spec M2.2, A5/A6/A8): canonical
%%% `POST /v1/audio/transcriptions` (multipart/form-data IN) with
%%% `model` + `file` parts, translated to the mimo chat-completions
%%% ASR dialect.
%%%
%%% Upstream reality (captured probe mimo_asr.json): the provider IS
%%% an OpenAI chat endpoint — messages: [{role: "user", content:
%%% [{type: "input_audio", input_audio: {data:
%%% "data:audio/wav;base64,..."}}]}], and the transcript is
%%% `choices[0].message.content` (the capture answers "嗯。").
%%%
%%% Transport (A5): the request body is RAW multipart bytes under a
%%% 25MiB HARD CAP (max_body/0 — janus_modality:run answers 413
%%% beyond, before this plugin runs). The parser is janus_multipart
%%% (pure, chunk-straddle-safe). Per-node admission slots (429 +
%%% Retry-After) are a separate, dashboard-knobbed mechanism and are
%%% NOT implemented in v1 of this plugin.
%%%
%%% Usage (M2.2/A5 duration-source rule): units stay NULL in v1 —
%%% the capture's provider `usage.seconds` field is not a stable
%%% contract, so the loss is documented rather than guessed. Binary
%%% audio is never logged (A8); nothing is spooled to disk.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_audio_asr).

-export([
    modality/0,
    max_body/0,
    process/5,
    asr_options/1,
    build_request/2,
    transcript_of/1,
    file_mime/1
]).

%% 25MiB hard request cap (spec A5/A8) — enforced upstream of this
%% plugin by the modality body reader (413).
-define(ASR_BODY_CAP, 25 * 1024 * 1024).

-define(DEFAULT_FILE_MIME, <<"audio/wav">>).

modality() ->
    <<"asr">>.

max_body() ->
    ?ASR_BODY_CAP.

%%%===================================================================
%%% Entry (janus_modality:run/3 has authed + read the capped body)
%%%===================================================================

process(Req, State, Agent, Body, _Meta) ->
    Started = erlang:monotonic_time(millisecond),
    case janus_multipart:boundary_of(cowboy_req:header(<<"content-type">>, Req)) of
        {ok, Boundary} ->
            case janus_multipart:parse(Body, Boundary) of
                {ok, #{fields := Fields, files := Files}} ->
                    admitted(Req, State, Agent, Fields, Files, Started);
                {error, bad_multipart} ->
                    reject(
                        Req,
                        State,
                        Agent,
                        #{},
                        400,
                        bad_multipart,
                        <<"malformed multipart body">>,
                        Started
                    )
            end;
        error ->
            reject(
                Req,
                State,
                Agent,
                #{},
                400,
                invalid_content_type,
                <<"content-type must be multipart/form-data with a boundary">>,
                Started
            )
    end.

admitted(Req, State, Agent, Fields, Files, Started) ->
    Model =
        case maps:get(<<"model">>, Fields, undefined) of
            M when is_binary(M), M =/= <<>> -> M;
            _ -> undefined
        end,
    File = first_named_file(Files, <<"file">>),
    case {Model, File} of
        {undefined, _} ->
            reject(Req, State, Agent, #{}, 400, missing_model,
                <<"you must provide a model parameter">>, Started);
        {_, undefined} ->
            reject(Req, State, Agent, #{}, 400, missing_file,
                <<"you must provide a file parameter">>, Started);
        _ ->
            case asr_options(Fields) of
                {ok, _Options} ->
                    put(janus_req_model, Model),
                    case janus_modality:check_modality(<<"asr">>, Model) of
                        ok ->
                            route(Req, State, Agent, Model, File, Started);
                        {error, Why} ->
                            reject(Req, State, Agent, #{}, 400, wrong_modality, Why, Started)
                    end;
                {error, invalid_language} ->
                    reject(Req, State, Agent, #{}, 400, invalid_language,
                        <<"language must be one of: auto, zh, en">>, Started)
            end
    end.

first_named_file([#{name := <<"file">>} = F | _], <<"file">>) ->
    F;
first_named_file([_ | Rest], File) ->
    first_named_file(Rest, File);
first_named_file([], _) ->
    undefined.

route(Req, State, Agent, Model, File, Started) ->
    case janus_modality:pick_route(Model) of
        {ok, Route} ->
            transcribe(Req, State, Agent, Route, Model, File, Started);
        {error, no_route} ->
            reject(Req, State, Agent, #{}, 404, no_route, <<"no route for model">>, Started);
        {error, Reason} ->
            logger:warning(#{what => janus_asr_no_route, reason => Reason}),
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
%%% Upstream call
%%%===================================================================

transcribe(Req, State, Agent, Route, Model, File, Started) ->
    UpReq = build_request(Model, File),
    case janus_modality:upstream_post(Route, <<"/chat/completions">>, UpReq) of
        {ok, Status, _Headers, RespBody} when Status >= 200, Status < 300 ->
            case janus_modality:parse_json(RespBody) of
                {ok, RMap} ->
                    case transcript_of(RMap) of
                        {ok, Text} ->
                            record(Agent, Route, 200, completed, Started),
                            janus_modality:reply_json(Req, State, 200, #{
                                <<"text">> => Text, <<"model">> => Model
                            });
                        error ->
                            logger:warning(#{
                                what => janus_asr_bad_upstream_reply
                            }),
                            reject(Req, State, Agent, Route, 502, upstream_bad_reply,
                                <<"upstream 2xx reply carries no transcript">>, Started)
                    end;
                {error, bad_json} ->
                    reject(Req, State, Agent, Route, 502, upstream_bad_reply,
                        <<"upstream 2xx reply is not JSON">>, Started)
            end;
        {ok, Status, _Headers, RespBody} ->
            reject(Req, State, Agent, Route, Status, upstream_error,
                upstream_message(RespBody), Started);
        {error, Reason} ->
            logger:warning(#{what => janus_asr_upstream_error, reason => Reason}),
            reject(Req, State, Agent, Route, 502, upstream_unreachable,
                <<"upstream request failed">>, Started)
    end.

%%%===================================================================
%%% Pure request/reply shaping
%%%===================================================================

%% Canonical parts → mimo chat dialect: the audio rides a data URL
%% inside an input_audio content part (mime from the file part's
%% content-type; audio/wav default per the capture).
-spec build_request(binary(), map()) -> map().
build_request(Model, #{data := Data} = File) when is_binary(Model), is_binary(Data) ->
    Mime = file_mime(maps:get(content_type, File, undefined)),
    DataUrl = <<"data:", Mime/binary, ";base64,", (base64:encode(Data))/binary>>,
    #{
        <<"model">> => Model,
        <<"messages">> => [
                #{
                    <<"role">> => <<"user">>,
                    <<"content">> => [
                        #{
                            <<"type">> => <<"input_audio">>,
                            <<"input_audio">> => #{<<"data">> => DataUrl}
                        }
                    ]
                }
            ]
    }.

%% File part content-type → data-URL mime: strip parameters,
%% lowercase; audio/wav default (audio/mpeg passes through as
%% audio/mpeg, any other declared type passes through for the
%% upstream to adjudicate).
-spec file_mime(binary() | undefined) -> binary().
file_mime(undefined) ->
    ?DEFAULT_FILE_MIME;
file_mime(CT) when is_binary(CT) ->
    [Head | _] = binary:split(CT, <<";">>),
    case string:trim(string:lowercase(Head), both, " \t") of
        <<>> -> ?DEFAULT_FILE_MIME;
        Mime -> Mime
    end.

%% language part → #{language => auto | zh | en}; anything else is a
%% 400 (validated at the edge). v1 sends audio only — mimo
%% auto-detects (capture has no language parameter); the validated
%% option is carried for provider translators that consume it (the
%% paraformer family follows the same plugin surface).
-spec asr_options(#{binary() => binary()}) -> {ok, #{language => auto | zh | en}} | {error, invalid_language}.
asr_options(Fields) when is_map(Fields) ->
    case maps:get(<<"language">>, Fields, <<"auto">>) of
        <<"auto">> -> {ok, #{language => auto}};
        <<"zh">> -> {ok, #{language => zh}};
        <<"en">> -> {ok, #{language => en}};
        _ -> {error, invalid_language}
    end;
asr_options(_) ->
    {error, invalid_language}.

%% {ok, Transcript} from a decoded upstream chat reply —
%% choices[0].message.content (a binary; silence legitimately answers
%% an empty string). `error` when the shape is absent.
-spec transcript_of(map()) -> {ok, binary()} | error.
transcript_of(Map) when is_map(Map) ->
    case maps:get(<<"choices">>, Map, undefined) of
        [#{<<"message">> := #{<<"content">> := Text}}] when is_binary(Text) ->
            {ok, Text};
        _ ->
            error
    end;
transcript_of(_) ->
    error.

%%%===================================================================
%%% Errors + usage
%%%===================================================================

reject(Req, State, Agent, Route, Status, Code, Msg, Started) ->
    record(Agent, Route, Status, failed, Started),
    reply_error(Req, State, Status, Code, Msg).

reply_error(Req, State, Status, Code, Msg) ->
    janus_modality:reply_json(Req, State, Status, #{
        error => #{message => Msg, type => <<"janus_error">>, code => code_bin(Code)}
    }).

code_bin(Code) when is_binary(Code) -> Code;
code_bin(Code) when is_atom(Code) -> atom_to_binary(Code, utf8).

%% Usage row: modality asr, units NULL in v1 (documented loss — see
%% module doc), outcome completed/failed.
record(Agent, Route, Status, Outcome, Started) ->
    janus_modality:record_usage(
        #{
            ts => erlang:system_time(second),
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null),
            protocol => openai_chat,
            stream => false,
            status => Status,
            latency_ms => erlang:monotonic_time(millisecond) - Started,
            modality => <<"asr">>,
            units => null,
            outcome => Outcome
        },
        Route
    ).

%% Best-effort upstream error message (never relayed raw bodies).
upstream_message(Body) ->
    case janus_modality:parse_json(Body) of
        {ok, #{<<"error">> := #{<<"message">> := M}}} when is_binary(M) -> M;
        {ok, #{<<"error">> := M}} when is_binary(M) -> M;
        _ -> <<"upstream request failed">>
    end.
