%%% @doc Pure constructors and validators for master/worker dist messages
%%% (spec §4). No I/O; safe redaction for verify artifacts.
%%%
%%% Wire compression extensions (spec 2026-10-12-wire-compression
%%% D2/F1): `chunk/4` carries the optional 5th Meta element
%%% (`#{enc => zlib}` — the 4-tuple stays the identity form), `done`
%%% gains the optional top-level `enc => zlib` map key (body-only
%%% compression), the hello_ack advertises the additive
%%% `wire_enc => [zlib]` capability, and `error` payloads are NEVER
%%% compressed. Old-peer validators tolerate every additive key.
-module(janus_worker_wire).

-export([
    credit_window_initial/0,
    non_stream_timeout_ms/0,
    stream_timeout_ms/0,
    stream_inactivity_timeout_ms/0,
    ack_deadline_ms/0,
    initial_chunk_seq/0,
    hello/3,
    hello_ack/1,
    hello_ack/2,
    hello_nack/2,
    drain/1,
    job/3,
    job_ack/2,
    chunk/3,
    chunk/4,
    done/2,
    error/3,
    error/4,
    cancel/1,
    credit/2,
    redact_job/1,
    validate/1
]).

-define(VSN, 1).
-define(METHODS, [get, post, put, delete, patch]).
-define(ERROR_CODES, [timeout, connect, tls, upstream_closed, internal]).
-define(NACK_REASONS, [drained, vsn, role, node]).

-spec credit_window_initial() -> pos_integer().
credit_window_initial() -> 32.

-spec non_stream_timeout_ms() -> pos_integer().
non_stream_timeout_ms() -> 120_000.

-spec stream_timeout_ms() -> pos_integer().
stream_timeout_ms() -> 600_000.

%% Mid-stream INACTIVITY ceiling (2026-10-29): stream_timeout_ms/0 is a
%% TOTAL budget for the whole stream; producers that never die but
%% never produce let a request sit for the full 10 minutes while the
%% client gave up long before. That asymmetry is what made a 300s
%% client idle timeout look like an unexplained "terminated" with no
%% gateway-side counterpart (live 2026-10-29: 15 aborted turns,
%% upstreams "completing" at latency_ms=294473). A stream that goes
%% this long WITHOUT A SINGLE BYTE is a stalled upstream, and the
%% gateway must say so in its own words instead of letting the client
%% die blind. Restarts on every forwarded chunk (progress), so only
%% true silence trips it. Deliberately BELOW stream_timeout_ms/0.
-spec stream_inactivity_timeout_ms() -> pos_integer().
stream_inactivity_timeout_ms() -> 180_000.

-spec ack_deadline_ms() -> pos_integer().
ack_deadline_ms() -> 5_000.

-spec initial_chunk_seq() -> 0.
initial_chunk_seq() -> 0.

