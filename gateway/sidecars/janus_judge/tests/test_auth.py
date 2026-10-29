from fastapi.testclient import TestClient

from janus_judge.state import reset_state


def test_ensure_rejects_when_token_unset(monkeypatch):
    monkeypatch.delenv("JANUS_JUDGE_TOKEN", raising=False)
    reset_state()
    from janus_judge.app import app

    with TestClient(app) as c:
        r = c.post(
            "/admin/ensure",
            json={"artifact": "laya-multilingual", "ensure_generation": 0},
            headers={"x-janus-judge-token": "anything"},
        )
        assert r.status_code == 401


def test_decide_rejects_when_token_unset(monkeypatch):
    monkeypatch.delenv("JANUS_JUDGE_TOKEN", raising=False)
    reset_state()
    from janus_judge.app import app

    with TestClient(app) as c:
        r = c.post(
            "/v1/decide",
            json={
                "system_prefix": "s",
                "user_prefix": "u",
                "labels": ["fast"],
            },
            headers={"x-janus-judge-token": "anything"},
        )
        assert r.status_code == 401


def test_ensure_wrong_token(client, auth_headers):
    bad = {**auth_headers, "x-janus-judge-token": "wrong"}
    r = client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 0},
        headers=bad,
    )
    assert r.status_code == 401


def test_ensure_missing_header(client):
    r = client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 0},
    )
    assert r.status_code == 401
