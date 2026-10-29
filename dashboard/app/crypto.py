"""JSEC envelope encryption compatible with the Erlang gateway.

Binary format (big-endian):
    "JSEC"          4 bytes magic
    version         1 byte  (uint8, currently 1)
    key_id_len      2 bytes (uint16)
    key_id          key_id_len bytes (UTF-8)
    iv_len          1 byte  (uint8, always 12)
    iv              12 bytes
    tag_len         1 byte  (uint8, always 16)
    tag             16 bytes
    ciphertext      remaining bytes

AAD = key_id bytes.
Keys come from JANUS_SECRETS_KEY env: "key_id:base64key,..."
The first entry is the active write key.
"""

import base64
import hashlib
import hmac
import logging
import os
import struct

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .config import config

logger = logging.getLogger("janus.dashboard.crypto")

MAGIC = b"JSEC"
VERSION = 1

# Malformed-keyring warnings are emitted once per distinct message: the
# keyring is re-parsed on every crypto call, and a typo must be visible in
# the startup log, not repeated on every request.
_warned_keyring: set[str] = set()


def _warn_keyring_once(message: str) -> None:
    if message in _warned_keyring:
        return
    _warned_keyring.add(message)
    logger.warning("%s", message)


def _parse_keyring(env_value: str) -> dict[str, bytes]:
    """Parse 'kid:base64key,kid:base64key,...' into {kid: key_bytes}."""
    keys: dict[str, bytes] = {}
    if not env_value:
        return keys
    for index, entry in enumerate(env_value.split(",")):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(":", 1)
        if len(parts) != 2:
            _warn_keyring_once(
                f"JANUS_SECRETS_KEY entry #{index} ignored (expected 'key_id:base64key')"
            )
            continue
        kid, b64 = parts[0].strip(), parts[1].strip()
        try:
            key_bytes = base64.b64decode(b64)
        except Exception:
            _warn_keyring_once(f"JANUS_SECRETS_KEY entry {kid!r} ignored (invalid base64)")
            continue
        if len(key_bytes) != 32:
            _warn_keyring_once(
                f"JANUS_SECRETS_KEY entry {kid!r} ignored "
                f"(decoded key is {len(key_bytes)} bytes, need 32)"
            )
            continue
        keys[kid] = key_bytes
    return keys


def _keyring() -> dict[str, bytes]:
    return _parse_keyring(config.secrets_key)


def _active_key() -> tuple[str, bytes]:
    """Return (key_id, key_bytes) for the first (active) entry."""
    ring = _keyring()
    env_value = config.secrets_key
    for entry in env_value.split(","):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(":", 1)
        if len(parts) == 2 and parts[0].strip() in ring:
            return parts[0].strip(), ring[parts[0].strip()]
    raise ValueError("JANUS_SECRETS_KEY has no valid entries")


def encrypt(plaintext: bytes) -> bytes:
    """Encrypt plaintext into a JSEC envelope using the active key."""
    key_id, key = _active_key()
    return encrypt_with(plaintext, key, key_id)


def encrypt_with(plaintext: bytes, key: bytes, key_id: str) -> bytes:
    iv = os.urandom(12)
    # AESGCM.encrypt returns ciphertext||tag (tag is last 16 bytes)
    ct_and_tag = AESGCM(key).encrypt(iv, plaintext, key_id.encode())
    ct, tag = ct_and_tag[:-16], ct_and_tag[-16:]
    kid = key_id.encode()
    return (
        MAGIC
        + struct.pack(">B", VERSION)
        + struct.pack(">H", len(kid))
        + kid
        + bytes([12])
        + iv
        + bytes([16])
        + tag
        + ct
    )


def decrypt(envelope: bytes) -> bytes:
    """Decrypt a JSEC envelope, trying all keys in the keyring.

    Every length field is bounds-checked before slicing and the version
    byte is enforced, so a malformed/truncated envelope raises ValueError
    instead of struct.error/IndexError/UnicodeDecodeError (L2/L3).
    """
    if not envelope or envelope[:4] != MAGIC:
        raise ValueError("not a JSEC envelope")
    if len(envelope) < 7:  # magic(4) + version(1) + key_id_len(2)
        raise ValueError("truncated JSEC envelope header")
    version = envelope[4]
    if version != VERSION:
        raise ValueError(f"unsupported JSEC envelope version: {version}")
    pos = 5
    kid_len = struct.unpack(">H", envelope[pos : pos + 2])[0]
    pos += 2
    if pos + kid_len > len(envelope):
        raise ValueError("truncated JSEC envelope (key id)")
    try:
        key_id = envelope[pos : pos + kid_len].decode()
    except UnicodeDecodeError as exc:
        raise ValueError("JSEC key id is not valid UTF-8") from exc
    pos += kid_len
    if pos >= len(envelope):
        raise ValueError("truncated JSEC envelope (iv length)")
    iv_len = envelope[pos]
    pos += 1
    if iv_len != 12:
        raise ValueError(f"unsupported JSEC iv length: {iv_len}")
    if pos + iv_len > len(envelope):
        raise ValueError("truncated JSEC envelope (iv)")
    iv = envelope[pos : pos + iv_len]
    pos += iv_len
    if pos >= len(envelope):
        raise ValueError("truncated JSEC envelope (tag length)")
    tag_len = envelope[pos]
    pos += 1
    if tag_len != 16:
        raise ValueError(f"unsupported JSEC tag length: {tag_len}")
    if pos + tag_len > len(envelope):
        raise ValueError("truncated JSEC envelope (tag)")
    tag = envelope[pos : pos + tag_len]
    pos += tag_len
    ct = envelope[pos:]

    ring = _keyring()
    if key_id not in ring:
        raise ValueError(f"unknown key_id: {key_id}")
    key = ring[key_id]
    return AESGCM(key).decrypt(iv, ct + tag, key_id.encode())


def is_envelope(data: bytes) -> bool:
    """Check if data starts with the JSEC magic."""
    return len(data) >= 4 and data[:4] == MAGIC


def hash_agent_key(raw_key: str) -> tuple[str, bytes]:
    """HMAC-SHA256 with the pepper; returns (prefix_8_chars, hash).

    Compatible with janus_api_keys:hash_key/1 in Erlang. The prefix is
    the first 8 characters and is stored in the TEXT column as-is.
    """
    pepper = config.api_key_pepper.encode()
    digest = hmac.new(pepper, raw_key.encode(), hashlib.sha256).digest()
    prefix = raw_key[:8]
    return prefix, digest


def verify_agent_key(raw_key: str, stored_hash: bytes) -> bool:
    """Constant-time verification compatible with janus_api_keys:verify/2."""
    _, computed = hash_agent_key(raw_key)
    return hmac.compare_digest(computed, stored_hash)


def hash_recovery_code(normalized: str) -> str:
    """Keyed SHA-256 (hex) for one-time recovery codes. The codes are
    random 80-bit values, so — unlike passwords — a fast keyed hash is
    the right tool; the pepper keeps offline brute force off the table."""
    pepper = config.api_key_pepper.encode()
    return hmac.new(pepper, normalized.encode(), hashlib.sha256).hexdigest()


def generate_agent_key() -> str:
    """Generate a new agent API key (sk-XXXXXX-random)."""
    rand = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("=")
    return f"sk-{rand[:5]}-{rand}"


# Validate the keyring at import (startup) so a typo'd/truncated entry is
# visible immediately instead of only when the first secret is decrypted.
_parse_keyring(config.secrets_key)