-spec hello(pid(), node(), map()) -> {janus_worker_hello, pid(), node(), map()}.
hello(From, Node, Opts) when is_pid(From), is_atom(Node), is_map(Opts) ->
    Region = maps:get(region, Opts, undefined),
    %% Scheduler v2 ADDITIVE hello keys (spec Part 0.10): capacity /
    %% sched_v / git_sha (v2.1 A.3/C.3 build provenance) ride the meta
    %% ONLY when well-formed — an old master's admit path builds its
    %% record from known keys and ignores them; the validator below
    %% tolerates the extra keys (verified: it matches on role/vsn/
    %% region only). Geo-affinity (2026-10-11 spec D4/D18): the worker's
    %% layered egress discovery rides egress_ip / egress_region /
    %% egress_source / egress_fetched_at plus the gw-echo health
    %% counters echo_ok_total / echo_fail_total — all omitted when
    %% absent (knob-off / no usable layer), same additive contract.
    Additive = maps:filter(
        fun
            (capacity, C) when is_integer(C), C >= 1 -> true;
            (sched_v, V) when is_integer(V), V >= 1 -> true;
            (git_sha, S) when is_binary(S), S =/= <<>> -> true;
            (egress_ip, S) when is_binary(S), S =/= <<>> -> true;
            (egress_region, S) when is_binary(S), S =/= <<>> -> true;
            (egress_source, S) when is_binary(S), S =/= <<>> -> true;
            (egress_fetched_at, T) when is_integer(T), T >= 0 -> true;
            (echo_ok_total, N) when is_integer(N), N >= 0 -> true;
            (echo_fail_total, N) when is_integer(N), N >= 0 -> true;
            (_K, _V) -> false
        end,
        Opts
    ),
    Meta = maps:merge(#{role => worker, vsn => ?VSN, region => Region}, Additive),
    Msg = {janus_worker_hello, From, Node, Meta},
    ok = validate(Msg),
    Msg.

-spec hello_ack(node()) -> {janus_worker_hello_ack, node(), map()}.
hello_ack(Node) when is_atom(Node) ->
    hello_ack(Node, #{}).

%% Wire compression (spec 2026-10-12 D2/F1): the master advertises
%% the compression capability as an ADDITIVE ack-map key. The option
%% carries the master's supported-codec LIST; we advertise the
%% DECODABLE SUBSET, normalized to `[zlib]' — `lists:member(zlib,
%% ...)' so a future multi-codec master (e.g. `[zlib, br]') still
%% advertises the zlib it can decode instead of silently dropping
%% compression end-to-end (ocr review); anything else is omitted (the
%% constructor never puts a capability on the wire the codec cannot
%% decode). The ack validator tolerates the extra key either way
%% (partial-map pattern), so an old worker still decodes.
%% SEQUENCING (PR1 task A): the master pool's gated call site (D10 —
%% `JANUS_WIRE_ENC` role-aware) is wired in the LATER PR1 task; until
%% then only the /1 form is on the wire (capability never advertised,
%% workers stay identity — the codec is unreachable end-to-end by
%% construction).
-spec hello_ack(node(), map()) -> {janus_worker_hello_ack, node(), map()}.
hello_ack(Node, Opts) when is_atom(Node), is_map(Opts) ->
    Codecs = maps:get(wire_enc, Opts, undefined),
    HasZlib = is_list(Codecs) andalso zlib_member(Codecs),
    Meta =
        case HasZlib of
            true -> #{vsn => ?VSN, wire_enc => [zlib]};
            false -> #{vsn => ?VSN}
        end,
    Msg = {janus_worker_hello_ack, Node, Meta},
    ok = validate(Msg),
    Msg.

%% is_list/1 accepts IMPROPER lists and lists:member/2 would then
%% raise function_clause — a malformed capability value must be
%% dropped, never crash the constructor (ocr review).
zlib_member(Codecs) ->
    try
        lists:member(zlib, Codecs)
    catch
        _:_ -> false
    end.

-spec hello_nack(node(), drained | vsn | role | node) ->
    {ok, {janus_worker_hello_nack, node(), map()}} | {error, term()}.
hello_nack(Node, Reason) when is_atom(Node) ->
    case valid_nack_reason(Reason) of
        ok ->
            Msg = {janus_worker_hello_nack, Node, #{reason => Reason}},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

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

%% Wire compression (spec 2026-10-12 D2/F1): the 5-tuple form carries
%% zlib bytes in Bin plus the Meta map. `#{enc => zlib}` when
%% compressed; `#{}` is the normalization target for the master-side
%% FIRST-receive clause (4-tuple => 5-tuple before seq/credit/log
%% handling); the identity fallback NEVER emits an enc key. Assert
%% style matches chunk/3: a malformed enc tag crashes the sender (a
%% worker-side bug — loud, never silent).
-spec chunk(binary(), non_neg_integer(), binary(), map()) ->
    {janus_chunk, binary(), non_neg_integer(), binary(), map()}.
chunk(JobRef, Seq, Bin, Meta) when
    is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin), is_map(Meta)
->
    Msg = {janus_chunk, JobRef, Seq, Bin, Meta},
    ok = validate(Msg),
    Msg.

