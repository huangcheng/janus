from typing import Any

from fastapi import Depends, FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from janus_judge.auth import require_judge_token
from janus_judge.config import (
    CONTRACT_VERSION,
    DEFAULT_ARTIFACT,
    fixture_mode,
    golden_file_sha256,
)
from janus_judge.golden import lookup_tier
from janus_judge.state import get_state

app = FastAPI(title="janus-judge", version="0.1.0")


class EnsureRequest(BaseModel):
    artifact: str = DEFAULT_ARTIFACT
    artifact_url: str | None = None
    artifact_sha256: str | None = None
    ensure_generation: int = 0


class DecideRequest(BaseModel):
    system_prefix: str = Field(max_length=256)
    user_prefix: str = Field(max_length=1200)
    out_budget: str = ""
    labels: list[str] = Field(min_length=1)


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    st = get_state()
    return {
        "ready": st.ready,
        "downloading": st.downloading,
        "artifact": st.artifact,
        "artifact_sha256": st.artifact_sha256,
        "contract_version": CONTRACT_VERSION,
        "error": st.error,
    }


@app.post("/admin/ensure")
def admin_ensure(
    body: EnsureRequest,
    _: None = Depends(require_judge_token),
) -> dict[str, Any]:
    st = get_state()
    st.artifact = body.artifact
    st.ensure_generation = body.ensure_generation
    st.error = None

    if fixture_mode():
        sha = golden_file_sha256()
        st.artifact_sha256 = sha
        st.ready = True
        st.downloading = False
        return {"ready": True, "artifact_sha256": sha}

    st.ready = False
    st.downloading = True
    st.artifact_sha256 = body.artifact_sha256
    return JSONResponse(status_code=202, content={"downloading": True})


@app.post("/v1/decide")
def decide(
    body: DecideRequest,
    _: None = Depends(require_judge_token),
) -> dict[str, Any]:
    st = get_state()
    if not st.ready:
        if st.downloading:
            return JSONResponse(status_code=503, content={"downloading": True})
        return JSONResponse(status_code=503, content={"ready": False})

    if fixture_mode():
        entry = lookup_tier(body.system_prefix, body.user_prefix, body.labels)
        if entry is None:
            return JSONResponse(
                status_code=500,
                content={"error": "no golden fixture for request"},
            )
        out: dict[str, Any] = {"tier": entry["tier"]}
        if "scores" in entry:
            out["scores"] = entry["scores"]
        if st.artifact_sha256:
            out["artifact_sha256"] = st.artifact_sha256
        return out

    return JSONResponse(status_code=503, content={"ready": False})


def main() -> None:
    import uvicorn

    from janus_judge.config import DEFAULT_HOST, DEFAULT_PORT

    uvicorn.run(
        "janus_judge.app:app",
        host=DEFAULT_HOST,
        port=DEFAULT_PORT,
        log_level="info",
    )


if __name__ == "__main__":
    main()
