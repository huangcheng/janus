-module(janus_worker_wire_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WNODE, 'worker@127.0.0.1').
-define(JREF, <<"job-ref-1">>).
-define(SECRET, <<"Bearer sk-live-super-secret">>).

pinned_knobs_test() ->
    ?assertEqual(32, janus_worker_wire:credit_window_initial()),
    ?assertEqual(120_000, janus_worker_wire:non_stream_timeout_ms()),
    ?assertEqual(600_000, janus_worker_wire:stream_timeout_ms()),
    ?assertEqual(5_000, janus_worker_wire:ack_deadline_ms()),
    ?assertEqual(0, janus_worker_wire:initial_chunk_seq()).

hello_roundtrip_test() ->
    From = self(),
    Msg = janus_worker_wire:hello(From, ?WNODE, #{region => <<"cn-east">>}),
    ?assertEqual(ok, janus_worker_wire:validate(Msg)),
    Msg2 = janus_worker_wire:hello(From, ?WNODE, #{}),
    ?assertEqual(ok, janus_worker_wire:validate(Msg2)).

hello_rejects_bad_meta_test() ->
    From = self(),
    Bad = {janus_worker_hello, From, ?WNODE, #{role => worker, vsn => 2}},
    ?assertMatch({error, {bad_vsn, 2}}, janus_worker_wire:validate(Bad)),
    BadRole = {janus_worker_hello, From, ?WNODE, #{role => master, vsn => 1}},
    ?assertMatch({error, {bad_role, master}}, janus_worker_wire:validate(BadRole)).

hello_control_roundtrip_test() ->
    ?assertEqual(ok, janus_worker_wire:validate(janus_worker_wire:hello_ack(?WNODE))),
    {ok, Nack1} = janus_worker_wire:hello_nack(?WNODE, drained),
    ?assertEqual(ok, janus_worker_wire:validate(Nack1)),
    {ok, Nack2} = janus_worker_wire:hello_nack(?WNODE, vsn),
    ?assertEqual(ok, janus_worker_wire:validate(Nack2)),
    ?assertEqual(ok, janus_worker_wire:validate(janus_worker_wire:drain(?WNODE))).

job_fields() ->
    #{
        url => <<"https://api.example/v1/chat">>,
        method => post,
        headers => [{<<"Authorization">>, ?SECRET}, {<<"Content-Type">>, <<"application/json">>}],
        body => <<"{\"model\":\"x\"}">>,
        stream => true,
        timeout_ms => janus_worker_wire:stream_timeout_ms(),
        protocol_meta => #{}
    }.

job_roundtrip_all_methods_test() ->
    Base = job_fields(),
    Master = self(),
    Methods = [get, post, put, delete, patch],
    [
        begin
            {ok, Msg} = janus_worker_wire:job(?JREF, Master, Base#{method => M}),
            ?assertEqual(ok, janus_worker_wire:validate(Msg))
        end
     || M <- Methods
    ].

job_rejects_bad_method_test() ->
    Master = self(),
    Base = job_fields(),
    ?assertMatch(
        {error, bad_method},
        janus_worker_wire:job(?JREF, Master, Base#{method => options})
    ),
    ?assertMatch(
        {error, bad_method},
        janus_worker_wire:validate(
            {janus_job, ?JREF, Master, maps:merge(Base, #{method => <<"POST">>})}
        )
    ).

job_rejects_bad_timeout_test() ->
    Master = self(),
    Base = job_fields(),
    ?assertMatch(
        {error, bad_timeout_ms},
        janus_worker_wire:job(?JREF, Master, Base#{timeout_ms => 0})
    ).

stream_messages_roundtrip_test() ->
    Worker = self(),
    ?assertEqual(
        ok,
        janus_worker_wire:validate(
            janus_worker_wire:job_ack(?JREF, Worker)
        )
    ),
    ?assertEqual(
        ok,
        janus_worker_wire:validate(
            janus_worker_wire:chunk(?JREF, janus_worker_wire:initial_chunk_seq(), <<"data">>)
        )
    ),
    Done = janus_worker_wire:done(?JREF, #{
        usage => #{prompt_tokens => 1},
        status => 200,
        trailers => #{},
        body => undefined
    }),
    ?assertEqual(ok, janus_worker_wire:validate(Done)),
    {ok, Err} = janus_worker_wire:error(?JREF, timeout, <<"timed out">>),
    ?assertEqual(ok, janus_worker_wire:validate(Err)).

chunk_rejects_negative_seq_test() ->
    Bad = {janus_chunk, ?JREF, -1, <<"x">>},
    ?assertMatch({error, bad_seq}, janus_worker_wire:validate(Bad)).

control_roundtrip_test() ->
    ?assertEqual(ok, janus_worker_wire:validate(janus_worker_wire:cancel(?JREF))),
    ?assertEqual(
        ok,
        janus_worker_wire:validate(janus_worker_wire:credit(?JREF, 32))
    ).

done_rejects_bad_status_test() ->
    Bad = {janus_done, ?JREF, #{
        usage => undefined,
        status => 999,
        trailers => #{},
        body => undefined
    }},
    ?assertMatch({error, bad_status}, janus_worker_wire:validate(Bad)).

validate_bad_shape_test() ->
    ?assertEqual({error, bad_shape}, janus_worker_wire:validate({unknown_msg, foo, bar})).

redact_job_headers_without_values_test() ->
    Master = self(),
    {ok, Msg} = janus_worker_wire:job(?JREF, Master, job_fields()),
    {ok, Red} = janus_worker_wire:redact_job(Msg),
    {janus_job, _Ref, _Pid, RedFields} = Red,
    #{headers := Hdr, body := Body} = RedFields,
    ?assertEqual(
        [{<<"Authorization">>, <<>>}, {<<"Content-Type">>, <<>>}],
        Hdr
    ),
    ?assertEqual(<<>>, Body).

redact_job_no_bearer_leak_test() ->
    Master = self(),
    {ok, Msg} = janus_worker_wire:job(?JREF, Master, job_fields()),
    {ok, Red} = janus_worker_wire:redact_job(Msg),
    Bin = term_to_binary(Red),
    ?assertEqual(nomatch, binary:match(Bin, <<"Bearer">>)),
    ?assertEqual(nomatch, binary:match(Bin, ?SECRET)).