%% Wire compression (spec 2026-10-12 D2): the done map MAY carry the
%% top-level `enc => zlib` key — ONLY the `body` field value is
%% compressed; usage/status/trailers stay plaintext (readable
%% outline). The validator below enforces the enc tag. SEQUENCING
%% (PR1 task A): the validator accepts the tagged shape BEFORE any
%% sender ships it (the repo's validators-before-senders rule) — the
%% master-side done-body decode lands in the later PR1 task together
%% with the compressing senders, so no tagged done exists on the wire
%% until its decoder does.
-spec done(binary(), map()) -> {janus_done, binary(), map()}.
done(JobRef, Fields) when is_binary(JobRef), is_map(Fields) ->
    Msg = {janus_done, JobRef, Fields},
    ok = validate(Msg),
    Msg.

%% Wire compression (spec 2026-10-12 D2): error payloads are NEVER
%% compressed — the message is a short string (nothing to compress)
%% and the error outline stays fully readable on the master; there is
%% no enc tag on janus_error by construction, so an error can never
%% fail inflate on the abort path (F2).
-spec error(binary(), atom(), binary()) ->
    {ok, {janus_error, binary(), map()}} | {error, term()}.
error(JobRef, Code, Message) when is_binary(JobRef), is_binary(Message) ->
    error(JobRef, Code, Message, #{}).

%% Scheduler v2 additive-key form (spec A.3): ExtraFields merges into
%% the base #{code, message} map — the shipped error validator matches
%% on code/message only, so extra keys (`rtt_ms`) pass validation and
%% an old master still decodes the message (spec Part 0.10).
-spec error(binary(), atom(), binary(), map()) ->
    {ok, {janus_error, binary(), map()}} | {error, term()}.
error(JobRef, Code, Message, ExtraFields) when
    is_binary(JobRef), is_binary(Message), is_map(ExtraFields)
->
    case valid_error_code(Code) of
        ok ->
            %% Base keys WIN: an ExtraFields collision with the
            %% reserved code/message must never override the wire
            %% contract (ocr review). `enc` is reserved-ABSENT here:
            %% error payloads are NEVER compressed (spec
            %% 2026-10-12-wire-compression D2 — the outline stays
            %% readable and can never fail inflate), so a smuggled
            %% enc key is stripped before the wire (ocr review).
            %% INTENTIONAL asymmetry with the boundary (ocr review):
            %% the constructor STRIPS (a Janus error must always be
            %% deliverable — stripping never blocks an error), while
            %% validate/1 REJECTS a raw enc-carrying tuple
            %% (valid_error_no_enc) — defense in depth in both
            %% directions.
            Fields = maps:merge(maps:remove(enc, ExtraFields), #{code => Code, message => Message}),
            Msg = {janus_error, JobRef, Fields},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

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
    {ok, {janus_job, binary(), pid(), map()}} | {error, term()}.
redact_job({janus_job, JobRef, MasterSessionPid, Fields}) ->
    case validate({janus_job, JobRef, MasterSessionPid, Fields}) of
        ok ->
            #{headers := Hdr} = Fields,
            RedHdr = [{K, <<>>} || {K, _V} <- Hdr],
            RedFields = Fields#{headers => RedHdr, body => <<>>},
            {ok, {janus_job, JobRef, MasterSessionPid, RedFields}};
        {error, Reason} ->
            {error, {bad_job, Reason}}
    end.

-spec validate(term()) -> ok | {error, term()}.
validate({janus_worker_hello, From, Node, Meta}) ->
    with_ok([
        valid_pid(From),
        valid_node(Node),
        validate_hello_meta(Meta)
    ]);
validate({janus_worker_hello_ack, Node, #{vsn := ?VSN} = Meta}) ->
    with_ok([
        valid_node(Node),
        %% Wire compression (ocr review): the capability key, IF
        %% present, must be a proper list of atoms (tolerant of
        %% future multi-codec lists) — the planned worker-dispatch
        %% consumer reads it; a malformed value is a boundary
        %% rejection, never a consumer crash. Absent = old master.
        valid_ack_wire_enc(maps:find(wire_enc, Meta))
    ]);
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
%% 5-tuple (spec 2026-10-12 D2): BOTH arities validate — decode is
%% tag-driven (F1), the master normalizes 4 => 5 before handling.
validate({janus_chunk, JobRef, Seq, Bin, Meta}) ->
    with_ok([
        valid_job_ref(JobRef),
        validate_chunk_seq(Seq),
        valid_binary(Bin),
        valid_chunk_meta(Meta)
    ]);
validate({janus_done, JobRef, Fields}) ->
    with_ok([valid_job_ref(JobRef), validate_done_fields(Fields)]);
validate({janus_error, JobRef, #{code := Code, message := Message} = Fields}) ->
    with_ok([
        valid_job_ref(JobRef),
        valid_error_code(Code),
        valid_binary(Message),
        %% Error payloads are NEVER compressed (spec 2026-10-12 D2):
        %% an `enc` key on janus_error is a contract violation AT THE
        %% BOUNDARY (ocr review — defense-in-depth with the error/4
        %% constructor strip); other additive keys stay tolerated.
        valid_error_no_enc(Fields)
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

validate_hello_meta(#{role := Role, vsn := Vsn} = Meta) ->
    with_ok([
        case Role of
            worker -> ok;
            _ -> {error, {bad_role, Role}}
        end,
        case Vsn of
            ?VSN -> ok;
            _ -> {error, {bad_vsn, Vsn}}
        end,
        case maps:get(region, Meta, undefined) of
            undefined -> ok;
            R when is_binary(R) -> ok;
            _ -> {error, bad_region}
        end
    ]);
validate_hello_meta(_) ->
    {error, bad_hello_meta}.

-define(JOB_REQUIRED, [url, method, headers, body, stream, timeout_ms, protocol_meta]).

validate_job_fields(Fields) when is_map(Fields) ->
    case lists:all(fun(K) -> maps:is_key(K, Fields) end, ?JOB_REQUIRED) of
        false ->
            {error, bad_job_fields};
        true ->
            with_ok([
                maps_find(url, Fields, fun valid_binary/1),
                maps_find(method, Fields, fun valid_method/1),
                maps_find(headers, Fields, fun valid_headers/1),
                maps_find(body, Fields, fun valid_body/1),
                maps_find(stream, Fields, fun valid_boolean/1),
                maps_find(timeout_ms, Fields, fun valid_timeout_ms/1),
                maps_find(protocol_meta, Fields, fun valid_protocol_meta/1)
            ])
    end;
validate_job_fields(_) ->
    {error, bad_job_fields}.

maps_find(Key, Map, Fun) ->
    case maps:find(Key, Map) of
        {ok, Val} -> Fun(Val);
        error -> {error, bad_job_fields}
    end.

%% Done fields with the OPTIONAL top-level `enc => zlib` key
%% (spec 2026-10-12 D2 — body-only compression; extra additive keys
%% like rtt_ms keep passing, the partial-map match tolerates them).
validate_done_fields(#{usage := Usage, status := Status, trailers := Trailers, body := Body} = Fields) ->
    with_ok([
        valid_usage(Usage),
        valid_status(Status),
        valid_map(Trailers),
        valid_done_body(Body),
        %% enc => zlib compresses ONLY the body value (D2): the tag
        %% implies a BINARY body — `enc => zlib` + undefined/non-binary
        %% body is an inconsistent message rejected here (ocr review),
        %% so the decode side can never funnel a non-binary into
        %% janus_wire_enc:inflate/2. maps:find (not maps:get) so an
        %% EXPLICIT `enc => undefined` is a violation, not absence.
        valid_done_enc(maps:find(enc, Fields), Body)
    ]);
validate_done_fields(_) ->
    {error, bad_done_fields}.

%% Chunk meta (spec 2026-10-12 D2/F1): any map; an `enc` key, IF
%% present, must be exactly the atom `zlib` — anything else (future
%% or corrupt tag, a binary "zlib", an explicit `enc => undefined`)
%% is a contract violation => {error, bad_enc}, never passed to
%% parsers. Presence is detected with maps:find (ocr review):
%% maps:get/3 would conflate an explicit undefined with absence.
valid_chunk_meta(Meta) when is_map(Meta) ->
    case maps:find(enc, Meta) of
        error -> ok;
        {ok, Tag} -> valid_enc_tag(Tag)
    end;
valid_chunk_meta(_) ->
    {error, bad_chunk_meta}.

%% Shared enc-tag rule for chunk meta (F1): called ONLY for a PRESENT
%% enc key (the find/get callers own absence) — the value must be
%% exactly the atom zlib.
valid_enc_tag(zlib) ->
    ok;
valid_enc_tag(_Other) ->
    {error, bad_enc}.

%% Done-specific enc rule: NOT a delegation to valid_enc_tag/1 (ocr
%% review suggestion declined): valid_done_body/1 tolerates
%% `undefined`, so the binary-body requirement for a zlib tag is LIVE
%% here exactly for the `enc => zlib` + `body => undefined` case; a
%% defined non-binary body already fails valid_done_body first.
valid_done_enc(error, _Body) ->
    ok;
valid_done_enc({ok, zlib}, Body) when is_binary(Body) ->
    ok;
valid_done_enc(_Other, _Body) ->
    {error, bad_enc}.

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

%% janus_error carries no enc tag ever (D2 — never compressed).
valid_error_no_enc(Fields) when is_map(Fields) ->
    case maps:is_key(enc, Fields) of
        true -> {error, bad_enc};
        false -> ok
    end.

%% Ack capability key (spec 2026-10-12 D2): absent = old master (ok);
%% present = proper list of atoms (ocr review — the worker-dispatch
%% consumer must never see a value that crashes list handling).
valid_ack_wire_enc(error) ->
    ok;
valid_ack_wire_enc({ok, Codecs}) when is_list(Codecs) ->
    try
        case lists:all(fun is_atom/1, Codecs) of
            true -> ok;
            false -> {error, bad_ack_wire_enc}
        end
    catch
        %% Improper list: lists:all would raise — boundary rejects.
        _:_ -> {error, bad_ack_wire_enc}
    end;
valid_ack_wire_enc({ok, _NotAList}) ->
    {error, bad_ack_wire_enc}.

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
