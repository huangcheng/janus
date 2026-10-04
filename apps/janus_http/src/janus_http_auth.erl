%%%-------------------------------------------------------------------
%%% @doc Agent API key auth for Cowboy handlers.
%%% Bearer preferred; `/v1/messages` may also send `x-api-key`.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_auth).

-export([require_agent/1, require_agent/2, bearer_token/1, agent_token/2]).

-spec require_agent(cowboy_req:req()) ->
    {ok, map(), cowboy_req:req()} | {error, cowboy_req:req()}.
require_agent(Req) ->
    require_agent(Req, #{allow_x_api_key => false}).

-spec require_agent(cowboy_req:req(), map()) ->
    {ok, map(), cowboy_req:req()} | {error, cowboy_req:req()}.
require_agent(Req, Opts) when is_map(Opts) ->
    case agent_token(Req, Opts) of
        {ok, Token} ->
            verify_token(Token, Req);
        error ->
            {error, unauthorized(Req, <<"missing bearer token">>)}
    end.

-spec agent_token(cowboy_req:req(), map()) -> {ok, binary()} | error.
agent_token(Req, Opts) ->
    case bearer_token(Req) of
        {ok, _} = Ok ->
            Ok;
        error ->
            case maps:get(allow_x_api_key, Opts, false) of
                true -> x_api_key(Req);
                false -> error
            end
    end.

-spec bearer_token(cowboy_req:req()) -> {ok, binary()} | error.
bearer_token(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Rest/binary>> when Rest =/= <<>> -> {ok, Rest};
        <<"bearer ", Rest/binary>> when Rest =/= <<>> -> {ok, Rest};
        _ -> error
    end.

x_api_key(Req) ->
    case cowboy_req:header(<<"x-api-key">>, Req) of
        Key when is_binary(Key), Key =/= <<>> -> {ok, Key};
        _ -> error
    end.

verify_token(Token, Req) ->
    Prefix = janus_api_keys:prefix(Token),
    case janus_catalog:lookup_api_key(Prefix) of
        {ok, #{enabled := false}} ->
            {error, unauthorized(Req, <<"api key disabled">>)};
        {ok, #{key_hash := Hash} = Meta} ->
            case janus_api_keys:verify(Token, Hash) of
                true -> {ok, Meta, Req};
                false -> {error, unauthorized(Req, <<"invalid api key">>)}
            end;
        error ->
            {error, unauthorized(Req, <<"invalid api key">>)}
    end.

unauthorized(Req, Msg) ->
    Body = thoas:encode(#{
        error => #{
            message => Msg,
            type => <<"authentication_error">>,
            code => <<"unauthorized">>
        }
    }),
    cowboy_req:reply(401, #{<<"content-type">> => <<"application/json">>}, Body, Req).
