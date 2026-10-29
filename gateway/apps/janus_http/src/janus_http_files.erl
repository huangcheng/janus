%% @doc /v1/files — the standard OpenAI Files API, gateway-owned.
%%
%% POST   /v1/files            multipart upload (file + purpose field)
%% GET    /v1/files            list (this key's files only)
%% GET    /v1/files/{id}       retrieve metadata
%% GET    /v1/files/{id}/content  raw bytes
%% DELETE /v1/files/{id}       remove (blob shared by sha256 dies with
%%                             its last row)
%%
%% Auth: the same agent-key bearer as /v1/chat; every file belongs to
%% its uploading key — cross-key access answers 404 model_not_found
%% style (existence is not leaked). Knob `files.enabled` (default off)
%% gates the whole surface; knob-off answers 503 files_disabled like
%% the modality gates.
-module(janus_http_files).
-behaviour(cowboy_handler).
-export([init/2]).

-define(MAX_BODY, 200 * 1024 * 1024).

init(Req0, State) ->
    erase(janus_req_counted),
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    %% This face never charges, but a keep-alive-reused process could
    %% carry the PREVIOUS request's nonce — drop it so a future charge
    %% site here can never dedupe against a stale id.
    erase(janus_quota_charge_id),
    case janus_files:enabled() of
        false ->
            reply_json(Req1, State, 503, #{
                error => #{
                    message =>
                        <<"files API disabled on this gateway (settings knob files, default off)">>,
                    type => <<"janus_error">>,
                    code => <<"files_disabled">>
                }
            });
        true ->
            case janus_http_auth:require_agent(Req1) of
                {ok, #{id := AgentKeyId} = _Agent, Req2} ->
                    route(cowboy_req:method(Req2), cowboy_req:path_info(Req2), AgentKeyId, Req2, State);
                {ok, _AgentWithoutId, Req2} ->
                    reply_json(Req2, State, 401, #{
                        error => #{message => <<"agent key has no id">>, type => <<"janus_error">>}
                    });
                {error, ReqErr} ->
                    {ok, ReqErr, State}
            end
    end.

route(<<"POST">>, undefined, AgentKeyId, Req, State) ->
    upload(AgentKeyId, Req, State);
route(<<"POST">>, [], AgentKeyId, Req, State) ->
    upload(AgentKeyId, Req, State);
route(<<"GET">>, undefined, AgentKeyId, Req, State) ->
    list_files(AgentKeyId, Req, State);
route(<<"GET">>, [], AgentKeyId, Req, State) ->
    list_files(AgentKeyId, Req, State);
route(<<"GET">>, [Id], AgentKeyId, Req, State) ->
    case janus_files:fetch(AgentKeyId, Id) of
        {ok, Meta, _Bytes} ->
            reply_json(Req, State, 200, Meta);
        {error, not_found} ->
            not_found(Req, State, Id);
        {error, Reason} ->
            reply_json(Req, State, 500, #{
                error => #{message => fmt(Reason), type => <<"janus_error">>}
            })
    end;
route(<<"GET">>, [Id, <<"content">>], AgentKeyId, Req, State) ->
    case janus_files:fetch(AgentKeyId, Id) of
        {ok, #{content_type := Mime}, Bytes} ->
            Req2 = cowboy_req:reply(
                200,
                #{<<"content-type">> => Mime},
                Bytes,
                Req
            ),
            {ok, Req2, State};
        {error, not_found} ->
            not_found(Req, State, Id);
        {error, Reason} ->
            reply_json(Req, State, 500, #{
                error => #{message => fmt(Reason), type => <<"janus_error">>}
            })
    end;
route(<<"DELETE">>, [Id], AgentKeyId, Req, State) ->
    case janus_files:remove(AgentKeyId, Id) of
        ok ->
            reply_json(Req, State, 200, #{id => Id, object => <<"file">>, deleted => true});
        {error, not_found} ->
            not_found(Req, State, Id);
        {error, Reason} ->
            reply_json(Req, State, 500, #{
                error => #{message => fmt(Reason), type => <<"janus_error">>}
            })
    end;
route(_Method, _Path, _AgentKeyId, Req, State) ->
    reply_json(Req, State, 405, #{
        error => #{message => <<"method not allowed">>, type => <<"invalid_request_error">>}
    }).

