from fastapi.testclient import TestClient
from proxy import app


def test_proxy_health():
    client = TestClient(app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy"}
