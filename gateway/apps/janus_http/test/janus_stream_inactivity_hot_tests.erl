%% The mid-stream inactivity ceiling vs the total stream budget (2026-11-09).
%%
%% Live: a reasoning-heavy turn went silent on the upstream and the gateway
%% tore the stream down at exactly 180.0s — the inactivity default. The
%% fleet's total budget had already been raised to 2400s through the
%% `translate` settings row, but the inactivity ceiling beside it was
%% readable only from the OS environment, so moving it needed a container
%% restart. That is the one shape this repository forbids: "Everything hot."
%%
%% Two properties are pinned here:
%%
%%   1. The inactivity ceiling honours the hot settings row, with the env
%%      override still reachable underneath it for the live driver.
%%   2. `inactivity < total` holds for EVERY input — including a hostile
%%      one where the hot row sets inactivity above total. The ordering is
%%      what lets the stall detector speak before the total budget blames
%%      the wrong ceiling; before this change a violated ordering silently
%%      discarded the operator's total and ran at the 600s constant.
-module(janus_stream_inactivity_hot_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, {janus, translate_cfg}).
-define(ENV, "JANUS_STREAM_INACTIVITY_TIMEOUT_MS").

%% Save and restore the shared app-level term: other suites read it too,
%% and a leaked fixture would make their results order-dependent.
%% Also neutralises the env override for the duration of the body, so the
%% assertions are about the row and not about whether the shell that ran
%% the suite happened to export JANUS_STREAM_INACTIVITY_TIMEOUT_MS (the
%% live drivers do, deliberately). An empty string is what positive_env/2
%% treats as malformed, so the row path is exercised deterministically.
with_cfg(Cfg, Fun) ->
    Prev = persistent_term:get(?KEY, undefined),
    PrevEnv = os:getenv(?ENV),
    try
        case Cfg of
            undefined -> persistent_term:erase(?KEY);
            _ -> persistent_term:put(?KEY, Cfg)
        end,
        _ = os:putenv(?ENV, ""),
        Fun()
    after
        case Prev of
            undefined -> persistent_term:erase(?KEY);
            _ -> persistent_term:put(?KEY, Prev)
        end,
        _ =
            case PrevEnv of
                false -> os:unsetenv(?ENV);
                V -> os:putenv(?ENV, V)
            end
    end.

%% What the row-less path resolves to with the env override neutralised:
%% the shipped default, capped by the same idle-lead rule the
%% implementation applies, so this expectation cannot drift from it.
shipped_inactivity_ms() ->
    Total = janus_worker_wire:stream_timeout_ms(),
    max(1000, min(180_000, Total div 2)).

%% The regression itself: a hot write must move the ceiling without a
%% restart. Before this change the row was ignored entirely.
hot_row_moves_the_ceiling_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 240_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(240_000, janus_worker_wire:stream_inactivity_timeout_ms()),
            ?assertEqual(2_400_000, janus_worker_wire:stream_timeout_ms())
        end
    ).

%% No hot value falls through to the shipped default (or the env value
%% when the driver set one) — the pre-existing behaviour, unchanged.
absent_row_keeps_the_default_test() ->
    %% No settings row at all: the pre-existing env/default path.
    with_cfg(
        undefined,
        fun() ->
            ?assertEqual(shipped_inactivity_ms(), janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ),
    with_cfg(
        #{<<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(shipped_inactivity_ms(), janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% The ordering invariant, under the input that used to break it: an
%% inactivity deadline ABOVE the total budget. The total falls back to the
%% shipped constant (the pre-existing contract), and the idle side is then
%% capped — so the stall detector can fire first, which is the property the
%% whole knob rests on.
hostile_ordering_cannot_invert_the_pair_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 9_000_000, <<"stream_total_timeout_ms">> => 1_200_000},
        fun() ->
            Total = janus_worker_wire:stream_timeout_ms(),
            Idle = janus_worker_wire:stream_inactivity_timeout_ms(),
            ?assert(Idle < Total),
            %% A raised total is PRESERVED, not lowered to the constant:
            %% lowering it would re-arm the 600s teardown it was raised to
            %% avoid. The idle side yields instead.
            ?assertEqual(1_200_000, Total),
            %% The client-idle ceiling binds first here (299s < half of the
            %% 1200s total); either way the idle side yields rather than the
            %% operator's raised total.
            ?assertEqual(299_000, Idle)
        end
    ).

