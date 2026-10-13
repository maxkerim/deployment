import redis

import app as app_module


class FakeRedis:
    def __init__(self):
        self.counter = 0
        self.up = True

    def incr(self, key):
        self.counter += 1
        return self.counter

    def ping(self):
        if not self.up:
            raise redis.ConnectionError("down")
        return True


def make_client(monkeypatch, fake):
    monkeypatch.setattr(app_module, "db", fake)
    return app_module.app.test_client()


def test_index_counts_hits(monkeypatch):
    client = make_client(monkeypatch, FakeRedis())
    assert client.get("/").get_json()["hits"] == 1
    assert client.get("/").get_json()["hits"] == 2


def test_health_ok(monkeypatch):
    client = make_client(monkeypatch, FakeRedis())
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_health_unhealthy_when_redis_down(monkeypatch):
    fake = FakeRedis()
    fake.up = False
    client = make_client(monkeypatch, fake)
    assert client.get("/health").status_code == 503


def test_metrics_format(monkeypatch):
    client = make_client(monkeypatch, FakeRedis())
    client.get("/health")
    body = client.get("/metrics").get_data(as_text=True)
    assert "app_requests_total" in body
    assert "app_uptime_seconds" in body
