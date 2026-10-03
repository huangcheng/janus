%%%-------------------------------------------------------------------
%%% @doc Logging setup: stdout (Docker-friendly) plus an opt-in rotating
%%% file handler via OTP's built-in `logger_disk_log_h`.
%%%
%%% Why: without file logs you cannot tell which provider or model
%%% failed after a restart (Docker keeps stdout, bare metal does not).
%%% OTP's disk_log handler has native rotation — `max_no_bytes` per
%%% file, `max_no_files` retained — no external logrotate needed.
%%%
%%% Env:
%%%   - `JANUS_LOG_DIR`    — set to enable file logging (e.g. /var/log/janus)
%%%   - `JANUS_LOG_BYTES`  — max bytes per file (default 10 MB)
%%%   - `JANUS_LOG_FILES`  — retained rotated files (default 5)
%%%   - `JANUS_LOG_LEVEL`  — default level (default info)
%%%
%%% Format: single-line with timestamp, level, and the report fields
%%% flattened — greppable and structured (`what` is our event id).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_log).

-export([setup/0]).

-define(DEFAULT_BYTES, 10 * 1024 * 1024).
-define(DEFAULT_FILES, 5).
-define(DEFAULT_LEVEL, info).

-spec setup() -> ok.
setup() ->
    _ = logger:set_primary_config(level, level()),
    _ = remove_std_handler(),
    ok = add_stdout_handler(),
    maybe_add_file_handler().

level() ->
    case os:getenv("JANUS_LOG_LEVEL") of
        Val when is_list(Val), Val =/= [] ->
            try
                list_to_existing_atom(Val)
            catch
                _:_ -> ?DEFAULT_LEVEL
            end;
        _ ->
            application:get_env(kernel, logger_level, ?DEFAULT_LEVEL)
    end.

%% Replace kernel's default handler with our formatted one so stdout
%% gets the same single-line shape as the file.
remove_std_handler() ->
    _ = logger:remove_handler(default),
    ok.

add_stdout_handler() ->
    Config = #{
        level => level(),
        formatter => {janus_log_fmt, #{}},
        %% Drop sasl supervisor progress noise from our handlers.
        filters => [{sas_progress, {fun sas_progress_filter/2, stop}}]
    },
    case logger:add_handler(janus_stdout, logger_std_h, Config) of
        ok -> ok;
        {error, already_present} -> ok
    end.

maybe_add_file_handler() ->
    case log_dir() of
        undefined ->
            logger:info(#{
                what => janus_log_file_disabled,
                hint => "set JANUS_LOG_DIR to enable rotating file logs"
            });
        Dir ->
            File = filename:join(Dir, "janus.log"),
            case filelib:ensure_dir(File) of
                ok ->
                    Config = #{
                        level => level(),
                        formatter => {janus_log_fmt, #{}},
                        filters => [{sas_progress, {fun sas_progress_filter/2, stop}}],
                        config => #{
                            file => File,
                            max_no_bytes => max_bytes(),
                            max_no_files => max_files(),
                            type => halt
                        }
                    },
                    case logger:add_handler(janus_file, logger_disk_log_h, Config) of
                        ok ->
                            logger:info(#{
                                what => janus_log_file_enabled,
                                file => File,
                                max_bytes => max_bytes(),
                                retained_files => max_files()
                            });
                        {error, already_present} ->
                            ok;
                        {error, Reason} ->
                            %% Logging must never block boot; fall back to stdout only.
                            logger:warning(#{what => janus_log_file_failed, reason => Reason})
                    end;
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_log_dir_unwritable,
                        dir => Dir,
                        reason => Reason
                    })
            end
    end.

log_dir() ->
    case os:getenv("JANUS_LOG_DIR") of
        Val when is_list(Val), Val =/= [] -> Val;
        _ -> application:get_env(janus, log_dir, undefined)
    end.

max_bytes() ->
    int_env("JANUS_LOG_BYTES", ?DEFAULT_BYTES).

max_files() ->
    int_env("JANUS_LOG_FILES", ?DEFAULT_FILES).

int_env(Name, Default) ->
    case os:getenv(Name) of
        Val when is_list(Val), Val =/= [] ->
            try
                list_to_integer(Val)
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%% sasl emits progress reports as {report, ...} without our `what` key;
%% drop them so the file stays signal-only.
sas_progress_filter(#{msg := {report, _}} = Event, _) ->
    case maps:get(meta, Event, #{}) of
        #{report_cb := _} -> stop;
        _ -> Event
    end;
sas_progress_filter(Event, _) ->
    Event.