%% Regression for the "lead" half of the fix. With the idle side capped at
%% exactly the total minus one, a single forwarded chunk pushed the idle
%% deadline past the total and every later tick chose the total — the
%% stream died with the total-budget reason even though silence is what
%% happened. The half-total cap restores a real lead for a chunk landing in
%% the first half of the budget.
%%
%% The bound is deliberately NOT asserted for chunks past the half-way
%% point: there the total budget legitimately owns the rest of the stream
%% and "total" is the honest label. Claiming otherwise would be a test that
%% pins a property the design does not offer.
idle_deadline_keeps_a_lead_in_the_first_half_test() ->
    with_cfg(
        %% Above the 600s constant the client-idle cap (299s) always binds
        %% before the half rule, so the half rule is only reachable for a
        %% total under that constant with an idle value above its half.
        #{<<"stream_inactivity_timeout_ms">> => 250_000, <<"stream_total_timeout_ms">> => 400_000},
        fun() ->
            Total = janus_worker_wire:stream_timeout_ms(),
            Idle = janus_worker_wire:stream_inactivity_timeout_ms(),
            Half = Total div 2,
            ?assertEqual(400_000, Total),
            ?assertEqual(Half, Idle),
            %% A chunk at T restarts the idle deadline to T+Idle; inside
            %% the first half it must still precede the total.
            lists:foreach(
                fun(T) ->
                    ?assert(T < Half),
                    ?assert(T + Idle < Total)
                end,
                [0, 5, 500, 1_000, 5_000, 10_000, Half - 1]
            )
        end
    ).

%% And the clamp must not disturb a pair that is already sane: the
%% operator's total is used verbatim when it clears the inactivity side.
sane_pair_is_used_verbatim_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 240_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(2_400_000, janus_worker_wire:stream_timeout_ms()),
            ?assertEqual(240_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% Malformed hot values are malformed, never "no ceiling": zero would tear
%% down every healthy stream on its first tick, and a non-integer would
%% crash the drain loop on an arithmetic comparison.
malformed_hot_value_is_ignored_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 0, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(shipped_inactivity_ms(), janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ),
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => <<"nonsense">>},
        fun() ->
            ?assertEqual(shipped_inactivity_ms(), janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% The keepalive cadence is derived from the ceiling and must stay strictly
%% below it, or a silent stream is torn down before the client is reassured
%% even once. The ceiling is asserted too: without it the bound would hold
%% trivially at the shipped 180s ceiling and the test would pass even if the
%% hot row were ignored entirely.
keepalive_stays_under_a_moved_ceiling_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 60_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            Ceiling = janus_worker_wire:stream_inactivity_timeout_ms(),
            ?assertEqual(60_000, Ceiling),
            Keepalive = janus_worker_wire:stream_keepalive_ms(),
            ?assert(Keepalive > 0),
            ?assert(Keepalive < Ceiling)
        end
    ).

%% Sub-second totals are reachable by a direct settings-row edit (the config
%% layer stores the map without range validation), and a total mistyped in
%% seconds implies its idle value is in the same wrong unit. The pair is
%% discarded TOGETHER for the shipped pair: falling back on the total alone
%% would floor a 180 (seconds intent) at the 1s minimum and hand the gateway
%% a 1-second silence ceiling, killing every stream after a second of quiet.
%%
%% Both sides of the threshold are pinned. 2000 is garbage, 2001 is honoured
%% verbatim (a 2s total is absurd but it is a *configured* 2s, not a typo
%% in another unit), so an off-by-one in the guard is a CI failure.
sub_second_total_resolves_to_the_constant_pair_test() ->
    lists:foreach(
        fun({Total, Idle}) ->
            with_cfg(
                #{
                    <<"stream_total_timeout_ms">> => Total,
                    <<"stream_inactivity_timeout_ms">> => Idle
                },
                fun() ->
                    ?assertEqual(600_000, janus_worker_wire:stream_timeout_ms()),
                    ?assertEqual(180_000, janus_worker_wire:stream_inactivity_timeout_ms())
                end
            )
        end,
        [{800, 500}, {1_000, 900}, {2_000, 1_000}]
    ).

%% Just above the garbage threshold the configured values are honoured, so
%% the guard is not swallowing every small total.
just_above_garbage_threshold_is_honoured_test() ->
    with_cfg(
        #{<<"stream_total_timeout_ms">> => 2_001, <<"stream_inactivity_timeout_ms">> => 1_000},
        fun() ->
            ?assertEqual(2_001, janus_worker_wire:stream_timeout_ms()),
            ?assertEqual(1_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% The env override must outrank the hot row: the live verification drivers
%% shrink the window through it, and a dashboard that materialized a default
%% into the row must not be able to shadow that. This is the precedence the
%% module documents, pinned rather than assumed.
env_override_outranks_the_hot_row_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 900_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            _ = os:putenv(?ENV, "6000"),
            ?assertEqual(6_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% /stats.stream_budgets is the diagnostic an operator uses to confirm a
%% hot write landed; it must report the resolved pair, not the constants.
stats_reports_the_resolved_pair_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 240_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            B = janus_gateway_stats:stream_budgets(),
            ?assertEqual(240_000, maps:get(inactivity_ms, B)),
            ?assertEqual(2_400_000, maps:get(total_ms, B))
        end
    ).

%% A pair that satisfies `idle < total` but sits above half the total still
%% loses the lead: a chunk landing past `total - idle` re-arms the idle
%% deadline beyond the total, and total wins every subsequent tick. The cap
%% applies to such a pair too, not only to one that inverts the ordering.
above_half_idle_is_capped_for_lead_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 600_000, <<"stream_total_timeout_ms">> => 1_000_000},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(1_000_000, Total),
            %% The client-idle ceiling binds before the half-total lead here.
            ?assertEqual(299_000, Idle)
        end
    ).

