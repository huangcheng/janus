%%%-------------------------------------------------------------------
%%% @doc Pure multipart/form-data parser (RFC 7578 / RFC 2046) for the
%%% ASR plugin (spec M2.2). Cowboy exposes read_part/read_part_body,
%%% but the modality front door reads ONE buffered body under the
%%% 25MiB cap — this parser turns those raw bytes into fields/files
%%% and is also chunk-safe: `parse_stream/2` feeds iodata chunks
%%% through the SAME state machine, so a boundary or a binary payload
%%% straddling chunk seams parses identically to the whole body (a
%%  scan cursor makes the re-scan cost O(chunk), not O(body)).
%%%
%%% Delimiter grammar (curl -F emits exactly this):
%%%   body      := dash_boundary (part CRLF dash_boundary)*
%%%                dash_boundary "--" epilogue?
%%%   dash_boundary := "--" boundary
%%%   part      := headers CRLF CRLF data   (data is byte-transparent:
%%%                only the FULL CRLF "--" boundary sequence cuts)
%%% Binary payloads are never logged (A8) and never spooled to disk.
%%% All functions are pure: no IO, no side effects.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_multipart).

-export([
    boundary_of/1,
    parse/2,
    parse_stream/2,
    init/1,
    feed/2,
    finish/1
]).

%% mode: pre          — bytes before the first dash-boundary (preamble)
%%       after_dash   — consumed "--" boundary, deciding CRLF vs "--"
%%       headers      — accumulating a part's header block
%%       data         — accumulating part data until the next delimiter
%%       done         — close delimiter seen; epilogue is ignored
%%
%% parts accumulate REVERSED; scan counts buf bytes already confirmed
%% delimiter-free (data-mode rescan cursor).
-record(state, {
    boundary :: binary(),
    mode = pre :: pre | after_dash | headers | data | done,
    buf = <<>> :: binary(),
    meta = undefined :: undefined | {Name :: binary() | undefined, Filename :: binary() | undefined, ContentType :: binary() | undefined},
    scan = 0 :: non_neg_integer(),
    parts = [] :: [term()]
}).

-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================

%% Extract the boundary token from a request content-type header.
%% Strict: only multipart/form-data with a boundary parameter passes
%% (A8 content-type validation); anything else is `error`. The media
%% type is matched case-insensitively but the boundary TOKEN is
%% case-sensitive (RFC 2046) and is returned verbatim, unquoted.
-spec boundary_of(binary() | undefined) -> {ok, binary()} | error.
boundary_of(CT) when is_binary(CT), byte_size(CT) > 0 ->
    [Type | Params] = binary:split(CT, <<";">>, [global]),
    case strip(lower(Type)) of
        <<"multipart/form-data">> ->
            boundary_param(Params);
        _ ->
            error
    end;
boundary_of(_) ->
    error.

boundary_param([]) ->
    error;
boundary_param([Seg | Rest]) ->
    case binary:split(strip(Seg), <<"=">>) of
        [K, V] when byte_size(V) > 0 ->
            case lower(K) of
                <<"boundary">> -> {ok, unquote(strip(V))};
                _ -> boundary_param(Rest)
            end;
        _ ->
            boundary_param(Rest)
    end.