upload(AgentKeyId, Req, State) ->
    Ct = cowboy_req:header(<<"content-type">>, Req, <<>>),
    case boundary_of(Ct) of
        {ok, Boundary} ->
            case janus_http_preamble:read_full(Req, ?MAX_BODY) of
                {ok, Body, Req2} ->
                    case janus_multipart:parse(Body, Boundary) of
                        {ok, #{files := [File | _], fields := Fields}} ->
                            Filename = filename_of(File),
                            Mime = mime_of(File, Filename),
                            Bytes = content_of(File),
                            Purpose =
                                case Fields of
                                    #{<<"purpose">> := P} when is_binary(P) -> P;
                                    _ -> <<"file-extract">>
                                end,
                            _ = Purpose,
                            case janus_files:create(AgentKeyId, Filename, Mime, Bytes) of
                                {ok, Obj} ->
                                    reply_json(Req2, State, 200, Obj);
                                {error, too_large} ->
                                    reply_json(Req2, State, 413, #{
                                        error => #{
                                            message => <<"file exceeds the 50 MiB per-file limit">>,
                                            type => <<"invalid_request_error">>,
                                            code => <<"file_too_large">>
                                        }
                                    });
                                {error, quota_exceeded} ->
                                    reply_json(Req2, State, 413, #{
                                        error => #{
                                            message => <<"agent key file quota (2 GiB) exceeded">>,
                                            type => <<"invalid_request_error">>,
                                            code => <<"quota_exceeded">>
                                        }
                                    });
                                {error, empty_file} ->
                                    reply_json(Req2, State, 400, #{
                                        error => #{
                                            message => <<"empty file">>,
                                            type => <<"invalid_request_error">>
                                        }
                                    });
                                {error, Reason} ->
                                    reply_json(Req2, State, 500, #{
                                        error => #{
                                            message => fmt(Reason),
                                            type => <<"janus_error">>
                                        }
                                    })
                            end;
                        {ok, #{files := []}} ->
                            reply_json(Req, State, 400, #{
                                error => #{
                                    message => <<"multipart body carries no file part">>,
                                    type => <<"invalid_request_error">>
                                }
                            });
                        {error, _} ->
                            reply_json(Req, State, 400, #{
                                error => #{
                                    message => <<"malformed multipart body">>,
                                    type => <<"invalid_request_error">>
                                }
                            })
                    end;
                {too_large, Req2} ->
                    reply_json(Req2, State, 413, #{
                        error => #{
                            message => <<"request body exceeds limit">>,
                            type => <<"invalid_request_error">>
                        }
                    })
            end;
        error ->
            reply_json(Req, State, 400, #{
                error => #{
                    message => <<"content-type must be multipart/form-data">>,
                    type => <<"invalid_request_error">>
                }
            })
    end.

list_files(AgentKeyId, Req, State) ->
    {ok, Objs} = janus_files:list(AgentKeyId),
    reply_json(Req, State, 200, #{object => <<"list">>, data => Objs}).

not_found(Req, State, Id) ->
    reply_json(Req, State, 404, #{
        error => #{
            message => <<"The file '", Id/binary, "' does not exist">>,
            type => <<"invalid_request_error">>,
            code => <<"file_not_found">>
        }
    }).

%% ---- helpers ---------------------------------------------------------

boundary_of(<<"multipart/form-data", Rest/binary>>) ->
    case binary:split(Rest, <<"boundary=">>) of
        [_, B] ->
            Boundary = case B of
                <<$", Quoted/binary>> -> binary:part(Quoted, 0, byte_size(Quoted) - 1);
                _ -> B
            end,
            {ok, binary:part(Boundary, 0, index_of($;, Boundary, byte_size(Boundary)))};
        _ ->
            error
    end;
boundary_of(_) ->
    error.

index_of(_C, <<>>, Default) -> Default;
index_of(C, Bin, Default) ->
    case binary:match(Bin, <<C>>) of
        {Pos, _} -> Pos;
        nomatch -> Default
    end.

%% janus_multipart's file parts carry name/filename/content_type/data.
filename_of(#{filename := F}) when is_binary(F), F =/= <<>> -> F;
filename_of(_) -> <<"attachment">>.

mime_of(#{content_type := CT}, _F) when is_binary(CT), CT =/= <<>> -> CT;
mime_of(_, F) -> mime_by_ext(F).

mime_by_ext(F) ->
    case filename:extension(binary_to_list(F)) of
        ".txt" -> <<"text/plain">>;
        ".md" -> <<"text/markdown">>;
        ".json" -> <<"application/json">>;
        ".csv" -> <<"text/csv">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".gif" -> <<"image/gif">>;
        ".pdf" -> <<"application/pdf">>;
        _ -> <<"application/octet-stream">>
    end.

content_of(#{data := D}) when is_binary(D) -> D;
content_of(_) -> <<>>.

reply_json(Req, State, Status, Map) ->
    Body = thoas:encode(Map),
    Req2 = cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        Body,
        Req
    ),
    {ok, Req2, State}.

fmt(T) when is_binary(T) -> T;
fmt(T) -> list_to_binary(io_lib:format("~p", [T])).
