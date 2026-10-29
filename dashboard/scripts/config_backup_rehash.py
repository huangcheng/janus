#!/usr/bin/env python3
"""Re-canonicalize a config-backup document after operator edits (spec §5.7).

Re-sorts C3 arrays (tier order preserved), re-derives ``crypto…key_ids``,
refuses duplicate provider-key ciphertext within one provider, self-validates
with JSON Schema format assertion ON, and recomputes ``integrity.payload_sha256``
only.

Usage:
  python scripts/config_backup_rehash.py IN.json [-o OUT.json]

When ``-o`` is omitted, ``IN.json`` is overwritten in place.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import tempfile
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from app.config_backup_canon import (
    derive_key_ids,
    payload_sha256,
    sort_document_arrays,
)
from app.config_backup_schema import load_schema


class RehashError(Exception):
    """Refusal before writing output."""


def _b64_bytes(value: object) -> bytes:
    if not isinstance(value, str) or not value:
        raise RehashError("a base64 field is empty")
    pad = "=" * ((4 - len(value) % 4) % 4)
    try:
        return base64.b64decode(value + pad, validate=True)
    except Exception as exc:
        raise RehashError("a base64 field is not decodable") from exc


def _within_provider_duplicate_ciphertext(doc: dict) -> None:
    providers = doc.get("providers")
    if not isinstance(providers, list):
        return
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        name = provider.get("name", "?")
        keys = provider.get("keys")
        if not isinstance(keys, list):
            continue
        seen: set[bytes] = set()
        for key in keys:
            if not isinstance(key, dict):
                continue
            try:
                raw = _b64_bytes(key.get("secret_ciphertext_b64"))
            except RehashError as exc:
                raise RehashError(f"provider {name} key ciphertext is not decodable") from exc
            if raw in seen:
                raise RehashError(f"duplicate provider-key ciphertext within provider {name}")
            seen.add(raw)


def _validate(document: dict, validator) -> None:
    errors = list(validator.iter_errors(document))
    if not errors:
        return
    err = min(errors, key=lambda item: [str(part) for part in item.absolute_path])
    loc = ".".join(str(part) for part in err.absolute_path) or "$"
    raise RehashError(
        f"schema validation failed at {loc} ({err.validator}); {len(errors)} error(s)"
    )


def rehash_document(doc: dict) -> dict:
    """Return a re-sorted, re-hashed copy; raise :class:`RehashError` on refusal."""
    if not isinstance(doc, dict):
        raise RehashError("document must be a JSON object")

    out = sort_document_arrays(doc)
    crypto = out.get("crypto")
    encryption = crypto.get("provider_key_encryption") if isinstance(crypto, dict) else None
    if not isinstance(encryption, dict):
        raise RehashError("crypto.provider_key_encryption is missing or not an object")
    encryption["key_ids"] = derive_key_ids(out)
    _within_provider_duplicate_ciphertext(out)

    validator = load_schema()
    _validate(out, validator)

    integrity = out.get("integrity")
    if integrity is None:
        integrity = {}
    elif not isinstance(integrity, dict):
        raise RehashError("integrity must be an object when present")
    integrity = dict(integrity)
    integrity["payload_sha256"] = payload_sha256(out)
    out["integrity"] = integrity

    _validate(out, validator)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Re-sort and re-hash a janus-config-backup v1 document after edits."
    )
    parser.add_argument("input", type=Path, help="Path to the backup JSON file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output path (default: overwrite input)",
    )
    args = parser.parse_args(argv)

    in_path = args.input
    out_path = args.output if args.output is not None else in_path

    try:
        raw = in_path.read_text(encoding="utf-8")
        doc = json.loads(raw)
        result = rehash_document(doc)
        payload = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        # The default output IS the input (06a L8), so write a sibling temp and
        # rename it into place: a crash or ENOSPC mid-write must not truncate
        # the only edited copy.
        fd, tmp_name = tempfile.mkstemp(
            prefix=out_path.name + ".", suffix=".tmp", dir=str(out_path.parent)
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write(payload)
                out.flush()
                os.fsync(out.fileno())
            try:
                os.chmod(tmp_name, out_path.stat().st_mode & 0o777)
            except OSError:
                pass  # new output file: keep mkstemp's 0600
            os.replace(tmp_name, out_path)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise
    except (OSError, json.JSONDecodeError) as exc:
        print(f"config_backup_rehash: {exc}", file=sys.stderr)
        return 1
    except RehashError as exc:
        print(f"config_backup_rehash: {exc}", file=sys.stderr)
        return 1

    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
