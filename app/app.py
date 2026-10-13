import os
import time

import redis
from flask import Flask, Response, jsonify

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "dev")
COLOR = os.environ.get("APP_COLOR", "unknown")
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

db = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_connect_timeout=2, socket_timeout=2)

START_TIME = time.time()
request_count = 0


@app.before_request
def count_request():
    global request_count
    request_count += 1


@app.route("/")
def index():
    hits = db.incr("hits")
    return jsonify(
        message="Hello from the blue-green demo",
        color=COLOR,
        version=VERSION,
        hits=hits,
    )


@app.route("/health")
def health():
    """Healthcheck used by deploy.sh and Docker before traffic is switched."""
    try:
        db.ping()
    except redis.RedisError:
        return jsonify(status="unhealthy", reason="redis unavailable"), 503
    return jsonify(status="ok", color=COLOR, version=VERSION)


@app.route("/metrics")
def metrics():
    """Minimal Prometheus text format, no extra dependencies."""
    uptime = time.time() - START_TIME
    lines = [
        "# HELP app_requests_total Total HTTP requests handled by this instance.",
        "# TYPE app_requests_total counter",
        f'app_requests_total{{color="{COLOR}",version="{VERSION}"}} {request_count}',
        "# HELP app_uptime_seconds Seconds since this instance started.",
        "# TYPE app_uptime_seconds gauge",
        f'app_uptime_seconds{{color="{COLOR}",version="{VERSION}"}} {uptime:.0f}',
    ]
    return Response("\n".join(lines) + "\n", mimetype="text/plain")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
