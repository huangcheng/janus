-module(janus_http_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port = application:get_env(janus, http_port, 8080),
    Bind = bind("JANUS_HTTP_BIND", http_bind),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", janus_http_health, []},
            {"/readyz", janus_http_ready, []},
            {"/v1/models", janus_http_models, []},
            {"/v1/chat/completions", janus_http_chat, []},
            {"/v1/responses", janus_http_responses, []},
            {"/v1/messages", janus_http_messages, []},
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
    %% Admin plane: read-only stats for the standalone dashboard to poll.
    %% Token-authenticated (JANUS_STATS_TOKEN); no UI, no write API.
    AdminPort = application:get_env(janus, admin_port, 8090),
    AdminBind = bind("JANUS_ADMIN_BIND", admin_bind),
    AdminDispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", janus_http_health, []},
            {"/stats", janus_gateway_stats, []},
            {"/stats/[...]", janus_gateway_stats, []},
            {"/metrics", janus_http_metrics, []}
        ]}
    ]),
    %% idle_timeout must exceed the longest legitimate upstream wait
    %% (reasoning models can compute for minutes before first byte) —
    %% cowboy's 60s default kills the handler mid-call with a bare
    %% connection reset (surfaced as a bodiless 502 behind a proxy).
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
    LogTail = #{
        id => janus_log_tail,
        start => {janus_log_tail, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_log_tail]
    },
    AdminListener = #{
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
    },
    logger:info(#{
        what => janus_http_listen, data_port => Port, admin_port => AdminPort
    }),
    {ok, {
        #{strategy => one_for_one, intensity => 5, period => 10},
        [AutoRouter, Listener, LogTail, AdminListener]
    }}.

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
