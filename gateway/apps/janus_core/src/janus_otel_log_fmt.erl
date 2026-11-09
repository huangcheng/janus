%%%-------------------------------------------------------------------
%%% @doc A formatter that produces nothing.
%%%
%%% `janus_otel_logs' is a logger handler that EXPORTS events; it has no
%%% device to write to. `logger' requires a formatter for every handler, so
%%% this one exists to be empty: rendering would duplicate the formatted
%%% line the stdout handler already emits, once per log line, for no reader.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_log_fmt).

-export([format/2]).

%% @doc Consume the event and render nothing.
-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(_Event, _Config) ->
    <<>>.
