from dataclasses import dataclass

from janus_judge.config import DEFAULT_ARTIFACT


@dataclass
class SidecarState:
    artifact: str = DEFAULT_ARTIFACT
    artifact_sha256: str | None = None
    ready: bool = False
    downloading: bool = False
    error: str | None = None
    ensure_generation: int = 0


_state = SidecarState()


def get_state() -> SidecarState:
    return _state


def reset_state() -> None:
    global _state
    _state = SidecarState()
