#!/usr/bin/env python3
"""Decrypt one provider_keys JSEC envelope (janus_secrets wire format).

Used by restore_leader.sh canary — mirrors apps/janus_core/src/janus_secrets.erl.

Usage:
  secrets_canary.py --env-file STAGED.env --ciphertext-hex HEX
  secrets_canary.py --env-file STAGED.env --ciphertext-b64 B64
  secrets_canary.py --self-test

Exit 0 on successful decrypt; 1 on failure; 2 on usage error.
"""

from __future__ import annotations

import argparse
import base64
import os
import struct
import sys

MAGIC = b"JSEC"
VERSION = 1


def parse_keyring(raw: str) -> dict[str, bytes]:
    ring: dict[str, bytes] = {}
    for index, part in enumerate(raw.split(","), start=1):
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            # Never interpolate the entry: a keyring written as "k1 <key>"
            # (space instead of colon) or as a bare key is KEY MATERIAL, and
            # this message reaches stderr plus the restore/backup logs (06a
            # M2). Identify the entry by position and size only.
            raise ValueError(
                f"bad keyring entry #{index} (need key_id:base64; {len(part)} chars, no ':' separator)"
            )
        kid, b64 = part.split(":", 1)
        key = base64.b64decode(b64.strip())
        if len(key) != 32:
            raise ValueError(f"key {kid!r} must be 32 bytes, got {len(key)}")
        ring[kid.strip()] = key
    if not ring:
        raise ValueError("empty JANUS_SECRETS_KEY")
    return ring


def load_env_file(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def decode_envelope(blob: bytes) -> tuple[str, bytes, bytes, bytes]:
    if len(blob) < 8 or blob[:4] != MAGIC:
        raise ValueError("bad_magic")
    ver = blob[4]
    if ver != VERSION:
        raise ValueError(f"unsupported_version:{ver}")
    key_id_len = struct.unpack(">H", blob[5:7])[0]
    i = 7
    if key_id_len <= 0 or i + key_id_len > len(blob):
        raise ValueError("truncated_envelope")
    key_id = blob[i : i + key_id_len]
    i += key_id_len
    if i >= len(blob):
        raise ValueError("truncated_envelope")
    iv_len = blob[i]
    i += 1
    if iv_len <= 0 or i + iv_len > len(blob):
        raise ValueError("truncated_envelope")
    iv = blob[i : i + iv_len]
    i += iv_len
    if i >= len(blob):
        raise ValueError("truncated_envelope")
    tag_len = blob[i]
    i += 1
    if tag_len <= 0 or i + tag_len > len(blob):
        raise ValueError("truncated_envelope")
    tag = blob[i : i + tag_len]
    i += tag_len
    ct = blob[i:]
    if not key_id or not iv or not tag or not ct:
        raise ValueError("truncated_envelope")
    return key_id.decode("utf-8"), iv, tag, ct


def _aesgcm(key: bytes):
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as e:
        raise SystemExit(
            "secrets_canary.py requires the 'cryptography' package (pip3 install cryptography)"
        ) from e
    return AESGCM(key)


def decrypt(blob: bytes, ring: dict[str, bytes]) -> bytes:
    key_id, iv, tag, ct = decode_envelope(blob)
    if key_id not in ring:
        raise ValueError(f"unknown_key_id:{key_id}")
    # Erlang crypto_one_time_aead returns ciphertext; tag is separate.
    # Python AESGCM expects ciphertext||tag.
    aes = _aesgcm(ring[key_id])
    return aes.decrypt(iv, ct + tag, key_id.encode("utf-8"))


def encrypt_for_selftest(plain: bytes, key_id: str, key: bytes) -> bytes:
    import os as _os

    iv = _os.urandom(12)
    aes = _aesgcm(key)
    packed = aes.encrypt(iv, plain, key_id.encode("utf-8"))
    ct, tag = packed[:-16], packed[-16:]
    kid = key_id.encode("utf-8")
    return (
        MAGIC
        + bytes([VERSION])
        + struct.pack(">H", len(kid))
        + kid
        + bytes([len(iv)])
        + iv
        + bytes([len(tag)])
        + tag
        + ct
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file")
    ap.add_argument(
        "--allow-env-fallback",
        action="store_true",
        help="use the ambient JANUS_SECRETS_KEY when --env-file has none "
        "(default: refuse — a staged .env must carry its own keyring)",
    )
    ap.add_argument("--ciphertext-hex")
    ap.add_argument("--ciphertext-b64")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        key = os.urandom(32)
        kid = "k1"
        env = encrypt_for_selftest(b"canary-plain", kid, key)
        ring = {kid: key}
        if decrypt(env, ring) != b"canary-plain":
            print("self-test FAILED", file=sys.stderr)
            return 1
        print("self-test ok")
        return 0

    if not args.env_file or not (args.ciphertext_hex or args.ciphertext_b64):
        ap.print_help()
        return 2

    env = load_env_file(args.env_file)
    # 06a L7: a staged .env that lost its keyring must FAIL, not be canaried
    # with whatever key the invoking shell happens to export. The ambient
    # fallback is opt-in only (e.g. an operator shell that sourced the live
    # .env on purpose).
    raw_key = env.get("JANUS_SECRETS_KEY")
    if not raw_key and args.allow_env_fallback:
        raw_key = os.environ.get("JANUS_SECRETS_KEY")
    if not raw_key:
        print(
            f"missing JANUS_SECRETS_KEY in {args.env_file} (ambient fallback requires --allow-env-fallback)",
            file=sys.stderr,
        )
        return 1
    ring = parse_keyring(raw_key)
    if args.ciphertext_hex:
        blob = bytes.fromhex(args.ciphertext_hex.strip())
    else:
        blob = base64.b64decode(args.ciphertext_b64.strip())
    plain = decrypt(blob, ring)
    if not plain:
        print("empty plaintext", file=sys.stderr)
        return 1
    print("canary ok", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f"canary failed: {e}", file=sys.stderr)
        raise SystemExit(1)
