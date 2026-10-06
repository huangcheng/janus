%%%-------------------------------------------------------------------
%%% @doc Resolve the client-facing request id: honor a well-formed
%%% inbound x-request-id, else generate req_<16 lowercase hex>.
%%% Well-formed = 1..128 bytes of [A-Za-z0-9-_]. Anything else is
%%% ignored (never echoed back — response-header injection hygiene).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_request_id).

-export([resolve/1]).

-define(MAX_LEN, 128).

-spec resolve(binary() | undefined) -> binary().
resolve(In) when is_binary(In), byte_size(In) >= 1, byte_size(In) =< ?MAX_LEN ->
    case valid(In) of
        true -> In;
        false -> generate()
    end;
resolve(_) ->
    generate().

valid(Bin) ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse
                (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse
                C =:= $- orelse C =:= $_
        end,
        binary_to_list(Bin)
    ).

generate() ->
    %% encode_hex is uppercase; lowercase to match the documented
    %% req_[0-9a-f]{16} shape. crypto:strong_rand_bytes is guarded:
    %% request ids must never 500 a request — fall back to a
    %% unique_integer-derived id PADDED to 8 bytes first (the 16-hex
    %% shape holds either way). NOTE: binary:encode_unsigned/2's second
    %% arg is the ENDIANNESS, not a pad size — pad via a binary pattern.
    try
        Hex = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(8))),
        <<"req_", Hex/binary>>
    catch
        _:_ ->
            I = erlang:unique_integer([positive]),
            FallbackHex = string:lowercase(binary:encode_hex(<<I:64/big>>)),
            <<"req_", FallbackHex/binary>>
    end.
