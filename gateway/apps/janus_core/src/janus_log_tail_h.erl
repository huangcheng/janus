%%%-------------------------------------------------------------------
%%% @doc logger handler that mirrors events into the janus_log_tail
%%% ring. Kept tiny: flatten the report to a map and push via the
%%% owning gen_server (serialized index assignment).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_log_tail_h).

-export([log/2, adding_handler/1, removing_handler/1]).

%% no filtering config; janus_log_tail sets the level
adding_handler(Config) -> {ok, Config}.
removing_handler(_Config) -> ok.

log(#{level := Level, msg := Msg, meta := #{report_cb := _}} = _Event, _Config) ->
    %% sasl progress reports — skip (kept out of the tail, same as file).
    ok;
log(#{level := Level, msg := Msg, meta := Meta} = _Event, _Config) ->
    Fields = event_fields(Msg) ++ [KV || {K, _V} = KV <- maps:to_list(Meta),
        not lists:member(K, [time, gl, pid, file, line, mfa, report_cb, domain])],
    Ts = case maps:get(time, Meta, undefined) of
        undefined -> 0;
        T -> unicode:characters_to_binary(
            calendar:system_time_to_rfc3339(T, [{unit, microsecond}, {offset, "Z"}]))
    end,
    janus_log_tail:push(#{
        idx => 0,  %% assigned by the gen_server
        ts => Ts,
        level => Level,
        fields => maps:map(fun(_K, V) -> json_safe(V) end, maps:from_list(Fields))
    }).

%% thoas cannot encode funs/pids/refs/tuples — stringify them.
json_safe(V) when is_binary(V); is_atom(V); is_integer(V); is_float(V) -> V;
json_safe(V) when is_list(V); is_map(V); is_tuple(V) ->
    unicode:characters_to_binary(io_lib:format("~0p", [V]));
json_safe(_) ->
    <<>>.

event_fields({string, Chardata}) ->
    [{msg, Chardata}];
event_fields({report, Report}) when is_map(Report) ->
    maps:to_list(Report);
event_fields({Format, Args}) ->
    [{msg, io_lib:format(Format, Args)}];
event_fields(_) ->
    [].
