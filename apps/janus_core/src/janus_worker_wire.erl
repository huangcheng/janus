%%% @doc Pure constructors and validators for master/worker dist messages
%%% (spec §4). No I/O; safe redaction for verify artifacts.
-module(janus_worker_wire).

-export([
    credit_window_initial/0,
    non_stream_timeout_ms/0,
    stream_timeout_ms/0,
    ack_deadline_ms/0,
    initial_chunk_seq/0,
    hello/3,
    hello_ack/1,
    hello_nack/2,
    drain/1,
    job/3,
    job_ack/2,
    chunk/3,
    done/2,
    error/3,
    cancel/1,
    credit/2,
    redact_job/1,
    validate/1
]).

-define(VSN, 1).
-define(METHODS, [get, post, put, delete, patch]).
-define(ERROR_CODES, [timeout, connect, tls, upstream_closed, internal]).
-define(NACK_REASONS, [drained, vsn]).

-spec credit_window_initial() -> pos_integer().
credit_window_initial() -> 32.

-spec non_stream_timeout_ms() -> pos_integer().
non_stream_timeout_ms() -> 120_000.

-spec stream_timeout_ms() -> pos_integer().
stream_timeout_ms() -> 600_000.

-spec ack_deadline_ms() -> pos_integer().
ack_deadline_ms() -> 5_000.

-spec initial_chunk_seq() -> 0.
initial_chunk_seq() -> 0.

-spec hello(pid(), node(), map()) -> {janus_worker_hello, pid(), node(), map()}.
hello(From, Node, Opts) when is_pid(From), is_atom(Node), is_map(Opts) ->
    Region = maps:get(region, Opts, undefined),
    Meta = #{role => worker, vsn => ?VSN, region => Region},
    Msg = {janus_worker_hello, From, Node, Meta},
    ok = validate(Msg),
    Msg.

