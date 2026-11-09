#!/usr/bin/env bash
# Conformance gate for the OpenTelemetry work (design doc §13.2).
#
# Each check pins something the per-request E2E scripts cannot see: that a
# rule holds across ALL families/fields, not just the one a request
# happened to exercise. A rule only ever asserted on one example rots
# silently the first time a new example is added without it.
#
# Usage:  ./scripts/verification/otel_conformance.sh
#
# Exit 77 when the environment cannot run it (no toolchain / no build).
set -u -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GW="$(cd "$HERE/../.." && pwd)"

command -v erl >/dev/null 2>&1 || { echo "SKIP: erl not found"; exit 77; }
[ -d "$GW/_build/default/lib/janus_http/ebin" ] || {
  echo "SKIP: build absent - run 'rebar3 compile' in $GW first"; exit 77
}

EBINS=(); for d in "$GW"/_build/default/lib/*/ebin; do EBINS+=(-pa "$d"); done

# Run from a scratch directory: booting an application may create files
# (SQLite), and a gate must not leave anything in the working tree.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"
pass=0; fail=0

# Run one check: the erl program prints exactly one PASS/FAIL line.
# stderr is captured separately and surfaced only on failure, so a crash
# cannot be mistaken for a passing check by matching on stdout alone.
check() {
  local label="$1" prog="$2" out rc err
  err="$(mktemp)"
  out=$(erl -noshell "${EBINS[@]}" -eval "$prog" 2>"$err")
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1))
    printf '  FAIL %s: erl exited %s\n' "$label" "$rc"
    head -5 "$err" | sed 's/^/  stderr: /'
    rm -f "$err"
    return
  fi
  rm -f "$err"
  case "$(printf '%s' "$out" | grep -E '^(PASS|FAIL)' | tail -1)" in
    PASS*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)) ;;
  esac
}

# C1 — every registered family declares a unit, and no unit is orphaned.
#
# Both directions matter: a family without a unit exports with no `unit'
# field (a consumer reads that as "unknown scale"), and a unit entry left
# behind after a family is deleted is a stale claim that the next reader
# will trust.
check "unit coverage" '
  Fam = janus_metrics_render:family_names(),
  Un = janus_metrics_render:units(),
  Missing = [N || N <- Fam, not maps:is_key(N, Un)],
  Orphan = [N || N <- maps:keys(Un), not lists:member(N, Fam)],
  Bogus = [N || {N, U} <- maps:to_list(Un), not is_binary(U) orelse byte_size(U) =:= 0],
  case {Missing, Orphan, Bogus} of
    {[], [], []} ->
      io:format("PASS every family declares a unit and no unit is orphaned (~p families)~n", [length(Fam)]);
    _ ->
      io:format("FAIL unit coverage: missing=~p orphaned=~p empty=~p~n", [Missing, Orphan, Bogus])
  end,
  halt().'

# C2 — a unit string must be UCUM, not prose. The specific mistake this
# blocks is `seconds'/'milliseconds'/'bytes': they look right and are wrong
# for OTLP, which specifies UCUM (`s', `ms', `By').
check "units are UCUM" '
  Un = janus_metrics_render:units(),
  Prose = [<<"seconds">>, <<"milliseconds">>, <<"microseconds">>, <<"nanoseconds">>,
           <<"bytes">>, <<"count">>, <<"counts">>, <<"percent">>, <<"percentage">>,
           <<"ratio">>],
  Bad = lists:usort([U || {_N, U} <- maps:to_list(Un), lists:member(U, Prose)]),
  case Bad of
    [] -> io:format("PASS units are UCUM, not prose~n");
    _ -> io:format("FAIL non-UCUM units: ~p~n", [Bad])
  end,
  halt().'

# C3 — the HELP unit suffix is OPT-IN. With the knob off no unit may
# appear; with it on, at least the unit of the family exercised here must.
# That is enough to catch the suffix leaking in unconditionally, which is
# the failure mode this gate exists for; C1 already proves every family
# HAS a unit, so per-unit rendering is not re-proven here.
check "help text respects the knob" '
  application:set_env(janus, sqlite_path, os:getenv("CONF_DB", "janus_conf.db")),
  ok = janus_metrics:init(),
  janus_metrics:inc(requests_total, #{endpoint => chat, protocol => openai_chat, status_class => <<"2xx">>}),
  os:putenv("JANUS_METRICS_HELP_UNITS", "0"),
  Plain = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  os:putenv("JANUS_METRICS_HELP_UNITS", "1"),
  WithUnit = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  OffHas = string:find(Plain, "(unit:") =/= nomatch,
  OnHas = string:find(WithUnit, "(unit: {request})") =/= nomatch,
  case {OffHas, OnHas} of
    {false, true} -> io:format("PASS HELP units are opt-in and complete when enabled~n");
    {true, _} -> io:format("FAIL unit suffix leaked into the default output~n");
    {_, false} -> io:format("FAIL unit suffix missing when the knob is on~n")
  end,
  halt().'

# C4 -- the "tier" label vocabulary is closed.
#
# The design (F13) requires enum validation at the PRODUCER, not reliance
# on the renderer series cap: a label is meant to be a closed enum by
# contract, and a cap is only a safety net. This feeds known tiers and
# deliberately bad ones to the real bump path and inspects what reached the
# metric.
check "metric labels are closed enums" '
  ok = janus_metrics:init(),
  Feed = fun(V) ->
           put(janus_auto_tier, V),
           janus_http_proxy:bump_auto_name_failover()
         end,
  TierOf = fun(L) ->
            [_Before, After0] = string:split(L, "tier=\"", leading),
            [V | _] = string:split(After0, "\""),
            V
          end,
  Snapshot = fun() ->
               Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
               Lines = [L || L <- string:split(Out, "\n", all), string:find(L, "tier=") =/= nomatch],
               lists:usort([TierOf(L) || L <- Lines])
             end,
  [Feed(V) || V <- [fast, big, flagship]],
  SeenIn = Snapshot(),
  [Feed(V) || V <- [<<"fast">>, typo_tier, <<"free form">>, 42]],
  SeenAll = Snapshot(),
  InEnum = ["fast", "big", "flagship"],
  Allowed = InEnum ++ ["unknown"],
  MissingIn = [T || T <- InEnum, not lists:member(T, SeenIn)],
  Escaped = [V || V <- SeenAll, not lists:member(V, Allowed)],
  Mapped = lists:member("unknown", SeenAll),
  if
    SeenAll =:= [] ->
      io:format("FAIL tier label: no series observed (vacuous pass)~n");
    MissingIn =/= [] ->
      io:format("FAIL tier label over-restricted: ~p missing from ~p~n", [MissingIn, SeenIn]);
    Escaped =/= [] ->
      io:format("FAIL tier label escaped the enum: ~p~n", [Escaped]);
    not Mapped ->
      io:format("FAIL off-enum values were dropped, not mapped: saw ~p~n", [SeenAll]);
    true ->
      io:format("PASS tier label keeps in-enum values and maps the rest (~p values)~n",
                [length(SeenAll)])
  end,
  halt().'

# C5 -- the semconv histograms use their PRESCRIBED ladders, byte-exact
# and in order, while the legacy histogram keeps its own.
#
# Two failure modes this exists for: an approximating ladder (the design
# calls this out as the thing to prevent), and a ladder edit that silently
# changes every published percentile on the legacy series that the
# deployed Grafana panels compute quantiles over.
check "semconv ladders are exact" '
  Legacy = [Le || {_B, Le} <- janus_metrics:buckets()],
  Http = [Le || {_B, Le} <- janus_metrics:buckets(http_server_request_duration)],
  Gen = [Le || {_B, Le} <- janus_metrics:buckets(gen_ai_client_inference_duration)],
  WantHttp = [<<"0.005">>, <<"0.01">>, <<"0.025">>, <<"0.05">>, <<"0.075">>,
              <<"0.1">>, <<"0.25">>, <<"0.5">>, <<"0.75">>, <<"1">>,
              <<"2.5">>, <<"5">>, <<"7.5">>, <<"10">>],
  WantGen = [<<"0.01">>, <<"0.02">>, <<"0.04">>, <<"0.08">>, <<"0.16">>,
             <<"0.32">>, <<"0.64">>, <<"1.28">>, <<"2.56">>, <<"5.12">>,
             <<"10.24">>, <<"20.48">>, <<"40.96">>, <<"81.92">>],
  %% The legacy ladder is a published contract: four Grafana panels compute
  %% histogram_quantile over it. Pinned literally so an edit cannot slip in.
  WantLegacy = [<<"0.05">>, <<"0.1">>, <<"0.25">>, <<"0.5">>, <<"1">>,
                <<"2.5">>, <<"5">>, <<"10">>, <<"30">>, <<"60">>,
                <<"120">>, <<"300">>, <<"600">>],
  if
    Http =/= WantHttp ->
      io:format("FAIL http.server.request.duration ladder is not the prescribed one: ~p~n", [Http]);
    Gen =/= WantGen ->
      io:format("FAIL gen_ai.client.inference.duration ladder is not the prescribed one: ~p~n", [Gen]);
    Legacy =/= WantLegacy ->
      io:format("FAIL legacy duration ladder changed (breaks published quantiles): ~p~n", [Legacy]);
    true ->
      io:format("PASS semconv ladders exact; legacy ladder unchanged~n")
  end,
  halt().'

# C6 -- with the export knob OFF, the semconv families must not appear.
#
# Design 13.4: new families are additive and gated, so a knob-off
# deployment sees no content change in /metrics. This asserts the gate
# rather than trusting it.
check "semconv families are knob-gated" '
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  os:unsetenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"),
  ok = janus_metrics:init(),
  L = #{<<"http.request.method">> => <<"POST">>, <<"url.scheme">> => <<"https">>},
  janus_metrics:observe(http_server_request_duration, L, 1.0),
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  Hits = length([X || X <- string:split(Out, "\n", all),
                       string:find(X, "http_server_request_duration") =/= nomatch]),
  OffOk = case {janus_telemetry:export_enabled(), Hits} of
            {false, 0} -> ok;
            {false, N} -> {fail, {knob_off_but_rendered, N}};
            {true, _} -> {fail, {knob_misread_as_enabled, true}}
          end,
  %% And the gate must OPEN: with an endpoint configured the same row has
  %% to appear, or "gated" would just mean "never emitted".
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  Out2 = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  Hits2 = length([X || X <- string:split(Out2, "\n", all),
                        string:find(X, "http_server_request_duration") =/= nomatch]),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  case {OffOk, Hits2 > 0} of
    {ok, true} ->
      io:format("PASS knob gates semconv families (absent off, present on)~n");
    {ok, false} ->
      io:format("FAIL knob on but semconv families still absent~n");
    {{fail, Why}, _} ->
      io:format("FAIL knob gate broken: ~p~n", [Why])
  end,
  halt().'

# C7 -- every label name the exposition emits is a LEGAL Prometheus label.
#
# A dotted name (the OTel spelling) makes the whole /metrics body
# unparseable, not just that series, so every scrape of the fleet fails.
# Asserted over the rendered text rather than over the call sites, because
# a new producer can add a label without touching an existing call site.
check "prometheus label names are legal" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  %% The OTel spellings are fed ON PURPOSE: the registry must transliterate
  %% them, so a producer that forgets cannot break the exposition.
  Http = #{<<"http.request.method">> => <<"POST">>, <<"url.scheme">> => <<"https">>},
  GenAi = #{<<"gen_ai.operation.name">> => <<"chat">>,
            <<"gen_ai.provider.name">> => <<"mockprov">>},
  janus_metrics:observe(http_server_request_duration, Http, 1.0),
  janus_metrics:observe(gen_ai_client_inference_duration, GenAi, 1.0),
  %% A legacy family too, so the parser is exercised on the ordinary shape.
  janus_metrics:inc(requests_total, #{endpoint => chat, protocol => openai_chat,
                                      status_class => <<"2xx">>}),
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  %% Walk every non-comment line, take the text between { and }, split on
  %% commas, and keep the part before =. That covers every label of every
  %% series, including the `le` bucket label.
  Groups = [begin
              Rest0 = lists:nthtail(string:str(L, "{"), L),
              [Inner | _] = string:split(Rest0, "}"),
              Inner
            end || L <- string:split(Out, "\n", all),
                   not lists:prefix("#", L),
                   string:str(L, "{") > 0],
  Pairs = lists:append([string:split(G, ",") || G <- Groups]),
  Names0 = [hd(string:split(P, "=")) || P <- Pairs, string:str(P, "=") > 0],
  Names = lists:usort([N || N <- Names0, N =/= ""]),
  Legal = fun(N) -> re:run(N, "^[a-zA-Z_][a-zA-Z0-9_]*$", [{capture, none}]) =:= match end,
  Bad = [N || N <- Names, not Legal(N)],
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  case Bad of
    [] when length(Names) >= 4 ->
      io:format("PASS all rendered label names are legal (~p checked)~n", [length(Names)]);
    [] ->
      io:format("FAIL label scan found only ~p names (vacuous)~n", [length(Names)]);
    _ ->
      io:format("FAIL illegal Prometheus label names: ~p~n", [Bad])
  end,
  halt().'

# C8 -- the HTTP-duration instrument reports a real status code and its
# scheme, produced by the PRODUCER rather than hand-fed here.
#
# Driving the producer matters: an earlier version of this check fed the
# label map itself, so deleting an attribute from the producer left the
# check green. It now calls `observe_http_server_duration/3'.
check "http duration producer emits the required attributes" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  put(janus_req_method, <<"GET">>),
  janus_http_proxy:observe_http_server_duration(200, false, 1000),
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  Mine = [X || X <- string:split(Out, "\n", all),
               string:find(X, "http_server_request_duration_bucket") =/= nomatch],
  Has = fun(Frag) -> length([X || X <- Mine, string:find(X, Frag) =/= nomatch]) > 0 end,
  Method = Has("http_request_method=\"GET\""),
  Status = Has("http_response_status_code=\"200\""),
  Scheme = Has("url_scheme=\"http\""),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  case {Mine, Method, Status, Scheme} of
    {[], _, _, _} ->
      io:format("FAIL http duration: no series rendered at all~n");
    {_, true, true, true} ->
      io:format("PASS http duration producer emits method, scheme and status~n");
    {_, M, St, Sc} ->
      io:format("FAIL http duration attributes: method=~p status=~p scheme=~p~n", [M, St, Sc])
  end,
  halt().'

# C9 -- the HTTP method label cannot be used to create series.
#
# Cowboy's parser accepts ANY HTTP token, so the method is client-supplied
# and unbounded. Left raw it would let a caller mint a time series per
# request. Unknown verbs must collapse to the semconv `_OTHER'.
check "http method label is bounded" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  Feed = fun(M) ->
           put(janus_req_method, M),
           janus_http_proxy:observe_http_server_duration(200, false, 1000)
         end,
  [Feed(M) || M <- [<<"GET">>, <<"PATCH">>, <<"ARBITRARY">>, <<"x">>, <<"">>]],
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  Seen = lists:usort([begin
                        [_B, A0] = string:split(L, "http_request_method=\"", leading),
                        [V | _] = string:split(A0, "\""),
                        V
                      end || L <- string:split(Out, "\n", all),
                             string:find(L, "http_request_method=") =/= nomatch]),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  Allowed = ["GET", "PATCH", "_OTHER"],
  Extra = [V || V <- Seen, not lists:member(V, Allowed)],
  HasOther = lists:member("_OTHER", Seen),
  case {Seen, Extra, HasOther} of
    {[], _, _} ->
      io:format("FAIL http method: no series rendered~n");
    {_, [_ | _], _} ->
      io:format("FAIL client-supplied verbs became labels: ~p~n", [Extra]);
    {_, [], false} ->
      io:format("FAIL unknown verbs not mapped to _OTHER: ~p~n", [Seen]);
    {_, [], true} ->
      io:format("PASS http method label is bounded (~p values)~n", [length(Seen)])
  end,
  halt().'

# C10 -- the GenAI operation label follows the published protocol.
#
# The bug this exists for: `Route' carries only provider/key/model ids, so
# reading the protocol off it always yielded the fallback, and the label was
# a constant that no dashboard could have detected. The check drives the
# producer with a non-chat protocol, which is the only way to tell a live
# mapping from a hardcoded string.
check "genai operation follows the protocol" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  [begin
     put(janus_upstream_proto, P),
     put(janus_upstream_ms, 1200),
     janus_http_proxy:maybe_observe_genai_duration(#{})
   end || P <- [image, embeddings]],
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  Seen = lists:usort([begin
                        [_B, A0] = string:split(L, "gen_ai_operation_name=\"", leading),
                        [V | _] = string:split(A0, "\""),
                        V
                      end || L <- string:split(Out, "\n", all),
                             string:find(L, "gen_ai_operation_name=") =/= nomatch]),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  Want = ["embeddings", "generate_content"],
  case {Seen, lists:sort(Seen) =:= Want} of
    {[], _} ->
      io:format("FAIL genai operation: no series rendered~n");
    {_, true} ->
      io:format("PASS genai operation follows the protocol (~p)~n", [Seen]);
    {_, false} ->
      io:format("FAIL genai operation is constant, not derived: ~p (want ~p)~n", [Seen, Want])
  end,
  halt().'

# C11 -- the token counters carry the mandated labels and the mandated
# exception, and report the actual counts.
#
# Required by the design: `gen_ai.token.modality' on all four token
# counters, mandated `unknown' (providers fold image/audio into
# prompt_tokens, so inferring `text' would fabricate a dimension);
# `gen_ai.request.model' as a discriminator; and `reasoning.output_tokens'
# must NOT appear (it dropped modality on 2026-11-05 and the gateway does
# not account for it separately).
check "token counters carry modality, model and counts" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  put(janus_upstream_proto, openai_chat),
  put(janus_req_model, <<"mock-model">>),
  %% cache_read = 0, cache_write = 11: the two directions of the
  %% non-zero-only rule are then both observable.
  janus_http_proxy:observe_genai_tokens(#{provider_id => 1}, 5298, 66, 0, 11),
  Out = binary_to_list(janus_metrics_render:render(janus_metrics:snapshot(), [])),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  Series = [X || X <- string:split(Out, "\n", all),
                 string:find(X, "gen_ai_client_inference_usage") =/= nomatch,
                 not lists:prefix("#", X)],
  Val = fun(Frag) ->
          case [X || X <- Series, string:find(X, Frag) =/= nomatch] of
            [Line | _] ->
              [_M, V] = string:split(Line, "} "),
              V;
            [] ->
              missing
          end
        end,
  Has = fun(Frag) -> Val(Frag) =/= missing end,
  IfNoMod = [X || X <- Series, string:find(X, "gen_ai_token_modality=\"unknown\"") =:= nomatch],
  IfNoModel = [X || X <- Series, string:find(X, "gen_ai_request_model=\"mock-model\"") =:= nomatch],
  Reasoning = lists:any(fun(X) ->
                           string:find(X, "reasoning_output_tokens") =/= nomatch
                         end, string:split(Out, "\n", all)),
  %% An if-guard cannot call a fun, so each check is reduced to a boolean
  %% first and the decision is a plain case expression.
  NoSeries = Series =:= [],
  BadMod = IfNoMod =/= [],
  BadModel = IfNoModel =/= [],
  HasIn = Has("usage_input_tokens_total{"),
  HasOut = Has("usage_output_tokens_total{"),
  HasCw = Has("cache_write_input_tokens_total{"),
  HasCr = Has("cache_read_input_tokens_total{"),
  InV = Val("usage_input_tokens_total{"),
  OutV = Val("usage_output_tokens_total{"),
  CwV = Val("cache_write_input_tokens_total{"),
  case {NoSeries, BadMod, BadModel, Reasoning, HasIn, HasOut, HasCw, HasCr,
        InV, OutV, CwV} of
    {true, _, _, _, _, _, _, _, _, _, _} ->
      io:format("FAIL token counters: nothing rendered~n");
    {_, true, _, _, _, _, _, _, _, _, _} ->
      io:format("FAIL token series without modality=unknown~n");
    {_, _, true, _, _, _, _, _, _, _, _} ->
      io:format("FAIL token series without gen_ai.request.model~n");
    {_, _, _, true, _, _, _, _, _, _, _} ->
      io:format("FAIL reasoning.output_tokens must not be emitted~n");
    {_, _, _, _, false, _, _, _, _, _, _} ->
      io:format("FAIL input_tokens counter absent~n");
    {_, _, _, _, _, false, _, _, _, _, _} ->
      io:format("FAIL output_tokens counter absent~n");
    {_, _, _, _, _, _, false, _, _, _, _} ->
      io:format("FAIL cache_write counter absent for a non-zero count~n");
    {_, _, _, _, _, _, _, true, _, _, _} ->
      io:format("FAIL cache_read emitted for a zero count~n");
    {_, _, _, _, _, _, _, _, InV2, _, _} when InV2 =/= "5298" ->
      io:format("FAIL input_tokens value ~p (want 5298)~n", [InV]);
    {_, _, _, _, _, _, _, _, _, OutV2, _} when OutV2 =/= "66" ->
      io:format("FAIL output_tokens value ~p (want 66)~n", [OutV]);
    {_, _, _, _, _, _, _, _, _, _, CwV2} when CwV2 =/= "11" ->
      io:format("FAIL cache_write value ~p (want 11)~n", [CwV]);
    _ ->
      io:format("PASS token counters carry modality+model and report counts; zero cache omitted~n")
  end,
  halt().'

# C12 -- the OTLP metrics view encodes the shape the data model requires.
#
# Three things a backend cannot recover from if wrong: CUMULATIVE
# temporality on every counter (delta would double-count a lifetime total),
# `isMonotonic' on sums (without it a rate is not computable), and
# `explicitBounds' one shorter than `bucketCounts' (the last count is the
# +Inf overflow). A histogram encoded as one metric per bucket would look
# fine in JSON and be rejected by every consumer.
check "otlp metrics encode the required shape" '
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:14318"),
  ok = janus_metrics:init(),
  janus_metrics:inc(requests_total, #{endpoint => chat, protocol => openai_chat,
                                      status_class => <<"2xx">>}),
  janus_metrics:observe(http_server_request_duration,
                        #{<<"http.request.method">> => <<"POST">>}, 0.042),
  Rows = janus_metrics:snapshot(),
  Enc = janus_otel_otlp:encode_metrics(Rows, [], #{<<"service.name">> => <<"janus">>},
                                       1700000000000000000),
  os:unsetenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
  Ms = maps:get(<<"metrics">>,
                hd(maps:get(<<"scopeMetrics">>,
                            hd(maps:get(<<"resourceMetrics">>, Enc))))),
  Counter = [M || M <- Ms, maps:is_key(<<"sum">>, M),
                  maps:get(<<"name">>, M) =:= <<"janus.requests_total">>],
  Hist = [M || M <- Ms, maps:is_key(<<"histogram">>, M)],
  SumOk = case Counter of
            [C | _] ->
              Sm = maps:get(<<"sum">>, C),
              maps:get(<<"aggregationTemporality">>, Sm) =:= 2 andalso
                  maps:get(<<"isMonotonic">>, Sm) =:= true andalso
                  maps:get(<<"unit">>, C) =:= <<"{request}">>;
            [] -> false
          end,
  Enc2 = janus_otel_otlp:encode_metrics(Rows, [], #{<<"service.name">> => <<"janus">>},
                                        1700000000000000000),
  DpOf = fun(E) ->
           Ms2 = maps:get(<<"metrics">>,
                          hd(maps:get(<<"scopeMetrics">>,
                                      hd(maps:get(<<"resourceMetrics">>, E))))),
           H2 = hd([M || M <- Ms2, maps:is_key(<<"histogram">>, M)]),
           hd(maps:get(<<"dataPoints">>, maps:get(<<"histogram">>, H2)))
         end,
  StableStart = maps:get(<<"startTimeUnixNano">>, DpOf(Enc)) =:=
                    maps:get(<<"startTimeUnixNano">>, DpOf(Enc2)),
  HistOk = case Hist of
             [H | _] ->
               Dp = hd(maps:get(<<"dataPoints">>, maps:get(<<"histogram">>, H))),
               Bounds = maps:get(<<"explicitBounds">>, Dp),
               Counts = maps:get(<<"bucketCounts">>, Dp),
               %% The wire spec requires sum(bucketCounts) == count. A
               %% cumulative-copied set would exceed it by a growing
               %% factor, and every consumer rejects the point.
               Sum = lists:sum([binary_to_integer(C) || C <- Counts]),
               PointCount = binary_to_integer(maps:get(<<"count">>, Dp)),
               length(Bounds) + 1 =:= length(Counts) andalso
                   Sum =:= PointCount andalso
                   maps:get(<<"unit">>, H) =:= <<"s">>;
             [] -> false
           end,
  %% The semconv family must use its semconv NAME, not the janus_ spelling:
  %% the two views are distinguished by exactly that.
  Names = [maps:get(<<"name">>, M) || M <- Ms],
  SemconvNamed = lists:member(<<"http.server.request.duration">>, Names),
  if
    not SumOk ->
      io:format("FAIL otlp counter: temporality/monotonic/unit wrong~n");
    not HistOk ->
      io:format("FAIL otlp histogram: bounds+1 ~= counts or unit wrong~n");
    not StableStart ->
      io:format("FAIL otlp metrics: startTimeUnixNano is not stable across encodings~n");
    not SemconvNamed ->
      io:format("FAIL otlp metrics do not use the semconv name: ~p~n", [Names]);
    true ->
      io:format("PASS otlp metrics carry cumulative+monotonic sums and a valid histogram~n")
  end,
  halt().'

# C13 -- the OTLP log record model: severity through the ENCODER, the
# `{string, Chardata}' body shape, and correlation from `meta'.
#
# Three normative details: `severityNumber >= 17' is what a backend counts
# as an ERROR, so `warning' MUST stay in the WARN band; `traceId'/'spanId'
# are ABSENT when there is no span, never back-filled; and a body must
# render as the text a human saw, not a quoted Erlang term.
check "otlp logs encode severity, body and correlation" '
  Want = [{debug, 5}, {info, 9}, {notice, 10}, {warning, 13},
          {error, 17}, {critical, 18}, {alert, 21}, {emergency, 22}],
  BadSev = [{L, N} || {L, N} <- Want,
                      element(1, janus_otel_logs:severity(L)) =/= N],
  WarningBand = element(1, janus_otel_logs:severity(warning)) < 17,
  %% Drive the REAL event shape through the encoder, so severity and body
  %% are asserted on the wire form rather than on the mapping table alone.
  Ev = #{level => warning,
         msg => {string, "plain text body"},
         meta => #{what => probe_line, trace_id => <<"0af7651916cd43dd8448eb211c80319c">>}},
  Rec = janus_otel_export:encode_log_for_test(Ev),
  NoTrace = janus_otel_export:encode_log_for_test(
              #{level => info, msg => {string, "no span"}, meta => #{what => x}}),
  SevOk = maps:get(<<"severityNumber">>, Rec) =:= 13 andalso
              maps:get(<<"severityText">>, Rec) =:= <<"WARN">>,
  BodyOk = maps:get(<<"stringValue">>, maps:get(<<"body">>, Rec)) =:= <<"plain text body">>,
  TraceOk = maps:get(<<"traceId">>, Rec) =:= <<"0af7651916cd43dd8448eb211c80319c">>,
  AbsentOk = not maps:is_key(<<"traceId">>, NoTrace) andalso
                 not maps:is_key(<<"spanId">>, NoTrace),
  Attrs = maps:get(<<"attributes">>, Rec),
  AttrOk = lists:any(fun(A) -> maps:get(<<"key">>, A) =:= <<"what">> end, Attrs),
  if
    BadSev =/= [] ->
      io:format("FAIL severity mapping: ~p~n", [BadSev]);
    not WarningBand ->
      io:format("FAIL warning mapped into the ERROR band (>=17)~n");
    not SevOk ->
      io:format("FAIL severity lost through the encoder~n");
    not BodyOk ->
      io:format("FAIL {string, Chardata} body did not render as text~n");
    not TraceOk ->
      io:format("FAIL traceId not carried from meta~n");
    not AbsentOk ->
      io:format("FAIL traceId/spanId fabricated for a line outside any span~n");
    not AttrOk ->
      io:format("FAIL meta field did not become an attribute~n");
    true ->
      io:format("PASS log records encode severity, body text and correlation~n")
  end,
  halt().'

# C14 -- a peer's `traceparent' is inherited, not replaced.
#
# The dashboard mints a header in the same W3C shape and the gateway must
# continue THAT trace; if it started a new one, the two processes would never
# appear in one view and the dashboard's CLIENT span would dangle. The header
# below is the exact shape the dashboard's telemetry module produces.
#
# Two invariants: the upstream header continues the INHERITED trace id with a
# NEW parent span id (that is how the gateway links its span into the peer's
# trace), and a malformed header RESTARTS rather than reusing garbage ids.
check "an inbound traceparent is inherited, not replaced" '
  Hdr = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
  T = janus_trace:ensure(Hdr, undefined),
  Id = janus_trace:trace_id(T),
  Sampled = janus_trace:sampled(T),
  {UpName, Up} = janus_trace:upstream_header(T),
  UpBin = iolist_to_binary(Up),
  Prefix = iolist_to_binary(["00-", Id, "-"]),
  UpSize = byte_size(UpBin),
  UpHead = binary:part(UpBin, 0, byte_size(Prefix)),
  UpTail = binary:part(UpBin, UpSize - 3, 3),
  %% 00-<32 tid>-<16 pid>-<2 flags>: the parent id starts after "00-" + tid + "-".
  PidOffset = 3 + 32 + 1,
  UpPid = binary:part(UpBin, PidOffset, 16),
  UpOk = UpSize =:= 55 andalso UpHead =:= Prefix andalso UpTail =:= <<"-01">>,
  NameOk = UpName =:= <<"traceparent">>,
  NewPid = UpPid =/= <<"00f067aa0ba902b7">>,
  %% An inbound `00` sampled flag must be PRESERVED: hardcoding 01 would
  %% silently record traces a conformant peer asked us not to.
  Uns = janus_trace:ensure(
      <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>, undefined
  ),
  UnsUp = iolist_to_binary(element(2, janus_trace:upstream_header(Uns))),
  UnsTail = binary:part(UnsUp, byte_size(UnsUp) - 3, 3),
  UnsOk = UnsTail =:= <<"-00">> andalso janus_trace:sampled(Uns) =:= false,
  Bad = janus_trace:ensure(<<"00-zzzz">>, undefined),
  FreshOk = janus_trace:trace_id(Bad) =/= Id,
  Embedded = <<"4bf92f3577b34da6a3ce929d0e0e4736">>,
  BadIds = [<<"00-zzzz">>,
            <<"00-00000000000000000000000000000000-0000000000000000-01">>,
            <<"ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
            <<"00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01">>,
            <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra">>],
  BadFresh = [janus_trace:trace_id(janus_trace:ensure(H, undefined)) =/= Embedded || H <- BadIds],
  AllFresh = lists:all(fun(X) -> X end, BadFresh),
  if
    Id =/= <<"4bf92f3577b34da6a3ce929d0e0e4736">> ->
      io:format("FAIL inherited trace id: ~s~n", [Id]);
    Sampled =/= true ->
      io:format("FAIL inherited sampled flag: ~p~n", [Sampled]);
    not UpOk ->
      io:format("FAIL upstream header does not continue the inherited trace: ~s~n", [Up]);
    not NewPid ->
      io:format("FAIL upstream header reuses the inbound parent span id~n");
    not NameOk ->
      io:format("FAIL upstream header name is not traceparent: ~p~n", [UpName]);
    not FreshOk ->
      io:format("FAIL a malformed traceparent did not restart the trace~n");
    not UnsOk ->
      io:format("FAIL an unsampled inbound decision was not preserved~n");
    not AllFresh ->
      io:format("FAIL a malformed traceparent was inherited: ~p~n", [BadFresh]);
    true ->
      io:format("PASS inbound traceparent is inherited and re-emitted correctly~n")
  end,
  halt().'

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
