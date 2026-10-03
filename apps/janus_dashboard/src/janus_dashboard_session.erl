%%%-------------------------------------------------------------------
%%% @doc Dashboard console sessions: password login, CSRF tokens, per-IP
%%% lockout. The gen_server owns the ETS tables and prunes expired
%%% rows; the hot path (login/validate/logout) runs in the caller
%%% against the public tables.
%%%
%%% Config (`janus_dashboard` app env / env vars):
%%%   - password: string (default `JANUS_DASHBOARD_PASSWORD`; unset ⇒
%%%     fail closed — login always refuses)
%%%   - ttl_sec: session lifetime (default 43200 = 12h)
%%%   - max_fails / fail_window_sec / lockout_sec (5 / 900 / 900)
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dashboard_session).

-behaviour(gen_server).

-export([start_link/0]).
-export([login/2, validate/1, logout/1, password_configured/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, ?MODULE).
-define(DEFAULT_TTL, 43200).
-define(DEFAULT_MAX_FAILS, 5).
-define(DEFAULT_WINDOW, 900).
-define(DEFAULT_LOCKOUT, 900).
-define(PRUNE_MS, 60_000).

%% {Token, Csrf, ExpiresAt, Ip}
%% {<<"fail|", Ip/binary>>, Fails, WindowStart, LockUntil}

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec login(binary(), binary()) ->
    {ok, Token :: binary(), Csrf :: binary()} | {error, locked, pos_integer()} |
    {error, invalid | not_configured}.
login(Password, Ip) when is_binary(Password), is_binary(Ip) ->
    ensure_table(),
    case locked(Ip) of
        {true, Retry} ->
            {error, locked, Retry};
        false ->
            case dashboard_password() of
                {ok, Actual} ->
                    case constant_time_eq(Password, Actual) of
                        true ->
                            ets:delete(?TAB, fail_key(Ip)),
                            Token = b64url(crypto:strong_rand_bytes(32)),
                            Csrf = b64url(crypto:strong_rand_bytes(32)),
                            ExpiresAt = now_sec() + ttl(),
                            true = ets:insert(?TAB, {Token, Csrf, ExpiresAt, Ip}),
                            {ok, Token, Csrf};
                        false ->
                            _ = note_fail(Ip),
                            {error, invalid}
                    end;
                not_configured ->
                    {error, not_configured}
            end
    end.

-spec validate(binary()) -> {ok, Csrf :: binary()} | error.
validate(Token) when is_binary(Token) ->
    ensure_table(),
    Now = now_sec(),
    case ets:lookup(?TAB, Token) of
        [{Token, Csrf, ExpiresAt, _Ip}] when ExpiresAt > Now ->
            {ok, Csrf};
        [{Token, _, _, _}] ->
            ets:delete(?TAB, Token),
            error;
        [] ->
            error
    end.

-spec logout(binary()) -> ok.
logout(Token) when is_binary(Token) ->
    ensure_table(),
    ets:delete(?TAB, Token),
    ok.

-spec password_configured() -> boolean().
password_configured() ->
    dashboard_password() =/= not_configured.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    ensure_table(),
    _ = erlang:send_after(?PRUNE_MS, self(), prune),
    case password_configured() of
        true -> ok;
        false ->
            logger:warning(#{
                what => janus_dashboard_no_password,
                hint => "set JANUS_DASHBOARD_PASSWORD to enable dashboard logins"
            })
    end,
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(prune, State) ->
    prune(),
    _ = erlang:send_after(?PRUNE_MS, self(), prune),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal
%%%===================================================================

ensure_table() ->
    case ets:whereis(?TAB) of
        undefined ->
            try
                ets:new(?TAB, [
                    named_table, set, public,
                    {read_concurrency, true}, {write_concurrency, true}
                ])
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end.

fail_key(Ip) ->
    <<"fail|", Ip/binary>>.

locked(Ip) ->
    Now = now_sec(),
    case ets:lookup(?TAB, fail_key(Ip)) of
        [{_, _, _, LockUntil}] when LockUntil > Now ->
            {true, LockUntil - Now};
        _ ->
            false
    end.

note_fail(Ip) ->
    Now = now_sec(),
    MaxFails = max_fails(),
    Window = window(),
    Lockout = lockout(),
    _ = ets:update_counter(?TAB, fail_key(Ip), {2, 1}, {fail_key(Ip), 0, Now, 0}),
    case ets:lookup(?TAB, fail_key(Ip)) of
        [{_, Fails, WindowStart, LockUntil}] when LockUntil =< Now ->
            if
                Now - WindowStart >= Window ->
                    ets:update_element(?TAB, fail_key(Ip), [{2, 1}, {3, Now}, {4, 0}]);
                Fails >= MaxFails ->
                    ets:update_element(?TAB, fail_key(Ip), [{4, Now + Lockout}]);
                true ->
                    ok
            end;
        _ ->
            ok
    end.

