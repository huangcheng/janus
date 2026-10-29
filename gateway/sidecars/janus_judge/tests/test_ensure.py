def test_ensure_fixture_immediate_ready(fixture_client, auth_headers, golden_sha):
    r = fixture_client.post(
        "/admin/ensure",
        json={
            "artifact": "laya-multilingual",
            "artifact_url": None,
            "artifact_sha256": None,
            "ensure_generation": 3,
        },
        headers=auth_headers,
    )
    assert r.status_code == 200
    assert r.json() == {"ready": True, "artifact_sha256": golden_sha}


def test_ensure_non_fixture_downloading(client, auth_headers):
    r = client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 1},
        headers=auth_headers,
    )
    assert r.status_code == 202
    assert r.json() == {"downloading": True}
    hz = client.get("/healthz").json()
    assert hz["downloading"] is True
    assert hz["ready"] is False