-spec hello_ack(node()) -> {janus_worker_hello_ack, node(), map()}.
hello_ack(Node) when is_atom(Node) ->
    Msg = {janus_worker_hello_ack, Node, #{vsn => ?VSN}},
    ok = validate(Msg),
    Msg.

-spec hello_nack(node(), drained | vsn) ->
    {janus_worker_hello_nack, node(), map()}.
hello_nack(Node, Reason) when is_atom(Node) ->
    Msg = {janus_worker_hello_nack, Node, #{reason => Reason}},
    ok = validate(Msg),
    Msg.

-spec drain(node()) -> {janus_worker_drain, node()}.
drain(Node) when is_atom(Node) ->
    Msg = {janus_worker_drain, Node},
    ok = validate(Msg),
    Msg.

-spec job(binary(), pid(), map()) ->
    {ok, {janus_job, binary(), pid(), map()}} | {error, term()}.
job(JobRef, MasterSessionPid, Fields) when is_binary(JobRef), is_pid(MasterSessionPid), is_map(Fields) ->
    case validate_job_fields(Fields) of
        ok ->
            Msg = {janus_job, JobRef, MasterSessionPid, Fields},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

-spec job_ack(binary(), pid()) -> {janus_job_ack, binary(), pid()}.
job_ack(JobRef, WorkerSessionPid) when is_binary(JobRef), is_pid(WorkerSessionPid) ->
    Msg = {janus_job_ack, JobRef, WorkerSessionPid},
    ok = validate(Msg),
    Msg.

-spec chunk(binary(), non_neg_integer(), binary()) ->
    {janus_chunk, binary(), non_neg_integer(), binary()}.
chunk(JobRef, Seq, Bin) when is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin) ->
    Msg = {janus_chunk, JobRef, Seq, Bin},
    ok = validate(Msg),
    Msg.

-spec done(binary(), map()) -> {janus_done, binary(), map()}.
done(JobRef, Fields) when is_binary(JobRef), is_map(Fields) ->
    Msg = {janus_done, JobRef, Fields},
    ok = validate(Msg),
    Msg.

-spec error(binary(), atom(), binary()) -> {janus_error, binary(), map()}.
error(JobRef, Code, Message) when is_binary(JobRef), is_binary(Message) ->
    Msg = {janus_error, JobRef, #{code => Code, message => Message}},
    ok = validate(Msg),
    Msg.

-spec cancel(binary()) -> {janus_cancel, binary()}.
cancel(JobRef) when is_binary(JobRef) ->
    Msg = {janus_cancel, JobRef},
    ok = validate(Msg),
    Msg.

-spec credit(binary(), pos_integer()) -> {janus_credit, binary(), pos_integer()}.
credit(JobRef, N) when is_binary(JobRef), is_integer(N), N > 0 ->
    Msg = {janus_credit, JobRef, N},
    ok = validate(Msg),
    Msg.

-spec redact_job({janus_job, binary(), pid(), map()}) ->
    {janus_job, binary(), pid(), map()}.
redact_job({janus_job, JobRef, MasterSessionPid, Fields}) ->
    case validate({janus_job, JobRef, MasterSessionPid, Fields}) of
        ok ->
            #{headers := Hdr} = Fields,
            RedHdr = [{K, <<>>} || {K, _V} <- Hdr],
            RedFields = Fields#{headers => RedHdr, body => <<>>},
            {janus_job, JobRef, MasterSessionPid, RedFields};
        {error, Reason} ->
            error({bad_job, Reason})
    end.

-spec validate(term()) -> ok | {error, term()}.
validate({janus_worker_hello, From, Node, Meta}) ->
    with_ok([
        valid_pid(From),
        valid_node(Node),
        validate_hello_meta(Meta)
    ]);
validate({janus_worker_hello_ack, Node, #{vsn := ?VSN}}) ->
    with_ok([valid_node(Node)]);
validate({janus_worker_hello_nack, Node, #{reason := Reason}}) ->
    with_ok([valid_node(Node), valid_nack_reason(Reason)]);
validate({janus_worker_drain, Node}) ->
    with_ok([valid_node(Node)]);
validate({janus_job, JobRef, MasterSessionPid, Fields}) ->
    with_ok([
        valid_job_ref(JobRef),
        valid_pid(MasterSessionPid),
        validate_job_fields(Fields)
    ]);
validate({janus_job_ack, JobRef, WorkerSessionPid}) ->
    with_ok([valid_job_ref(JobRef), valid_pid(WorkerSessionPid)]);
validate({janus_chunk, JobRef, Seq, Bin}) ->
    with_ok([
        valid_job_ref(JobRef),
        validate_chunk_seq(Seq),
        valid_binary(Bin)
    ]);
validate({janus_done, JobRef, Fields}) ->
    with_ok([valid_job_ref(JobRef), validate_done_fields(Fields)]);
validate({janus_error, JobRef, #{code := Code, message := Message}}) ->
    with_ok([
        valid_job_ref(JobRef),
        valid_error_code(Code),
        valid_binary(Message)
    ]);
validate({janus_cancel, JobRef}) ->
    with_ok([valid_job_ref(JobRef)]);
validate({janus_credit, JobRef, N}) ->
    with_ok([valid_job_ref(JobRef), valid_pos_integer(N)]);
validate(_) ->
    {error, bad_shape}.

with_ok([]) ->
    ok;
with_ok([ok | Rest]) ->
    with_ok(Rest);
with_ok([{error, _} = Err | _]) ->
    Err.

%%--------------------------------------------------------------------
%% Internal validation
%%--------------------------------------------------------------------

validate_hello_meta(#{role := worker, vsn := ?VSN} = Meta) ->
    case maps:get(region, Meta, undefined) of
        undefined -> ok;
        R when is_binary(R) -> ok;
        _ -> {error, bad_region}
    end;
validate_hello_meta(#{role := Role}) ->
    {error, {bad_role, Role}};
validate_hello_meta(#{vsn := Vsn}) ->
    {error, {bad_vsn, Vsn}};
validate_hello_meta(_) ->
    {error, bad_hello_meta}.

validate_job_fields(Fields) when map_size(Fields) =:= 7 ->
    with_ok([
        maps_find(url, Fields, fun valid_binary/1),
        maps_find(method, Fields, fun valid_method/1),
        maps_find(headers, Fields, fun valid_headers/1),
        maps_find(body, Fields, fun valid_body/1),
        maps_find(stream, Fields, fun valid_boolean/1),
        maps_find(timeout_ms, Fields, fun valid_timeout_ms/1),
        maps_find(protocol_meta, Fields, fun valid_protocol_meta/1)
    ]);
validate_job_fields(_) ->
    {error, bad_job_fields}.

maps_find(Key, Map, Fun) ->
    case maps:find(Key, Map) of
        {ok, Val} -> Fun(Val);
        error -> {error, bad_job_fields}
    end.

validate_done_fields(#{usage := Usage, status := Status, trailers := Trailers, body := Body}) ->
    valid_usage(Usage),
    valid_status(Status),
    valid_map(Trailers),
    valid_done_body(Body);
validate_done_fields(_) ->
    {error, bad_done_fields}.

validate_chunk_seq(Seq) when is_integer(Seq), Seq >= 0 ->
    ok;
validate_chunk_seq(_) ->
    {error, bad_seq}.

valid_job_ref(Ref) when is_binary(Ref), byte_size(Ref) > 0 ->
    ok;
valid_job_ref(_) ->
    {error, bad_job_ref}.

valid_pid(P) when is_pid(P) ->
    ok;
valid_pid(_) ->
    {error, bad_pid}.

valid_node(N) when is_atom(N) ->
    ok;
valid_node(_) ->
    {error, bad_node}.

valid_binary(B) when is_binary(B) ->
    ok;
valid_binary(_) ->
    {error, bad_binary}.

valid_map(M) when is_map(M) ->
    ok;
valid_map(_) ->
    {error, bad_map}.

valid_boolean(B) when is_boolean(B) ->
    ok;
valid_boolean(_) ->
    {error, bad_stream}.

valid_method(M) ->
    case lists:member(M, ?METHODS) of
        true -> ok;
        false -> {error, bad_method}
    end.

valid_headers(Hdr) when is_list(Hdr) ->
    case lists:all(
        fun
            ({K, V}) when is_binary(K), is_binary(V) -> true;
            (_) -> false
        end,
        Hdr
    ) of
        true -> ok;
        false -> {error, bad_headers}
    end;
valid_headers(_) ->
    {error, bad_headers}.

valid_body(B) when is_binary(B) ->
    ok;
valid_body(B) when is_list(B) ->
    ok;
valid_body(_) ->
    {error, bad_body}.

valid_timeout_ms(T) when is_integer(T), T > 0 ->
    ok;
valid_timeout_ms(_) ->
    {error, bad_timeout_ms}.

valid_protocol_meta(M) when is_map(M) ->
    ok;
valid_protocol_meta(_) ->
    {error, bad_protocol_meta}.

valid_pos_integer(N) when is_integer(N), N > 0 ->
    ok;
valid_pos_integer(_) ->
    {error, bad_credit_n}.

valid_nack_reason(R) ->
    case lists:member(R, ?NACK_REASONS) of
        true -> ok;
        false -> {error, bad_nack_reason}
    end.

valid_error_code(C) ->
    case lists:member(C, ?ERROR_CODES) of
        true -> ok;
        false -> {error, bad_error_code}
    end.

valid_usage(undefined) ->
    ok;
valid_usage(U) when is_map(U) ->
    ok;
valid_usage(_) ->
    {error, bad_usage}.

valid_status(S) when is_integer(S), S >= 100, S =< 599 ->
    ok;
valid_status(_) ->
    {error, bad_status}.

valid_done_body(undefined) ->
    ok;
valid_done_body(B) when is_binary(B) ->
    ok;
valid_done_body(_) ->
    {error, bad_done_body}.
