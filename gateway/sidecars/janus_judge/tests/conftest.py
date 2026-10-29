import pytest
from fastapi.testclient import TestClient

from janus_judge.config import golden_file_sha256
from janus_judge.state import reset_state


@pytest.fixture(autouse=True)
def _clean_state():
    reset_state()
    yield
    reset_state()


@pytest.fixture
def token_env(monkeypatch):
    monkeypatch.setenv("JANUS_JUDGE_TOKEN", "test-secret-token")
    monkeypatch.delenv("JANUS_JUDGE_FIXTURE", raising=False)


@pytest.fixture
def fixture_env(token_env, monkeypatch):
    monkeypatch.setenv("JANUS_JUDGE_FIXTURE", "1")


@pytest.fixture
def client(token_env):
    from janus_judge.app import app

    return TestClient(app)


@pytest.fixture
def fixture_client(fixture_env):
    from janus_judge.app import app

    return TestClient(app)


@pytest.fixture
def auth_headers():
    return {"x-janus-judge-token": "test-secret-token"}


@pytest.fixture
def golden_sha():
    return golden_file_sha256()
