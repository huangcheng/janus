"""WebAuthn/passkey support with zero dedicated dependencies — challenge
store in memory (TTL 5 min, single instance), COSE key parsing and
signature verification via `cryptography`.

Supported algorithms (covers every mainstream authenticator):
  ES256 (COSE alg -7, P-256 + SHA-256)  — passkeys in browsers/phones
  RS256 (COSE alg -257, RSA 2048 + SHA-256) — some security keys

The wire format is the browser's PublicKeyCredential JSON: credential
ids and challenges are base64url strings. Authdata layout per
WebAuthn L3 §6.5.6; we verify (in order) challenge, origin, RP ID
hash, user-present/user-verified flags, and the signature over
authenticatorData || SHA256(clientDataJSON). Registration additionally
parses the attested credential data (public key from the CBOR map).

Counter (sign_count) clone detection: a lower-or-equal counter on a
credential that has one (>0 initial) is rejected and logged; the
count advances on every successful assertion.
"""

import base64
import hashlib
import hmac
import json
import logging
import secrets
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

logger = logging.getLogger("janus.dashboard.passkey")

CHALLENGE_TTL_SEC = 300
_allowed_origins: set[str] = set()


def b64url_decode(s: str) -> bytes:
    """base64url without padding — WebAuthn's idiom."""
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def b64url_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


