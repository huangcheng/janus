%%%-------------------------------------------------------------------
%%% @doc Single-line log formatter for both stdout and the rotating
%%% file handler. Emits:
%%%
%%%   2026-10-03T14:12:37.178Z info what=janus_http_listen port=8080
%%%
%%% Maps are flattened as `key=value` pairs (nested maps via ~0p);
%%% strings quoted only when they contain spaces.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_log_fmt).

-export([format/2]).

-spec format(logger:log_event(), map()) -> unicode:chardata().
format(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    Ts = format_ts(maps:get(time, Meta, undefined)),
    Fields = msg_fields(Msg) ++ meta_fields(Meta),
    Line = [Ts, <<" ">>, level_str(Level), <<" ">>, fields_str(Fields)],
    [unicode:characters_to_binary(Line), <<"\n">>].

fields_str(Fields) ->
    Parts = [field_str(K, V) || {K, V} <- Fields],
    lists:join(<<" ">>, Parts).

field_str(K, V) ->
    KS = to_bin(K),
    VS = val_str(V),
    case needs_quote(VS) of
        true -> [KS, <<"=\"">>, VS, <<"\"">>];
        false -> [KS, <<"=">>, VS]
    end.

to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(B) when is_binary(B) -> B;
to_bin(Other) -> unicode:characters_to_binary(io_lib:format("~0p", [Other])).

val_str(V) when is_atom(V); is_binary(V); is_integer(V); is_float(V) -> to_bin(V);
val_str(V) -> to_bin(io_lib:format("~0p", [V])).

needs_quote(VS) ->
    binary:match(VS, <<" ">>) =/= nomatch orelse
        binary:match(VS, <<"=">>) =/= nomatch.

level_str(debug) -> <<"debug">>;
level_str(info) -> <<"info">>;
level_str(notice) -> <<"notice">>;
level_str(warning) -> <<"warn">>;
level_str(error) -> <<"error">>;
level_str(critical) -> <<"crit">>;
level_str(alert) -> <<"alert">>;
level_str(emergency) -> <<"emerg">>;
level_str(_) -> <<"info">>.

format_ts(undefined) ->
    <<"1970-01-01T00:00:00.000000Z">>;
format_ts(Timestamp) ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(Timestamp, [
            {unit, microsecond}, {offset, "Z"}
        ])
    ).

msg_fields({string, Chardata}) ->
    [{"msg", Chardata}];
msg_fields({report, Report}) when is_map(Report) ->
    maps:to_list(Report);
msg_fields({Format, Args}) ->
    [{"msg", io_lib:format(Format, Args)}];
msg_fields(_) ->
    [].

%% Reserved logger metadata keys that are not useful per-line.
meta_fields(Meta) ->
    Skip = [time, gl, pid, file, line, mfa, report_cb, domain],
    [KV || {K, _V} = KV <- maps:to_list(Meta), not lists:member(K, Skip)].
