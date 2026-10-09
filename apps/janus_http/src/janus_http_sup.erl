-module(janus_http_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
%% Agent-face registry read by /readyz (write-gate advertisement,
%% Decisions spec §4.3) and by eunit.
-export([agent_routes/0, agent_protocols/0, publish_agent_protocols/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Agent face registry — the SINGLE source for (a) the cowboy agent
%% dispatch entries and (b) the `protocols` list /readyz advertises at
%% listener start (dashboard write gate polls it before allowing
%% Decisions provider writes; captured from the handler modules
%% registered for agent routes, unauthenticated like healthz —
%% accepted disclosure, §4.3).
-spec agent_routes() -> [{string(), module(), atom()}].
agent_routes() ->
    [
        {"/v1/chat/completions", janus_http_chat, openai_chat},
        {"/v1/responses", janus_http_responses, openai_responses},
        {"/v1/messages", janus_http_messages, anthropic_messages},
        %% Fourth agent face (D1): native Decisions passthrough.
        {"/v1/decisions", janus_http_decisions, openai_decisions}
    ].

%% Sorted unique protocol binaries advertised on /readyz. Kept in
%% persistent_term at supervisor init (boot-order-safe convention —
%% readyz may be scraped before any handler ran).
-spec agent_protocols() -> [binary()].
agent_protocols() ->
    persistent_term:get({janus, agent_protocols}, []).

publish_agent_protocols() ->
    Protocols =
        lists:usort([atom_to_binary(Proto, utf8) || {_, _, Proto} <- agent_routes()]),
    persistent_term:put({janus, agent_protocols}, Protocols),
    ok.

init([]) ->
    Role = janus_role:get(),
    ok = publish_agent_protocols(),
    Port = application:get_env(janus, http_port, 8080),
    AdminPort = application:get_env(janus, admin_port, 8090),
    AdminBind = bind("JANUS_ADMIN_BIND", admin_bind),
    LogTail = log_tail_child(),
    Children =
        case Role of
            worker -> worker_http_children(AdminPort, AdminBind, LogTail);
            master -> master_http_children(Port, AdminPort, AdminBind, LogTail)
        end,
    {ok, {
        #{strategy => one_for_one, intensity => 5, period => 10},
        Children
    }}.

%% Worker: no public agent :8080 (spec §3.2). Optional loopback-only
%% admin when JANUS_ADMIN_BIND / admin_bind is set explicitly.
worker_http_children(AdminPort, AdminBind, LogTail) ->
    logger:info(#{
        what => janus_http_listen,
        role => worker,
        agent_port => skipped,
        admin_port => admin_port_log(AdminPort, AdminBind)
    }),
    case admin_listener_child(AdminPort, AdminBind) of
        undefined -> [LogTail];
        AdminListener -> [LogTail, AdminListener]
    end.

master_http_children(Port, AdminPort, AdminBind, LogTail) ->
    Bind = bind("JANUS_HTTP_BIND", http_bind),
    AgentDispatch = [{Path, Handler, []} || {Path, Handler, _Proto} <- agent_routes()],
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", janus_http_health, []},
            {"/readyz", janus_http_ready, []},
            {"/v1/models", janus_http_models, []}
        ] ++ AgentDispatch ++ [
            %% Modality plugins (spec 2026-10-07): static dispatch,
            %% each route fronts one plugin module.
            {"/v1/images/generations", janus_http_modality, [janus_m_images]},
            {"/v1/audio/speech", janus_http_modality, [janus_m_audio_speech]},
            {"/v1/audio/transcriptions", janus_http_modality, [janus_m_audio_asr]},
            %% Video (spec M3): the exact route takes the POST submit;
            %% the [...]-route lets the plugin path-switch GET/DELETE
            %% on cowboy path_info ([Jvid] poll/cancel, [Jvid,
            %% <<"content">>] download).
            {"/v1/videos", janus_http_modality, [janus_m_video]},
            {"/v1/videos/[...]", janus_http_modality, [janus_m_video]}
        ]}
    ]),
    AdminDispatch = admin_dispatch(),
    ProtocolOpts = #{
        env => #{dispatch => Dispatch},
        idle_timeout => 300_000
    },
    AdminProtocolOpts = #{
        env => #{dispatch => AdminDispatch},
        idle_timeout => 300_000
    },
    AutoRouter = #{
        id => janus_auto,
        start => {janus_auto, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_auto]
    },
    Listener = #{
        id => janus_http_listener,
        start =>
            {cowboy, start_clear, [
                janus_http_listener,
                transport_opts(Port, Bind),
                ProtocolOpts
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cowboy]
    },
    AdminListener = admin_listener_spec(AdminPort, AdminBind, AdminProtocolOpts),
    logger:info(#{
        what => janus_http_listen,
        role => master,
        data_port => Port,
        admin_port => AdminPort
    }),
    [AutoRouter, Listener, LogTail, AdminListener].

admin_dispatch() ->
    cowboy_router:compile([
        {'_', [
            {"/healthz", janus_http_health, []},
            {"/stats", janus_gateway_stats, []},
            {"/stats/fleet/command", janus_http_fleet, []},
            {"/stats/[...]", janus_gateway_stats, []},
            {"/metrics", janus_http_metrics, []}
        ]}
    ]).

admin_listener_spec(AdminPort, AdminBind, AdminProtocolOpts) ->
    #{
        id => janus_admin_listener,
        start =>
            {cowboy, start_clear, [
                janus_admin_listener,
                transport_opts(AdminPort, AdminBind),
                AdminProtocolOpts
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cowboy]
    }.

%% Explicit bind only — default (all interfaces) is skipped on workers.
admin_listener_child(AdminPort, undefined) ->
    undefined;
admin_listener_child(AdminPort, AdminBind) ->
    admin_listener_spec(AdminPort, AdminBind, #{
        env => #{dispatch => admin_dispatch()},
        idle_timeout => 300_000
    }).

admin_port_log(_AdminPort, undefined) ->
    skipped;
admin_port_log(AdminPort, _AdminBind) ->
    AdminPort.

log_tail_child() ->
    #{
        id => janus_log_tail,
        start => {janus_log_tail, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_log_tail]
    }.

transport_opts(Port, undefined) ->
    [{port, Port}];
transport_opts(Port, Ip) when is_tuple(Ip) ->
    [{port, Port}, {ip, Ip}].

bind(EnvName, AppKey) ->
    case os:getenv(EnvName) of
        Val when is_list(Val), Val =/= [] ->
            parse_ip(Val);
        _ ->
            case application:get_env(janus, AppKey, undefined) of
                undefined -> undefined;
                Ip when is_tuple(Ip) -> Ip;
                Str -> parse_ip(Str)
            end
    end.

parse_ip(Bin) when is_binary(Bin) -> parse_ip(binary_to_list(Bin));
parse_ip(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Ip} -> Ip;
        {error, _} -> {0, 0, 0, 0}
    end.
