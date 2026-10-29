-module(janus_http_ready).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Ready = janus_config:ready(),
    Status =
        case Ready of
            true -> 200;
            false -> 503
        end,
    Body = thoas:encode(#{
        ready => Ready,
        generation => janus_config:generation(),
        backend => janus_db:select_backend(),
        %% Agent protocols this node serves (captured at cowboy
        %% listener start from the agent-route handler registry,
        %% janus_http_sup:agent_routes/0). The dashboard write gate
        %% requires EVERY node to advertise openai_decisions here
        %% before a Decisions provider may be created/enabled
        %% (§4.3). Unauthenticated disclosure accepted (same public
        %% health surface as healthz).
        protocols => janus_http_sup:agent_protocols()
    }),
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>
        },
        Body,
        Req0
    ),
    {ok, Req, State}.
