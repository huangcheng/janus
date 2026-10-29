%%%-------------------------------------------------------------------
%%% @doc Fleet TLS dist helpers (spec Part A identity model).
%%%
%%% verify/3 is the handshake `verify_fun` rendered into the
%%% ssl_dist_optfile with pinned-chain semantics:
%%% - event `valid_peer` (the leaf): SAN dNSNames normalized to
%%%   binaries, >= 1 must be in the init-state peer list (binaries —
%%%   the rendered state is exactly the JANUS_FLEET_PEERS entries);
%%% - EVERY other event returns `{unknown, State}` — never
%%%   `{valid, _}`, so the fun can never rescue a failed path
%%%   validation (a self-signed cert carrying a peer's SAN still dies
%%%   at unknown_ca).
%%%
%%% Client-side verification is OTP-automatic (SNI = full node name +
%%% pkix_verify_hostname), so node certs are issued with SAN dNSName =
%%% the full node name `janus@<host>`.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_fleet_tls).

-include_lib("public_key/include/OTP-PUB-KEY.hrl").

-export([verify/3, san_dns_names/1, cert_days_remaining/1]).

%% @doc Pinned-chain verify_fun for the ssl_dist_optfile server opts:
%% `{verify_fun, {fun janus_fleet_tls:verify/3, [<<"janus@hostB">>, ...]}}`.
-spec verify(term(), valid_peer | valid | {extension, _} | {bad_cert, _}, [binary()]) ->
    {valid, [binary()]} | {fail, san_not_in_peer_set} | {unknown, [binary()]}.
verify(OtpCert, valid_peer, PeerNames) when is_list(PeerNames) ->
    Names = san_dns_names(OtpCert),
    case lists:any(fun(N) -> lists:member(N, PeerNames) end, Names) of
        true -> {valid, PeerNames};
        false -> {fail, san_not_in_peer_set}
    end;
verify(_OtpCert, _Event, State) ->
    %% Never-rescue semantics (Part 0.6b): everything that is not the
    %% leaf-cert membership decision is `unknown`, deferring to the
    %% normal path validation.
    {unknown, State}.

%% SAN dNSNames as binaries. The cert arrives in the OTP shape ssl
%% hands to verify_fun ('OTPCertificate'); extraction is structural so
%% both otp and plain der-decoded shapes work.
-spec san_dns_names(term()) -> [binary()].
san_dns_names(Der) when is_binary(Der) ->
    try
        san_dns_names(public_key:pkix_decode_cert(Der, otp))
    catch
        _:_ -> []
    end;
san_dns_names(Cert) when tuple_size(Cert) >= 2 ->
    Tbs = element(2, Cert),
    case element_size(Tbs) >= 11 of
        true ->
            Extensions = element(11, Tbs),
            san_dns_from_extensions(Extensions);
        false ->
            []
    end;
san_dns_names(_) ->
    [].


element_size(T) when is_tuple(T) -> tuple_size(T);
element_size(_) -> 0.

san_dns_from_extensions(Extensions) when is_list(Extensions) ->
    lists:flatmap(
        fun
            (#'Extension'{extnID = {2, 5, 29, 17}, extnValue = DerGenNames}) ->
                general_names_dns(DerGenNames);
            ({extension, {2, 5, 29, 17}, _Critical, DerGenNames}) ->
                general_names_dns(DerGenNames);
            (_) ->
                []
        end,
        Extensions
    );
san_dns_from_extensions(_) ->
    [].

%% In the otp decode the extension value is ALREADY the decoded
%% GeneralNames list; the plain/native decode leaves raw DER. Accept
%% both so the fun works against any cert shape ssl hands it.
general_names_dns(ExtValue) ->
    Gns =
        case ExtValue of
            G when is_list(G) ->
                G;
            Der when is_binary(Der) ->
                case catch public_key:der_decode('SubjectAltName', Der) of
                    Decoded when is_list(Decoded) -> Decoded;
                    _ -> []
                end;
            _ ->
                []
        end,
    [N || {dNSName, N0} <- Gns, N <- [normalize_bin(N0)], N =/= <<>>].

normalize_bin(N) when is_binary(N) -> N;
normalize_bin(N) when is_list(N) -> unicode:characters_to_binary(N);
normalize_bin(_) -> <<>>.

%% @doc Days until the leaf cert's notAfter (can be negative — an
%% expired cert must be visible as such). Cached by the caller
%% (janus_fleet) against the file mtime.
-spec cert_days_remaining(file:filename_all()) -> {ok, integer()} | error.
cert_days_remaining(Path) ->
    try
        {ok, Pem} = file:read_file(Path),
        [{'Certificate', Der, _}] = public_key:pem_decode(Pem),
        Cert = public_key:pkix_decode_cert(Der, otp),
        NotAfter = validity_not_after(element(2, Cert)),
        Days = calendar:time_difference(
            calendar:universal_time(), NotAfter
        ),
        DaysSec = days_to_seconds(Days),
        %% Round toward negative infinity so 0 = "expires today".
        {ok, DaysSec div 86400}
    catch
        Class:Reason ->
            logger:warning(#{
                what => janus_fleet_cert_days_failed,
                path => Path,
                class => Class,
                reason => Reason
            }),
            error
    end.

days_to_seconds({Days, Time}) ->
    Days * 86400 + calendar:time_to_seconds(Time).

%% 'Validity' sits at element 6 of the OTP TBS certificate: the ASN.1
%% native shape (plain der_decode) uses {validity, NotBefore, NotAfter}
%% tuples; be tolerant of record/atom spellings.
validity_not_after(Tbs) when tuple_size(Tbs) >= 6 ->
    Validity = element(6, Tbs),
    parse_asn1_time(element(3, Validity)).

parse_asn1_time({utcTime, Str}) ->
    asn1_time(Str, short);
parse_asn1_time({generalTime, Str}) ->
    asn1_time(Str, long);
parse_asn1_time({_, Str}) when is_list(Str) ->
    asn1_time(Str, guess);
parse_asn1_time(_) ->
    erlang:error(bad_validity).

asn1_time(Str, Kind) ->
    Digits = [D || D <- Str, D >= $0, D =< $9],
    case {Kind, length(Digits)} of
        {short, N} when N >= 12 -> utc(short, Str);
        {long, N} when N >= 14 -> utc(long, Str);
        {guess, N} when N >= 14 -> utc(long, Str);
        {guess, N} when N >= 12 -> utc(short, Str);
        _ ->
            erlang:error(bad_validity)
    end.

utc(short, [Y1, Y2, M1, M2, D1, D2, H1, H2, Mi1, Mi2, S1, S2 | _]) ->
    {{two_digit_year(Y1, Y2), two_digit(M1, M2), two_digit(D1, D2)},
        {two_digit(H1, H2), two_digit(Mi1, Mi2), two_digit(S1, S2)}};
utc(long, [Y1, Y2, Y3, Y4, M1, M2, D1, D2, H1, H2, Mi1, Mi2, S1, S2 | _]) ->
    {{two_digit(Y1, Y2) * 100 + two_digit(Y3, Y4), two_digit(M1, M2), two_digit(D1, D2)},
        {two_digit(H1, H2), two_digit(Mi1, Mi2), two_digit(S1, S2)}}.

two_digit(A, B) ->
    (A - $0) * 10 + (B - $0).

%% RFC 5280 UTCTime: YY < 50 means 20YY, else 19YY.
two_digit_year(A, B) ->
    YY = two_digit(A, B),
    case YY < 50 of
        true -> 2000 + YY;
        false -> 1900 + YY
    end.