%% Whole-body parse.
-spec parse(binary(), binary()) ->
    {ok, #{fields => #{binary() => binary()}, files => [map()]}} | {error, bad_multipart}.
parse(Body, Boundary) when is_binary(Body), is_binary(Boundary) ->
    parse_stream([Body], Boundary).

%% Chunked parse: the list of iodata chunks a socket/stream reader
%% produced. Chunks may split boundaries, headers and payloads at ANY
%% byte — the result is identical to parse/2 on the concatenation.
-spec parse_stream([iodata()], binary()) ->
    {ok, #{fields => #{binary() => binary()}, files => [map()]}} | {error, bad_multipart}.
parse_stream(Chunks, Boundary) when is_list(Chunks), is_binary(Boundary), byte_size(Boundary) > 0 ->
    %% foldl hands (Element, Acc) to the fun — feed/2 is (State, Data).
    finish(lists:foldl(fun(Data, S) -> feed(S, Data) end, init(Boundary), Chunks)).

-spec init(binary()) -> state().
init(Boundary) when is_binary(Boundary), byte_size(Boundary) > 0 ->
    #state{boundary = Boundary}.

%% Feed one chunk. Never raises and never errors eagerly: malformed
%% structure simply stops consuming and surfaces at finish/1.
-spec feed(state() | {error, bad_multipart}, iodata()) -> state() | {error, bad_multipart}.
feed({error, bad_multipart} = Err, _Data) ->
    Err;
feed(#state{mode = done} = S, _Data) ->
    S;
feed(#state{} = S0, Data) ->
    S = S0#state{buf = <<(S0#state.buf)/binary, (iodata_bin(Data))/binary>>},
    run(S).

%% Terminal pass: the close delimiter must have been seen (a body cut
%% before it is malformed — its dangling part is never emitted).
-spec finish(state() | {error, bad_multipart}) ->
    {ok, #{fields => #{binary() => binary()}, files => [map()]}} | {error, bad_multipart}.
finish({error, bad_multipart}) ->
    {error, bad_multipart};
finish(#state{mode = done, parts = Parts}) ->
    Ordered = lists:reverse(Parts),
    Fields = maps:from_list([{N, V} || {field, N, V} <- Ordered]),
    Files = [F || {file, F} <- Ordered],
    {ok, #{fields => Fields, files => Files}};
finish(#state{}) ->
    {error, bad_multipart}.

%%%===================================================================
%%% Incremental state machine
%%%===================================================================

run(#state{mode = pre} = S) ->
    case pre_step(S) of
        {consume, S2} -> run(S2);
        hold -> S
    end;
run(#state{mode = after_dash} = S) ->
    case after_dash_step(S) of
        {consume, S2} -> run(S2);
        hold -> S
    end;
run(#state{mode = headers} = S) ->
    case headers_step(S) of
        {consume, S2} -> run(S2);
        hold -> S
    end;
run(#state{mode = data} = S) ->
    case data_step(S) of
        {consume, S2} -> run(S2);
        {hold, S2} -> S2
    end;
run(#state{mode = done} = S) ->
    S.

%% Preamble: skip bytes until the first "--" boundary. Preambles are
%% legal (RFC 2046) though curl never emits one.
pre_step(#state{boundary = B, buf = Buf} = S) ->
    Dash = <<"--", B/binary>>,
    case binary:match(Buf, Dash) of
        {Pos, Len} ->
            {consume, S#state{buf = drop(Buf, Pos + Len), mode = after_dash, scan = 0}};
        nomatch ->
            hold
    end.

%% After "--" boundary: transport padding (SP/TAB), then either CRLF
%% (a part follows) or "--" (close). Indecidable tails hold for more
%% bytes; anything else is junk that can never become valid — hold and
%% let finish/1 report bad_multipart.
after_dash_step(#state{buf = <<C, Rest/binary>>} = S) when C =:= $\s; C =:= $\t ->
    {consume, S#state{buf = Rest, scan = 0}};
after_dash_step(#state{buf = <<"\r\n", Rest/binary>>} = S) ->
    {consume, S#state{buf = Rest, mode = headers, scan = 0}};
after_dash_step(#state{buf = <<"--", _/binary>>} = S) ->
    {consume, S#state{buf = <<>>, mode = done, scan = 0}};
after_dash_step(_) ->
    hold.

%% Header block: runs to the blank line. A block starting with CRLF is
%% empty (no headers — still a legal part).
headers_step(#state{buf = <<"\r\n", Rest/binary>>} = S) ->
    {consume, enter_data(S, <<>>, Rest)};
headers_step(#state{buf = Buf} = S) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        {Pos, _} ->
            HdrBlob = binary:part(Buf, 0, Pos),
            Rest = drop(Buf, Pos + 4),
            {consume, enter_data(S, HdrBlob, Rest)};
        nomatch ->
            hold
    end.

enter_data(S, HdrBlob, Rest) ->
    S#state{buf = Rest, mode = data, scan = 0, meta = part_meta(HdrBlob)}.

%% Part data: byte-transparent until the FULL CRLF "--" boundary
%% sequence. The scan cursor avoids rescanning confirmed-clean bytes
%% on every feed (a partial delimiter tail is re-checked by
%% backtracking delim_size-1 bytes).
data_step(#state{boundary = B, buf = Buf, meta = Meta} = S) ->
    Delim = <<"\r\n--", B/binary>>,
    DelimSize = byte_size(Delim),
    From = max(0, S#state.scan - (DelimSize - 1)),
    case match_from(Buf, From, Delim) of
        {ok, Abs} ->
            Data = binary:part(Buf, 0, Abs),
            Rest = drop(Buf, Abs + DelimSize),
            S2 = emit(S, Meta, Data),
            {consume, S2#state{buf = Rest, mode = after_dash, meta = undefined, scan = 0}};
        nomatch ->
            {hold, S#state{scan = byte_size(Buf)}}
    end.

match_from(Buf, From, Pat) when byte_size(Buf) - From > 0 ->
    case binary:match(Buf, Pat, [{scope, {From, byte_size(Buf) - From}}]) of
        %% binary:match/3 with a scope returns SUBJECT-relative
        %% positions (not scope-relative) — no From offset to add.
        {Pos, _} when Pos >= From ->
            {ok, Pos};
        {Pos, _} ->
            %% Cannot happen (bytes before From were already scanned
            %% clean) — fail loud rather than cut at a wrong offset.
            error({janus_multipart_scan, Pos, From});
        nomatch ->
            nomatch
    end;
match_from(_Buf, _From, _Pat) ->
    nomatch.

emit(S, {Name, Filename, CType}, Data) when Filename =/= undefined ->
    S#state{parts = [
        {file, #{
            name => Name,
            filename => Filename,
            content_type => CType,
            data => Data
        }}
        | S#state.parts
    ]};
emit(S, {Name, undefined, _}, Data) when Name =/= undefined ->
    S#state{parts = [{field, Name, Data} | S#state.parts]};
%% Parts without a Content-Disposition name are ignored wholesale.
emit(S, {undefined, undefined, _}, _Data) ->
    S.

%%%===================================================================
%%% Header block parsing
%%%===================================================================

%% {Name, Filename, ContentType} from a part's header blob.
%% ContentType is normalized (lowercase, params stripped) or undefined.
part_meta(<<>>) ->
    {undefined, undefined, undefined};
part_meta(HdrBlob) ->
    Hdrs = [header(Line) || Line <- binary:split(HdrBlob, <<"\r\n">>, [global]), Line =/= <<>>],
    CDP = cd_params(Hdrs),
    Name = maps:get(<<"name">>, CDP, undefined),
    Filename = maps:get(<<"filename">>, CDP, undefined),
    CType =
        case lists:keyfind(<<"content-type">>, 1, Hdrs) of
            {<<"content-type">>, CT} -> norm_ct(CT);
            false -> undefined
        end,
    {Name, Filename, CType}.

cd_params(Hdrs) ->
    case lists:keyfind(<<"content-disposition">>, 1, Hdrs) of
        {<<"content-disposition">>, V} ->
            lists:foldl(
                fun(Seg, Acc) ->
                    case binary:split(strip(Seg), <<"=">>) of
                        [K, Val] when byte_size(Val) > 0 -> Acc#{lower(K) => unquote(Val)};
                        _ -> Acc
                    end
                end,
                #{},
                binary:split(V, <<";">>, [global])
            );
        false ->
            #{}
    end.

header(Line) ->
    case binary:split(Line, <<":">>) of
        [N, V] -> {strip(lower(N)), strip(V)};
        [Only] -> {strip(lower(Only)), <<>>}
    end.

norm_ct(CT) ->
    case strip(binary:part(lower(CT), 0, ct_len(CT))) of
        <<>> -> undefined;
        Norm -> Norm
    end.

%% keep the media type, drop any "; params"
ct_len(CT) ->
    case binary:match(CT, <<";">>) of
        {Pos, _} -> Pos;
        nomatch -> byte_size(CT)
    end.

%%%===================================================================
%%% Small helpers
%%%===================================================================

iodata_bin(Data) when is_binary(Data) -> Data;
iodata_bin(Data) -> iolist_to_binary(Data).

drop(Bin, N) when N >= byte_size(Bin) -> <<>>;
drop(Bin, N) -> binary:part(Bin, N, byte_size(Bin) - N).

lower(Bin) when is_binary(Bin) -> string:lowercase(Bin).

strip(Bin) when is_binary(Bin) -> string:trim(Bin, both, " \t").

%% RFC 2045 quoted-string: strip quotes, honor backslash escapes; a
%% bare token is returned as-is.
unquote(<<"\"", Rest/binary>>) ->
    unquote_q(Rest, <<>>);
unquote(V) ->
    V.

unquote_q(<<"\\", C, Rest/binary>>, Acc) -> unquote_q(Rest, <<Acc/binary, C>>);
unquote_q(<<"\"", _Rest/binary>>, Acc) -> Acc;
unquote_q(<<C, Rest/binary>>, Acc) -> unquote_q(Rest, <<Acc/binary, C>>);
unquote_q(<<>>, Acc) -> Acc.
