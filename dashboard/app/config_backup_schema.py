"""Load the v1 config-backup JSON Schema and prove format assertion is on.

Draft 2020-12 treats ``format`` as annotation-only unless a FormatChecker
is installed. jsonschema registers ``date-time`` only when
``rfc3339-validator`` imported successfully. A known-bad fixture that
passes means the process would accept corrupt documents, so startup
refuses to boot (``export_invalid``, spec §5.2 / C11).
"""

import json
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError

_SCHEMA_FILENAME = "config-backup-v1.schema.json"


class SchemaSelfCheckError(RuntimeError):
    """Schema file or format assertion is unusable. Boot must stop."""

    code = "export_invalid"


def schema_path() -> Path:
    """Repo ``docs/schemas/`` file. Resolved from this module, not cwd."""
    return Path(__file__).resolve().parent.parent / "docs" / "schemas" / _SCHEMA_FILENAME


def load_schema() -> Draft202012Validator:
    """Draft 2020-12 validator with format assertion enabled."""
    schema = json.loads(schema_path().read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER)


def startup_schema_self_check() -> None:
    """Raise :class:`SchemaSelfCheckError` when the validator is misconfigured.

    Two known-bad fixtures must fail: a duplicated ``uniqueItems`` array,
    and a ``taken_at`` that is not RFC 3339. The date-time case passes a
    checker-less validator, which is exactly the misconfig this guards.
    """
    try:
        validator = load_schema()
    except (OSError, json.JSONDecodeError, SchemaError) as exc:
        raise SchemaSelfCheckError(
            f"config-backup schema failed to load from {schema_path()}: {exc}"
        ) from exc

    duplicated = {"source": {"schema_migrations": ["001_init", "001_init"]}}
    if not any(err.validator == "uniqueItems" for err in validator.iter_errors(duplicated)):
        raise SchemaSelfCheckError(
            "known-bad uniqueItems fixture passed; schema validator is misconfigured"
        )

    bad_date = {"taken_at": "not-a-date"}
    if not any(err.validator == "format" for err in validator.iter_errors(bad_date)):
        raise SchemaSelfCheckError(
            "known-bad date-time fixture passed; format assertion is off "
            "(install rfc3339-validator and pass Draft202012Validator.FORMAT_CHECKER)"
        )