class PasskeyError(Exception):
    """Verification failure; .code maps to the API error body."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# --- challenge store (single instance, in memory) ---

_challenges: dict[str, tuple[bytes, float, str]] = {}
# challenge_b64 -> (raw bytes, expires_at, kind "assert"|"create")
_last_sweep = 0.0


def _sweep(now: float) -> None:
    global _last_sweep
    if now - _last_sweep < 60:
        return
    _last_sweep = now
    for k in [k for k, (_, exp, _) in _challenges.items() if exp < now]:
        _challenges.pop(k, None)


def new_challenge(kind: str) -> str:
    """32 random bytes, one-time, 5-minute TTL. Consumed on verify."""
    now = time.time()
    _sweep(now)
    raw = secrets.token_bytes(32)
    key = b64url_encode(raw)
    _challenges[key] = (raw, now + CHALLENGE_TTL_SEC, kind)
    return key


def consume_challenge(kind: str, presented_b64: str) -> bytes:
    entry = _challenges.pop(presented_b64, None)
    if entry is None:
        raise PasskeyError("passkey_challenge", "unknown or already-used challenge")
    raw, exp, stored_kind = entry
    if exp < time.time() or stored_kind != kind:
        raise PasskeyError("passkey_challenge", "challenge expired or wrong kind")
    return raw


def set_allowed_origins(origins: set[str]) -> None:
    _allowed_origins.clear()
    _allowed_origins.update(origins)


# --- clientDataJSON ---


def _verify_client_data(client_data_b64: str, expected_challenge: bytes, kind: str) -> None:
    try:
        cdj = json.loads(b64url_decode(client_data_b64))
    except (ValueError, TypeError):
        raise PasskeyError("passkey_format", "clientDataJSON is not valid base64url JSON")
    if cdj.get("type") != f"webauthn.{kind}":
        raise PasskeyError("passkey_format", f"clientData type is not webauthn.{kind}")
    presented = cdj.get("challenge")
    if not isinstance(presented, str) or not hmac.compare_digest(
        b64url_decode(presented), expected_challenge
    ):
        raise PasskeyError("passkey_challenge", "challenge mismatch")
    origin = cdj.get("origin")
    if not isinstance(origin, str) or origin not in _allowed_origins:
        raise PasskeyError("passkey_origin", f"origin {origin!r} is not this deployment")


# --- authenticatorData ---


def _parse_authdata(authdata: bytes) -> dict:
    """Fixed header (37 bytes) + optional attested credential data +
    optional extensions. Returns flags/counter and, when present, the
    embedded credential id + COSE public key bytes."""
    if len(authdata) < 37:
        raise PasskeyError("passkey_format", "authenticatorData shorter than 37 bytes")
    rp_id_hash = authdata[:32]
    flags = authdata[32]
    counter = int.from_bytes(authdata[33:37], "big")
    out = {
        "rp_id_hash": rp_id_hash,
        "up": bool(flags & 0x01),
        "uv": bool(flags & 0x04),
        "att_data": bool(flags & 0x40),
        "counter": counter,
    }
    if out["att_data"]:
        body = authdata[37:]
        if len(body) < 18:
            raise PasskeyError("passkey_format", "attested credential data truncated")
        aaguid = body[:16]
        cred_len = int.from_bytes(body[16:18], "big")
        rest = body[18:]
        if len(rest) < cred_len:
            raise PasskeyError("passkey_format", "credential id truncated")
        out["credential_id"] = rest[:cred_len]
        out["cose_start"] = 18 + cred_len  # offset into body
        out["_aaguid"] = aaguid
        out["_body"] = body
    return out


# --- minimal CBOR (enough for COSE keys) ---
# COSE key map: {1: kty, 3: alg, -1: crv/n, -2: x/e, -3: y/n}
# Only what the two supported algs need — no general CBOR.


def _cbor_read(buf: bytes, pos: int) -> tuple[object, int]:
    """Decode one CBOR item at pos -> (value, next_pos). Handles exactly
    the types WebAuthn structures use: uints, negative ints, byte/text
    strings, arrays, maps. The initial byte's additional-info IS the
    value/length when < 24 — never another element."""
    ib = buf[pos]
    mt, ai = ib >> 5, ib & 0x1F
    pos += 1
    if ai < 24:
        arg = ai
    elif ai == 24:
        arg = buf[pos]
        pos += 1
    elif ai == 25:
        arg = int.from_bytes(buf[pos : pos + 2], "big")
        pos += 2
    elif ai == 26:
        arg = int.from_bytes(buf[pos : pos + 4], "big")
        pos += 4
    elif ai == 27:
        arg = int.from_bytes(buf[pos : pos + 8], "big")
        pos += 8
    else:
        raise PasskeyError("passkey_format", "indefinite-length CBOR is not supported")
    if mt == 0:  # unsigned int
        return arg, pos
    if mt == 1:  # negative int: -1 - arg
        return -1 - arg, pos
    if mt in (2, 3):  # byte string / text string
        if pos + arg > len(buf):
            raise PasskeyError("passkey_format", "CBOR string runs past the buffer")
        raw = buf[pos : pos + arg]
        return (raw.decode() if mt == 3 else raw), pos + arg
    if mt == 4:  # array (e.g. x5c cert chains inside attStmt)
        arr = []
        for _ in range(arg):
            v, pos = _cbor_read(buf, pos)
            arr.append(v)
        return arr, pos
    if mt == 5:  # map
        m = {}
        for _ in range(arg):
            k, pos = _cbor_read(buf, pos)
            v, pos = _cbor_read(buf, pos)
            m[k] = v
        return m, pos
    raise PasskeyError("passkey_format", f"unsupported CBOR major type {mt}")


def cose_key_from_authdata(parsed: dict) -> tuple[str, bytes]:
    """Extract (public_key_serialized, alg) from attested credential
    data. The serialized form re-encodes the COSE map bytes so the
    stored TEXT column is exactly what we parsed."""
    body = parsed["_body"]
    cose_map, _end = _cbor_read(body, parsed["cose_start"])
    # re-serialize deterministically: our own encoder for a flat map
    if not isinstance(cose_map, dict):
        raise PasskeyError("passkey_format", "COSE key is not a map")
    alg = cose_map.get(3)
    if alg not in (-7, -257):
        raise PasskeyError("passkey_alg", f"unsupported COSE alg {alg} (need ES256 or RS256)")
    encoded = _encode_cose(cose_map)
    return encoded, alg


def _encode_cose(m: dict) -> str:
    """Hex of a canonical CBOR map with keys sorted ascending."""
    keys = sorted(m.keys(), key=lambda k: (isinstance(k, str), str(k)))

    def head(mt: int, v: int) -> bytes:
        if v < 24:
            return bytes([(mt << 5) | v])
        if v < 0x100:
            return bytes([(mt << 5) | 24, v])
        if v < 0x10000:
            return bytes([(mt << 5) | 25]) + v.to_bytes(2, "big")
        return bytes([(mt << 5) | 26]) + v.to_bytes(4, "big")

    def item(v) -> bytes:
        if isinstance(v, int):
            return head(0, v) if v >= 0 else head(1, -1 - v)
        if isinstance(v, bytes):
            return head(2, len(v)) + v
        if isinstance(v, str):
            b = v.encode()
            return head(3, len(b)) + b
        raise PasskeyError("passkey_format", "unsupported value type in COSE map")

    n = len(keys)
    out = bytes([(5 << 5) | n]) if n < 24 else bytes([(5 << 5) | 24, n])
    for k in keys:
        out += item(k) + item(m[k])
    return out.hex()


def _load_cose_public_key(serialized_hex: str):
    """Deserialize our stored canonical COSE map into a cryptography
    public key object (EC P-256 or RSA)."""
    m, _ = _cbor_read(bytes.fromhex(serialized_hex), 0)
    alg = m.get(3)
    if alg == -7:  # ES256 — EC2 layout: -1 crv, -2 x, -3 y
        x = m[-2]
        y = m[-3]
        if not isinstance(x, bytes) or not isinstance(y, bytes) or len(x) != 32 or len(y) != 32:
            raise PasskeyError("passkey_format", "P-256 coordinates must be 32 bytes each")
        if m.get(-1) != 1:  # crv 1 = P-256
            raise PasskeyError("passkey_alg", "only the P-256 curve is supported")
        return ec.EllipticCurvePublicNumbers(
            int.from_bytes(x, "big"), int.from_bytes(y, "big"), ec.SECP256R1()
        ).public_key()
    if alg == -257:  # RS256 — RSA layout: -1 n, -2 e
        n = m[-1]
        e = m[-2]
        if not isinstance(n, bytes) or not isinstance(e, bytes):
            raise PasskeyError("passkey_format", "RSA modulus/exponent must be byte strings")
        return rsa.RSAPublicNumbers(int.from_bytes(e, "big"), int.from_bytes(n, "big")).public_key()
    raise PasskeyError("passkey_alg", f"stored key has unsupported alg {alg}")


# --- verification entry points ---


def verify_assertion(
    *,
    credential_id_b64: str,
    client_data_b64: str,
    authdata_b64: str,
    signature_b64: str,
    expected_challenge: bytes,
    expected_rp_id: str,
    stored_public_key_hex: str,
    stored_sign_count: int,
) -> int:
    """Verify a navigator.credentials.get() assertion. Returns the new
    sign_count. Raises PasskeyError on any failure."""
    _verify_client_data(client_data_b64, expected_challenge, "get")
    authdata = b64url_decode(authdata_b64)
    parsed = _parse_authdata(authdata)
    if parsed["rp_id_hash"] != hashlib.sha256(expected_rp_id.encode()).digest():
        raise PasskeyError("passkey_rp", "authenticatorData RP ID hash mismatch")
    if not parsed["up"]:
        raise PasskeyError("passkey_flags", "user-present flag not set")

    # (caller checks the credential id matches the row)
    # Possible cloned authenticator: a regression from a nonzero count.
    # WebAuthn allows non-incrementing counters only when both are 0.
    if stored_sign_count > 0 and 0 < parsed["counter"] <= stored_sign_count:
        raise PasskeyError(
            "passkey_counter",
            f"signature counter did not advance (stored {stored_sign_count}, got {parsed['counter']})",
        )

    key = _load_cose_public_key(stored_public_key_hex)
    signature = b64url_decode(signature_b64)
    signed = authdata + hashlib.sha256(b64url_decode(client_data_b64)).digest()
    try:
        if isinstance(key, ec.EllipticCurvePublicKey):
            # WebAuthn ES256 signatures are DER-encoded ECDSA.
            key.verify(signature, signed, ec.ECDSA(hashes.SHA256()))
        else:
            key.verify(signature, signed, padding.PKCS1v15(), hashes.SHA256())
    except Exception:
        raise PasskeyError("passkey_signature", "signature verification failed")
    return parsed["counter"]


def _unwrap_attestation(attestation_b64: str) -> bytes:
    """attestationObject is the CBOR map {fmt, attStmt, authData} — not
    raw authenticatorData. We never verify the attestation chain (the
    new key is proven the first time it signs an assertion), but the map
    itself must parse so authData can be extracted. Browsers send fmt
    none/packed/tpm/android-key; their attStmt values are only
    ints/bytes/texts/maps/arrays, which the reader handles."""
    blob = b64url_decode(attestation_b64)
    obj, _ = _cbor_read(blob, 0)
    if not isinstance(obj, dict) or not isinstance(obj.get("authData"), (bytes, bytearray)):
        raise PasskeyError(
            "passkey_format", "attestationObject is not a {fmt, attStmt, authData} map"
        )
    return obj["authData"]


def verify_registration(
    *,
    client_data_b64: str,
    attestation_b64: str,
    expected_challenge: bytes,
    expected_rp_id: str,
) -> tuple[str, str]:
    """Verify a navigator.credentials.create() attestationObject.
    Returns (credential_id_b64, public_key_hex). Requires attested
    credential data (the new key)."""
    _verify_client_data(client_data_b64, expected_challenge, "create")
    authdata = _unwrap_attestation(attestation_b64)
    parsed = _parse_authdata(authdata)
    if parsed["rp_id_hash"] != hashlib.sha256(expected_rp_id.encode()).digest():
        raise PasskeyError("passkey_rp", "authenticatorData RP ID hash mismatch")
    if not parsed["up"]:
        raise PasskeyError("passkey_flags", "user-present flag not set")
    if not parsed["att_data"] or "credential_id" not in parsed:
        raise PasskeyError(
            "passkey_format", "registration response has no attested credential data"
        )
    pub_hex, _alg = cose_key_from_authdata(parsed)
    return b64url_encode(parsed["credential_id"]), pub_hex
