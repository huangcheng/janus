%%%-------------------------------------------------------------------
%%% @doc OpenAI-compatible chat/completions upstream via gun.
%%% Global User-Agent: opencode/2.0.15 (coding-plan allowlists).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_openai).

-export([chat_completions/3, user_agent/0]).

-define(UA, <<"opencode/2.0.15">>).
-define(CONNECT_MS, 5000).
-define(TTFB_MS, 60000).
-define(BODY_MS, 120000).

-spec user_agent() -> binary().
user_agent() ->
    case os:getenv("JANUS_UPSTREAM_UA") of
        false -> ?UA;
        "" -> ?UA;
        Val -> list_to_binary(Val)
    end.

%% Route from janus_lb:pick_route/2 — includes provider_key map.
-spec chat_completions(map(), binary(), map()) ->
    {ok, pos_integer(), map(), binary()}
    | {error, term()}.
chat_completions(Route, Body, ReqMap) when is_map(Route), is_binary(Body), is_map(ReqMap) ->
    case resolve_upstream(Route, ReqMap) of
        {ok, #{
            host := Host, port := Port, path := Path, tls := Tls, token := Token, body := OutBody
        }} ->
            do_post(Host, Port, Path, Tls, Token, OutBody);
        {error, _} = Err ->
            Err
    end.

resolve_upstream(#{provider_id := Pid, provider_key := KeyMeta} = Route, ReqMap) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case decrypt_key(KeyMeta) of
                {ok, Token} ->
                    BaseUrl = iolist_to_binary(BaseUrl0),
                    case parse_base(BaseUrl) of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = join_path(BasePath, <<"/chat/completions">>),
                            UpstreamModel =
                                case maps:get(upstream_model_id, Route, undefined) of
                                    undefined -> maps:get(<<"model">>, ReqMap);
                                    null -> maps:get(<<"model">>, ReqMap);
                                    UM -> UM
                                end,
                            OutMap = ReqMap#{<<"model">> => UpstreamModel, <<"stream">> => false},
                            OutBody = thoas:encode(OutMap),
                            Target = #{
                                provider_id => Pid,
                                key_id => maps:get(id, KeyMeta, undefined)
                            },
                            {ok, #{
                                host => Host,
                                port => Port,
                                path => Path,
                                tls => Tls,
                                token => Token,
                                body => OutBody,
                                target => Target
                            }};
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {ok, #{enabled := false}} ->
            {error, provider_disabled};
        error ->
            {error, provider_not_found}
    end;
resolve_upstream(_, _) ->
    {error, missing_provider_key}.

decrypt_key(#{secret_ref := {_KeyId, Cipher}}) when is_binary(Cipher) ->
    janus_secrets:decrypt(Cipher);
decrypt_key(#{secret_ref := Cipher}) when is_binary(Cipher) ->
    janus_secrets:decrypt(Cipher);
decrypt_key(_) ->
    {error, bad_secret_ref}.

parse_base(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U when
            Scheme =:= <<"https">>;
            Scheme =:= <<"http">>;
            Scheme =:= "https";
            Scheme =:= "http"
        ->
            Tls = scheme_tls(Scheme),
            Port =
                case maps:get(port, U, undefined) of
                    undefined when Tls -> 443;
                    undefined -> 80;
                    P -> P
                end,
            Path0 = maps:get(path, U, <<"/">>),
            Path =
                case Path0 of
                    <<>> -> <<"">>;
                    <<"/">> -> <<"">>;
                    Pth -> iolist_to_binary(Pth)
                end,
            HostBin = iolist_to_binary(Host),
            {ok, binary_to_list(HostBin), Port, Path, Tls};
        Other ->
            {error, {bad_base_url, Other}}
    end.

scheme_tls(<<"https">>) -> true;
scheme_tls("https") -> true;
scheme_tls(_) -> false.

join_path(Base, Suffix) ->
    B =
        case Base of
            <<>> ->
                <<>>;
            _ ->
                case binary:last(iolist_to_binary(Base)) of
                    $/ ->
                        binary:part(
                            iolist_to_binary(Base), 0, byte_size(iolist_to_binary(Base)) - 1
                        );
                    _ ->
                        iolist_to_binary(Base)
                end
        end,
    <<B/binary, Suffix/binary>>.

do_post(Host, Port, Path, Tls, Token, Body) ->
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    Opts = #{
        transport => Transport,
        tls_opts => [{verify, verify_none}],
        connect_timeout => ?CONNECT_MS
    },
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, ?CONNECT_MS) of
                    {ok, _} ->
                        Headers = [
                            {<<"authorization">>, <<"Bearer ", Token/binary>>},
                            {<<"content-type">>, <<"application/json">>},
                            {<<"accept">>, <<"application/json">>},
                            {<<"user-agent">>, user_agent()}
                        ],
                        Stream = gun:post(Conn, Path, Headers, Body),
                        case gun:await(Conn, Stream, ?TTFB_MS) of
                            {response, fin, Status, RespHeaders} ->
                                {ok, Status, headers_map(RespHeaders), <<>>};
                            {response, nofin, Status, RespHeaders} ->
                                case collect_body(Conn, Stream, <<>>) of
                                    {ok, RespBody} ->
                                        {ok, Status, headers_map(RespHeaders), RespBody};
                                    {error, _} = Err ->
                                        Err
                                end;
                            {error, Reason} ->
                                {error, {await, Reason}};
                            Other ->
                                {error, {unexpected_await, Other}}
                        end;
                    {error, Reason} ->
                        {error, {await_up, Reason}}
                end
            after
                gun:close(Conn)
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

collect_body(Conn, Stream, Acc) ->
    case gun:await(Conn, Stream, ?BODY_MS) of
        {data, nofin, Data} ->
            collect_body(Conn, Stream, <<Acc/binary, Data/binary>>);
        {data, fin, Data} ->
            {ok, <<Acc/binary, Data/binary>>};
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

headers_map(Headers) when is_list(Headers) ->
    maps:from_list([{to_lower(K), V} || {K, V} <- Headers]);
headers_map(_) ->
    #{}.

to_lower(B) when is_binary(B) ->
    string:lowercase(B);
to_lower(L) when is_list(L) ->
    string:lowercase(list_to_binary(L)).
