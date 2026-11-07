%%%-------------------------------------------------------------------
%%% @doc Characterization tests for cache-token accounting.
%%%
%%% `cache_read' and `cache_write' are distinct reportable dimensions
%%% (a cache hit vs a cache fill). Both were previously summed into
%%% `prompt' and then discarded, so a cache hit and a cache fill were
%%% indistinguishable to every consumer.
%%%
%%% Invariant pinned here: `prompt' includes both (billing parity with
%%% the provider's own input count), while `cache_read'/`cache_write'
%%% report them separately and are SUBSETS of `prompt' — not extra
%%% tokens. A consumer that sums all four double-counts.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_usage_parse_cache_tests).

-include_lib("eunit/include/eunit.hrl").

anthropic_cache_read_and_write_split_test() ->
    Body = json(#{
        <<"usage">> => #{
            <<"input_tokens">> => 100,
            <<"cache_creation_input_tokens">> => 25,
            <<"cache_read_input_tokens">> => 50,
            <<"output_tokens">> => 7
        }
    }),
    U = janus_usage_parse:from_response_body(anthropic_messages, Body),
    ?assertEqual(175, maps:get(prompt, U)),
    ?assertEqual(7, maps:get(completion, U)),
    ?assertEqual(50, maps:get(cache_read, U)),
    ?assertEqual(25, maps:get(cache_write, U)).

cache_dimensions_are_subsets_of_prompt_test() ->
    Body = json(#{
        <<"usage">> => #{
            <<"input_tokens">> => 10,
            <<"cache_creation_input_tokens">> => 4,
            <<"cache_read_input_tokens">> => 6,
            <<"output_tokens">> => 1
        }
    }),
    U = janus_usage_parse:from_response_body(anthropic_messages, Body),
    Base = maps:get(prompt, U) - maps:get(cache_read, U) - maps:get(cache_write, U),
    ?assertEqual(10, Base),
    ?assert(maps:get(cache_read, U) =< maps:get(prompt, U)),
    ?assert(maps:get(cache_write, U) =< maps:get(prompt, U)).

cache_absent_is_zero_not_missing_test() ->
    Body = json(#{<<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 2}}),
    U = janus_usage_parse:from_response_body(openai_chat, Body),
    ?assertEqual(0, maps:get(cache_read, U)),
    ?assertEqual(0, maps:get(cache_write, U)),
    ?assertEqual(5, maps:get(prompt, U)).

openai_cache_write_alias_test() ->
    %% Accept the OpenAI-shaped key too, so a provider that names it
    %% `cache_write_input_tokens' is not silently zeroed.
    %%
    %% `prompt' stays 20: OpenAI's `prompt_tokens' is the TOTAL input and
    %% already INCLUDES cached tokens, so adding the cache dimensions
    %% would double-count. (This assertion previously expected 28, which
    %% encoded that double-count as correct.)
    Body = json(#{
        <<"usage">> => #{
            <<"prompt_tokens">> => 20,
            <<"cache_write_input_tokens">> => 8,
            <<"completion_tokens">> => 1
        }
    }),
    U = janus_usage_parse:from_response_body(openai_chat, Body),
    ?assertEqual(8, maps:get(cache_write, U)),
    ?assertEqual(20, maps:get(prompt, U)).

unreported_usage_stays_undefined_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_response_body(openai_chat, <<"{\"x\":1}">>)).

json(M) -> iolist_to_binary(thoas:encode(M)).
