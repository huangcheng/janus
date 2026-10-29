def _ensure_ready(client, headers):
    client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 1},
        headers=headers,
    )


def test_decide_not_ready_503(client, auth_headers):
    r = client.post(
        "/v1/decide",
        json={
            "system_prefix": "You route requests to model tiers.",
            "user_prefix": "User asks for code completion.",
            "out_budget": "Output budget: <=2k tokens",
            "labels": ["fast", "big"],
        },
        headers=auth_headers,
    )
    assert r.status_code == 503
    assert r.json() == {"ready": False}


def test_decide_downloading_503(client, auth_headers):
    client.post(
        "/admin/ensure",
        json={"artifact": "laya-multilingual", "ensure_generation": 1},
        headers=auth_headers,
    )
    r = client.post(
        "/v1/decide",
        json={
            "system_prefix": "x",
            "user_prefix": "y",
            "labels": ["fast"],
        },
        headers=auth_headers,
    )
    assert r.status_code == 503
    assert r.json() == {"downloading": True}


def test_decide_fixture_golden(fixture_client, auth_headers, golden_sha):
    _ensure_ready(fixture_client, auth_headers)
    r = fixture_client.post(
        "/v1/decide",
        json={
            "system_prefix": "You route requests to model tiers.",
            "user_prefix": "User asks for code completion.",
            "out_budget": "Output budget: <=2k tokens",
            "labels": ["big", "fast"],
        },
        headers=auth_headers,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["tier"] == "fast"
    assert body["scores"] == {"fast": 0.71, "big": 0.29}
    assert body["artifact_sha256"] == golden_sha


def test_decide_fixture_second_entry(fixture_client, auth_headers):
    _ensure_ready(fixture_client, auth_headers)
    r = fixture_client.post(
        "/v1/decide",
        json={
            "system_prefix": "You route requests to model tiers.",
            "user_prefix": "User asks for long document analysis.",
            "labels": ["flagship", "fast", "big"],
        },
        headers=auth_headers,
    )
    assert r.status_code == 200
    assert r.json()["tier"] == "big"
