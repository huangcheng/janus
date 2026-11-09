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

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
