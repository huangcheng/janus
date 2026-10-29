%%%-------------------------------------------------------------------
%%% @doc Build provenance (scheduler v2.1 spec Part C.3).
%%%
%%% The Dockerfile bakes the git SHA both as an image LABEL
%%% (`org.opencontainers.image.revision`) and as `ENV JANUS_GIT_SHA` —
%%% image labels are INVISIBLE to the running container, the ENV is
%%% what feeds boot -> persistent_term -> `/stats/sched git_sha`
%%% (master, additive key) and the worker hello `git_sha` (mixed-image
%%% fleets visible in the workers array, v2.1 A.3).
%%%
%%% A missing build-arg stamps the literal `<<"unknown">>` — never
%%% empty (the incident tree that shipped uncommitted code must be
%%% structurally impossible to reproduce silently; the deploy script
%%% additionally REFUSES a dirty tree).
%%%
%%% `init/0` runs at janus_core boot on BOTH roles (before the
%%% supervisor); `sha/0` is a tolerant PT read usable from any process
%%% (badarg -> <<"unknown">> when init has not run, e.g. eunit).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_build).

-export([init/0, sha/0, normalize/1]).

-define(PT_KEY, {janus_build, git_sha}).

-spec init() -> ok.
init() ->
    persistent_term:put(?PT_KEY, normalize(os:getenv("JANUS_GIT_SHA"))),
    ok.

%% @doc The stamped SHA (e.g. `<<"0123...">>` or `<<"unknown">>`).
-spec sha() -> binary().
sha() ->
    try
        persistent_term:get(?PT_KEY)
    catch
        error:badarg -> <<"unknown">>
    end.

%% @doc `JANUS_GIT_SHA` parse: unset/empty/non-string => the literal
%% `<<"unknown">>`; a string => binary (the same contract as the
%% worker hello's git_sha_opt/1 — exported for reuse/tests).
-spec normalize(false | string() | term()) -> binary().
normalize(false) ->
    <<"unknown">>;
normalize("") ->
    <<"unknown">>;
normalize(Val) when is_list(Val) ->
    %% Flat Latin-1 lists only — a Unicode codepoint list makes
    %% list_to_binary raise; degrade to unknown (ocr review).
    try
        list_to_binary(Val)
    catch
        _:_ -> <<"unknown">>
    end;
normalize(Val) when is_binary(Val), Val =/= <<>> ->
    Val;
normalize(_) ->
    <<"unknown">>.
