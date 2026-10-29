from janus_judge.config import CONTRACT_VERSION, DEFAULT_ARTIFACT


def test_healthz_initial(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body == {
        "ready": False,
        "downloading": False,
        "artifact": DEFAULT_ARTIFACT,
        "artifact_sha256": None,
        "contract_version": CONTRACT_VERSION,
        "error": None,
    }


def test_healthz_after_fixture_ensure(fixture_client, auth_headers, golden_sha):
    fixture_client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 1},
        headers=auth_headers,
    )
    r = fixture_client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["ready"] is True
    assert body["downloading"] is False
    assert body["artifact_sha256"] == golden_sha
    assert body["contract_version"] == 1
