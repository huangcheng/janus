import hashlib
import os
from functools import lru_cache
from pathlib import Path

CONTRACT_VERSION = 1
DEFAULT_ARTIFACT = "laya-multilingual"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8191

_PKG_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_PATH = _PKG_ROOT / "testdata" / "golden.json"


def judge_token() -> str | None:
    raw = os.environ.get("JANUS_JUDGE_TOKEN")
    if raw is None or raw.strip() == "":
        return None
    return raw


def fixture_mode() -> bool:
    return os.environ.get("JANUS_JUDGE_FIXTURE", "").strip() in ("1", "true", "yes")


@lru_cache(maxsize=1)
def golden_file_sha256() -> str:
    data = GOLDEN_PATH.read_bytes()
    return hashlib.sha256(data).hexdigest()
