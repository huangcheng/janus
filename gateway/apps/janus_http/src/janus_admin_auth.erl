%%%-------------------------------------------------------------------
%%% @doc Shared admin-plane auth (/stats + /metrics): Bearer token via
%%% JANUS_STATS_TOKEN / janus.stats_token, constant-time compare;
%%% loopback-only fallback when no token is configured.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_admin_auth).

-export([authorize/1]).

authorize(Req0) ->
    case stats_token() of
        undefined ->
            %% No token configured: allow only loopback connections.
            {{Ip, _Port} = _Peer} = cowboy_req:peer(Req0),
            case is_loopback(Ip) of
                true -> ok;
                false -> {error, unauthorized(Req0, <<"stats token not configured; loopback only">>)}
            end;
        Token ->
            case bearer_token(Req0) of
                {ok, Got} ->
                    case token_eq(Got, Token) of
                        true -> ok;
                        false -> {error, unauthorized(Req0, <<"invalid or missing stats token">>)}
                    end;
                error ->
                    {error, unauthorized(Req0, <<"invalid or missing stats token">>)}
            end
    end.

bearer_token(Req) ->
    case cowboy_req:header(<<"authorization">>, Req) of
        Bin when is_binary(Bin) ->
            case binary:split(Bin, <<" ">>) of
                [Scheme, Rest] when Rest =/= <<>> ->
                    case string:lowercase(Scheme) of
                        <<"bearer">> -> {ok, Rest};
                        _ -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

token_eq(Got, Want) when byte_size(Got) =:= byte_size(Want) ->
    crypto:hash_equals(Got, Want);
token_eq(_, _) ->
    false.

stats_token() ->
    case os:getenv("JANUS_STATS_TOKEN") of
        Val when is_list(Val), Val =/= [] -> list_to_binary(Val);
        _ ->
            case application:get_env(janus, stats_token, undefined) of
                B when is_binary(B), B =/= <<>> -> B;
                L when is_list(L), L =/= [] -> list_to_binary(L);
                _ -> undefined
            end
    end.

is_loopback({127, 0, 0, 1}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

unauthorized(Req, Msg) ->
    Body = thoas:encode(#{
        error => #{code => <<"unauthorized">>, message => Msg}
    }),
    cowboy_req:reply(401, #{
        <<"content-type">> => <<"application/json">>,
        <<"www-authenticate">> => <<"Bearer">>
    }, Body, Req).
