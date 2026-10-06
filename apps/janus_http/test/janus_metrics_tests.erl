-module(janus_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    janus_metrics:init(),
    ets:delete_all_objects(janus_metrics).

cumulative_buckets_test() ->
    setup(),
    janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, 0.4),
    Rows = janus_metrics:snapshot(),
    %% 0.4s lands in 0.5, 1, 2.5, … +Inf — cumulative: every bound >= 0.4.
    ?assertEqual(1, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"0.5">>}, Rows)),
    ?assertEqual(0, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"0.25">>}, Rows)),
    ?assertEqual(1, get({hist, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}], <<"+Inf">>}, Rows)),
    ?assertEqual(400000, get({hist_sum_us, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)),
    ?assertEqual(1, get({hist_count, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)).

negative_clamp_test() ->
    setup(),
    janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, -1.0),
    Rows = janus_metrics:snapshot(),
    ?assertEqual(0, get({hist_sum_us, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)),
    ?assertEqual(1, get({hist_count, request_duration_seconds, [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}]}, Rows)).

label_normalization_test() ->
    setup(),
    %% provider name as a LIST (DB charlist) must not crash or drop.
    janus_metrics:inc(upstream_requests_total, #{provider => "acme", status_class => <<"2xx">>}),
    Rows = janus_metrics:snapshot(),
    ?assertEqual(1, get({counter, upstream_requests_total, [{<<"provider">>, <<"acme">>}, {<<"status_class">>, <<"2xx">>}]}, Rows)).

init_idempotent_test() ->
    janus_metrics:init(),
    janus_metrics:init(),
    ?assert(lists:any(fun(T) -> T =:= janus_metrics end, ets:all())).

concurrent_observe_final_consistency_test() ->
    setup(),
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat, stream => 0}, 0.3),
            Self ! done
        end)
     || _ <- lists:seq(1, 500)
    ],
    [receive done -> ok end || _ <- Pids],
    Rows = janus_metrics:snapshot(),
    L = [{<<"protocol">>, <<"openai_chat">>}, {<<"stream">>, <<"0">>}],
    Count = get({hist_count, request_duration_seconds, L}, Rows),
    Inf = get({hist, request_duration_seconds, L, <<"+Inf">>}, Rows),
    ?assertEqual(500, Count),
    ?assertEqual(Count, Inf),
    ?assert(Inf >= get({hist, request_duration_seconds, L, <<"0.5">>}, Rows)).

never_crashes_without_table_test() ->
    janus_metrics:init(),
    ets:delete(janus_metrics),
    ?assertEqual(ok, janus_metrics:inc(requests_total, #{endpoint => chat})),
    ?assertEqual(ok, janus_metrics:observe(request_duration_seconds, #{protocol => openai_chat}, 0.5)),
    ?assertEqual([], janus_metrics:snapshot()),
    ?assertEqual(ok, janus_metrics:inc(not_atom_label_test, #{bogus => self()})),
    janus_metrics:init().

get(K, Rows) ->
    case lists:keyfind(K, 1, Rows) of
        {_, V} -> V;
        false -> 0
    end.