prune() ->
    try
        Now = now_sec(),
        _ = [
            ets:delete(?TAB, Row)
         || Row <- ets:tab2list(?TAB), prune_row(Row, Now)
        ],
        ok
    catch
        error:badarg -> ok
    end.

%% session row: {Token, Csrf, ExpiresAt, Ip}
prune_row({Token, _Csrf, ExpiresAt, _Ip}, Now)
    when is_binary(Token), is_integer(ExpiresAt) ->
    ExpiresAt =< Now;
%% failure row: {<<"fail|…">>, Fails, WindowStart, LockUntil}
prune_row({<<"fail|", _/binary>>, _Fails, Ws, Lu}, Now)
    when is_integer(Ws), is_integer(Lu) ->
    max(Ws, Lu) + window() < Now;
prune_row(_, _) ->
    false.

%%% config

dashboard_password() ->
    FromEnv = fun(Key) ->
        case application:get_env(janus_dashboard, Key, undefined) of
            P when is_binary(P), P =/= <<>> -> {ok, P};
            P when is_list(P), P =/= [] -> {ok, unicode:characters_to_binary(P)};
            _ -> not_configured
        end
    end,
    case os:getenv("JANUS_DASHBOARD_PASSWORD") of
        Val when is_list(Val), Val =/= [] -> {ok, unicode:characters_to_binary(Val)};
        _ -> FromEnv(password)
    end.

ttl() -> pos_env(ttl_sec, ?DEFAULT_TTL).
max_fails() -> pos_env(max_fails, ?DEFAULT_MAX_FAILS).
window() -> pos_env(fail_window_sec, ?DEFAULT_WINDOW).
lockout() -> pos_env(lockout_sec, ?DEFAULT_LOCKOUT).

pos_env(Key, Default) ->
    case application:get_env(janus_dashboard, Key, Default) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end.

constant_time_eq(A, B) when is_binary(A), is_binary(B) ->
    Mac = fun(X) -> crypto:mac(hmac, sha256, <<"janus-dashboard-pw">>, X) end,
    crypto:hash_equals(Mac(A), Mac(B));
constant_time_eq(_, _) ->
    false.

now_sec() ->
    erlang:system_time(second).

b64url(Bin) when is_binary(Bin) ->
    B64 = base64:encode(Bin),
    << <<(b64url_char(C))/binary>> || <<C>> <= B64, C =/= $= >>.

b64url_char($+) -> <<"-">>;
b64url_char($/) -> <<"_">>;
b64url_char(C) -> <<C>>.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

login_lockout_test() ->
    ok = application:set_env(janus_dashboard, password, <<"pw-test-123">>),
    try
        Ip = <<"10.9.9.9">>,
        [begin {error, invalid} = login(<<"wrong">>, Ip) end
         || _ <- lists:seq(1, 5)],
        {error, locked, _} = login(<<"pw-test-123">>, Ip),
        %% a different IP is unaffected
        {ok, _, _} = login(<<"pw-test-123">>, <<"10.9.9.8">>)
    after
        application:unset_env(janus_dashboard, password)
    end.

session_lifecycle_test() ->
    ok = application:set_env(janus_dashboard, password, <<"pw-test-123">>),
    try
        {ok, Token, Csrf} = login(<<"pw-test-123">>, <<"127.0.0.1">>),
        {ok, Csrf} = validate(Token),
        ok = logout(Token),
        error = validate(Token)
    after
        application:unset_env(janus_dashboard, password)
    end.

expiry_test() ->
    ensure_table(),
    %% inject an already-expired session
    true = ets:insert_new(?TAB, {<<"tok-expired">>, <<"csrf">>, 1, <<"ip">>}),
    error = validate(<<"tok-expired">>).

not_configured_test() ->
    OsPw = os:getenv("JANUS_DASHBOARD_PASSWORD"),
    try
        os:unsetenv("JANUS_DASHBOARD_PASSWORD"),
        application:unset_env(janus_dashboard, password),
        {error, not_configured} = login(<<"x">>, <<"127.0.0.1">>)
    after
        case OsPw of
            false -> ok;
            V -> os:putenv("JANUS_DASHBOARD_PASSWORD", V)
        end
    end.

-endif.
