%%%-------------------------------------------------------------------
%%% @doc POST /stats/fleet/command — the admin-plane entry to the
%%% closed-enum fleet command channel (native-distribution spec F.1).
%%% Same token auth as every /stats route (janus_admin_auth). Boundary
%%% change (operator sign-off, spec): :8090 goes from read-only to
%%% hosting IDEMPOTENT fleet commands — every invocation audited.
%%%
%%% Body: {"command": "fleet_status"}
%%%       {"command": "lb_cool_clear",
%%%        "target": {"kind": "route", "model": 7, "provider": 3}}
%%% Response: {"command": ..., "outcome": ok|partial|error,
%%%            "results": {"<node>": <per-node result>}}
%%% Unknown name or bad args: local 400, zero peers contacted.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_fleet).

-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 65536).

init(Req0, State) ->
    Req =
        case janus_admin_auth:authorize(Req0) of
            ok ->
                handle(cowboy_req:method(Req0), Req0);
            {error, Req1} ->
                Req1
        end,
    {ok, Req, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

handle(<<"POST">>, Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_BODY}) of
        {ok, Body, Req1} ->
            case thoas:decode(Body) of
                {ok, #{<<"command">> := Command} = Json} when is_binary(Command) ->
                    Arg = arg_from_json(Json),
                    execute(Command, Arg, Req1);
                {ok, _} ->
                    bad_request(<<"missing command">>, Req1);
                _ ->
                    bad_request(<<"invalid json">>, Req1)
            end;
        {more, _, Req1} ->
            bad_request(<<"body too large">>, Req1)
    end;
handle(_Method, Req) ->
    cowboy_req:reply(405, #{
        <<"content-type">> => <<"application/json">>,
        <<"allow">> => <<"POST">>
    }, thoas:encode(#{error => #{code => <<"method_not_allowed">>}}), Req).

execute(Command, Arg, Req) ->
    case janus_fleet_commands:execute(Command, Arg) of
        {ok, #{results := Results, outcome := Outcome}} ->
            Nodes = maps:fold(
                fun(Node, Res, Acc) ->
                    Acc#{atom_to_binary(Node, utf8) => result_json(Res)}
                end,
                #{},
                Results
            ),
            reply_json(200, #{
                command => Command,
                outcome => Outcome,
                results => Nodes
            }, Req);
        {error, unknown_command} ->
            %% No fan-out happened (registry gate) — counter-asserted.
            bad_request(<<"unknown command">>, Req);
        {error, {bad_arg, target}} ->
            bad_request(<<"invalid target">>, Req);
        {error, not_exported} ->
            bad_request(<<"command not available on this node (version skew)">>, Req);
        {error, _Other} ->
            bad_request(<<"bad request">>, Req)
    end.

result_json({ok, V}) ->
    case is_json_deep(V) of
        true -> #{ok => V};
        false -> #{ok => fmt(V)}
    end;
result_json({error, Reason}) when is_atom(Reason); is_binary(Reason) ->
    #{error => Reason};
result_json({error, Class, Reason}) ->
    #{error => fmt({Class, Reason})};
result_json(Other) ->
    #{ok => fmt(Other)}.

is_json_deep(V) when is_map(V) ->
    lists:all(fun({_K, X}) -> is_json_deep(X) end, maps:to_list(V));
is_json_deep(V) when is_list(V) ->
    lists:all(fun is_json_deep/1, V);
is_json_deep(V) when is_binary(V); is_number(V); is_boolean(V); V =:= null ->
    true;
is_json_deep(V) when is_atom(V) ->
    true;
is_json_deep(_) ->
    false.

fmt(T) ->
    unicode:characters_to_binary(io_lib:format("~0p", [T])).

arg_from_json(#{<<"target">> := Target} = Json) ->
    case decode_target(Target) of
        {ok, T} -> #{target => T};
        error -> Json#{<<"target">> => bad_target}
    end;
arg_from_json(_Json) ->
    #{}.

%% JSON target encoding for lb_cool_clear (the wire cannot carry
%% tuples): {"kind": "route", "model": M|null, "provider": P} |
%% {"kind": "provider", "provider": P} | {"kind": "provider_key",
%% "key": K} | {"kind": "listing", "name": N}. Validation of the
%% decoded shape happens in the registry (before ANY fan-out).
decode_target(#{<<"kind">> := <<"route">>} = T) ->
    case {maps:get(<<"model">>, T, null), val(maps:get(<<"provider">>, T, null))} of
        {null, P} when P =/= null -> {ok, {route, P}};
        {M, P} when M =/= null, P =/= null -> {ok, {route, M, P}};
        _ -> error
    end;
decode_target(#{<<"kind">> := <<"provider">>} = T) ->
    case val(maps:get(<<"provider">>, T, null)) of
        P when P =/= null -> {ok, {provider, P}};
        _ -> error
    end;
decode_target(#{<<"kind">> := <<"provider_key">>} = T) ->
    case val(maps:get(<<"key">>, T, null)) of
        K when K =/= null -> {ok, {provider_key, K}};
        _ -> error
    end;
decode_target(#{<<"kind">> := <<"listing">>, <<"name">> := N}) when
    is_binary(N), N =/= <<>>
->
    {ok, {listing, N}};
decode_target(_) ->
    error.

val(V) when is_integer(V); is_binary(V) -> V;
val(_) -> null.

bad_request(Msg, Req) ->
    reply_json(400, #{error => #{code => <<"bad_request">>, message => Msg}}, Req).

reply_json(Status, Map, Req) ->
    Body = thoas:encode(Map),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req).
