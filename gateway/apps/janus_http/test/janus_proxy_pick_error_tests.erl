%% Pick-error handling (review 06d M2/M5). M2: the janus-auto
%% next-name gate must treat the "empty pick" classes (all_cooling /
%% provider_disabled / keys_disabled / missing_provider_key) as
%% skippable, while catalog_not_ready and plain no_route stay terminal.
%% M5: the status fed to track/3 must be the class of the response the
%% client actually receives — bare `all_cooling` answers 503 but used
%% to be recorded as 404.
-module(janus_proxy_pick_error_tests).

-include_lib("eunit/include/eunit.hrl").

advanceable_pick_error_test() ->
    Advanceable = [
        all_cooling,
        {all_cooling, 5000},
        provider_disabled,
        keys_disabled,
        missing_provider_key
    ],
    [?assert(janus_http_proxy:is_advanceable_pick_error(R)) || R <- Advanceable],
    Terminal = [catalog_not_ready, no_route, {error, timeout}, undefined],
    [?assertNot(janus_http_proxy:is_advanceable_pick_error(R)) || R <- Terminal].

committed_pick_error_status_test() ->
    ?assertEqual(503, janus_http_proxy:pick_error_status(all_cooling)),
    ?assertEqual(503, janus_http_proxy:pick_error_status({all_cooling, 5000})),
    %% Malformed cooldown still replies 503 (retry-after falls back to
    %% the default), so the tracked class must stay 503.
    ?assertEqual(503, janus_http_proxy:pick_error_status({all_cooling, 0})),
    ?assertEqual(503, janus_http_proxy:pick_error_status(provider_disabled)),
    ?assertEqual(503, janus_http_proxy:pick_error_status(keys_disabled)),
    ?assertEqual(503, janus_http_proxy:pick_error_status(missing_provider_key)),
    ?assertEqual(503, janus_http_proxy:pick_error_status(catalog_not_ready)),
    ?assertEqual(404, janus_http_proxy:pick_error_status(no_route)).
