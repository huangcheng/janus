%%%-------------------------------------------------------------------
%%% @doc Agent API key auth for Cowboy handlers.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_auth).

-export([require_agent/1, bearer_token/1]).

-spec require_agent(cowboy_req:req()) ->
    {ok, map(), cowboy_req:req()} | {error, cowboy_req:req()}.
require_agent(Req) ->
    case bearer_token(Req) of
        {ok, Token} ->
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
            end;
        error ->
            {error, unauthorized(Req, <<"missing bearer token">>)}
    end.

-spec bearer_token(cowboy_req:req()) -> {ok, binary()} | error.
bearer_token(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Rest/binary>> when Rest =/= <<>> -> {ok, Rest};
        <<"bearer ", Rest/binary>> when Rest =/= <<>> -> {ok, Rest};
        _ -> error
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