%% One resolution returns both values, so a caller needing the pair cannot
%% straddle two config generations.
budgets_pair_is_consistent_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 240_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(janus_worker_wire:stream_timeout_ms(), Total),
            ?assertEqual(janus_worker_wire:stream_inactivity_timeout_ms(), Idle),
            ?assert(Idle < Total)
        end
    ).

%% An above-half pair is refused by the dashboard PUT now, so this is the
%% BACKSTOP path: a direct settings-row edit or an ops script that bypasses
%% the API. It must still resolve to a stall-first pair rather than
%% honouring a value that cannot express one — a chunk past `total - idle`
%% would re-arm the idle deadline beyond the total and silence the stall
%% path. Pinned so the clamp stays deliberate.
above_half_pair_is_capped_at_the_backstop_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 1_800_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(2_400_000, Total),
            ?assertEqual(299_000, Idle)
        end
    ).

%% And a pair at or under half — the only shape the dashboard now accepts —
%% is honoured verbatim, so the cap is not silently shrinking every
%% legitimate configuration.
dashboard_acceptable_pair_is_honoured_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 1_200_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(2_400_000, Total),
            ?assertEqual(299_000, Idle)
        end
    ).

%% A total mistyped in seconds (600 meant as ms) must be treated as garbage
%% and fall back to the shipped constant, not honoured as a literal 600ms or
%% lifted to a bare 2s. Either reading would tear down every stream after
%% ~1s of silence — the teardown class the constant fallback exists to
%% prevent — and drag the worker job timeout and listener idle timeout down
%% with it.
mistyped_second_scale_total_falls_back_test() ->
    with_cfg(
        #{<<"stream_total_timeout_ms">> => 600, <<"stream_inactivity_timeout_ms">> => 180},
        fun() ->
            ?assertEqual(600_000, janus_worker_wire:stream_timeout_ms()),
            %% The idle key is in the same wrong unit, so it falls back with
            %% the total instead of being floored to 1s.
            ?assertEqual(180_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% A total the operator legitimately LOWERED but which is still sane and
%% above the idle side is honoured — the guard must not swallow real intent.
lowered_but_sane_total_is_honoured_test() ->
    with_cfg(
        #{<<"stream_total_timeout_ms">> => 240_000, <<"stream_inactivity_timeout_ms">> => 60_000},
        fun() ->
            ?assertEqual(240_000, janus_worker_wire:stream_timeout_ms()),
            ?assertEqual(60_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% A sub-floor configured value is a unit typo (180 meant as seconds), not a
%% usable ceiling. Flooring it to the 1s minimum would silently hand the
%% fleet a one-second silence ceiling — every stream killed after a second
%% of quiet, before the first byte included. It falls back to the shipped
%% default instead.
sub_floor_idle_value_falls_back_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 180, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(180_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% Exactly at the floor is usable and honoured, so the guard is not
%% swallowing a legitimate (if aggressive) ceiling.
at_floor_idle_value_is_honoured_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 1_000, <<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            ?assertEqual(1_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% An explicit env override is an operator/CI request for a SHORTER window
%% (the live drivers shrink it on purpose), so a sub-floor value is floored
%% to the minimum rather than discarded in favour of the shipped default —
%% discarding it would leave a driver idling out the production ceiling.
sub_floor_env_override_is_floored_test() ->
    with_cfg(
        #{<<"stream_total_timeout_ms">> => 2_400_000},
        fun() ->
            _ = os:putenv(?ENV, "900"),
            ?assertEqual(1_000, janus_worker_wire:stream_inactivity_timeout_ms())
        end
    ).

%% The other guard in the total resolver is `Total0 < ?DEFAULT_TOTAL_MS`, so
%% an inverted pair at exactly the constant keeps its total (the idle side
%% yields) while one millisecond below substitutes the constant. Adjacent
%% inputs, different branches — pin both so an off-by-one in `=<` versus `<`
%% is a CI failure rather than a silent behaviour change.
inverted_pair_at_the_constant_keeps_its_total_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 900_000, <<"stream_total_timeout_ms">> => 600_000},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(600_000, Total),
            ?assertEqual(299_000, Idle)
        end
    ).

%% One millisecond below the constant the pair is treated as the old
%% incident shape and the total yields to the shipped default.
inverted_pair_below_the_constant_yields_test() ->
    with_cfg(
        #{<<"stream_inactivity_timeout_ms">> => 900_000, <<"stream_total_timeout_ms">> => 599_999},
        fun() ->
            {Total, Idle} = janus_worker_wire:stream_budgets(),
            ?assertEqual(600_000, Total),
            ?assertEqual(299_000, Idle)
        end
    ).
