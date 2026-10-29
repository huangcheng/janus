import json
from functools import lru_cache
from janus_judge.config import GOLDEN_PATH


@lru_cache(maxsize=1)
def _load_entries() -> list[dict]:
    raw = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
    return list(raw.get("entries", []))


def _labels_key(labels: list[str]) -> tuple[str, ...]:
    return tuple(sorted(labels))


def lookup_tier(
    system_prefix: str, user_prefix: str, labels: list[str]
) -> dict | None:
    want_labels = _labels_key(labels)
    for entry in _load_entries():
        if entry.get("system_prefix") != system_prefix:
            continue
        if entry.get("user_prefix") != user_prefix:
            continue
        if _labels_key(list(entry.get("labels", []))) != want_labels:
            continue
        return entry
    return None
