import secrets

from fastapi import Header, HTTPException

from janus_judge.config import judge_token

TOKEN_HEADER = "x-janus-judge-token"


def require_judge_token(
    x_janus_judge_token: str | None = Header(default=None, alias=TOKEN_HEADER),
) -> None:
    expected = judge_token()
    if expected is None:
        raise HTTPException(status_code=401, detail="token not configured")
    if x_janus_judge_token is None:
        raise HTTPException(status_code=401, detail="unauthorized")
    try:
        # Compare as UTF-8 bytes: Starlette headers are latin-1 strs; non-ASCII
        # or mixed types make compare_digest raise TypeError → treat as 401.
        ok = secrets.compare_digest(
            x_janus_judge_token.encode("utf-8"),
            expected.encode("utf-8"),
        )
    except (TypeError, UnicodeEncodeError):
        ok = False
    if not ok:
        raise HTTPException(status_code=401, detail="unauthorized")
