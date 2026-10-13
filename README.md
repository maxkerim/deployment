# Blue-Green Deployment

Zero-downtime deployments for a small containerized web app (Flask + Redis), using Docker Compose and Nginx. Built as a solution to the [roadmap.sh Blue/Green Deployment project](https://roadmap.sh/projects/blue-green-deployment), including both bonus tasks (CI/CD pipeline and monitoring).

## How it works

```
                      ┌──────────────┐
   users ───────────▶ │    nginx     │
                      │ (upstream.   │
                      │  conf = live │
                      │  color)      │
                      └──────┬───────┘
                 live        │        idle / next release
              ┌──────────────┴──────────────┐
              ▼                             ▼
        ┌───────────┐                 ┌───────────┐
        │ app-blue  │                 │ app-green │
        └─────┬─────┘                 └─────┬─────┘
              └──────────────┬──────────────┘
                             ▼
                      ┌─────────────┐
                      │ redis       │  (named volume: data survives every switch)
                      └─────────────┘
```

`./deploy.sh deploy` does this:

1. Finds the live color (recorded in `nginx/upstream/upstream.conf`) and picks the other one as the target.
2. Builds and starts the target container with the new version. Live traffic is untouched.
3. Waits until the target's Docker healthcheck (`/health`, which also pings Redis) passes. If it never does, the deploy is aborted and nothing changes for users.
4. Rewrites `upstream.conf` atomically, validates the config (`nginx -t`) and does a graceful `nginx -s reload`: in-flight requests finish on the old color, new ones go to the new color.
5. Verifies through Nginx that the new color is really answering. If not, it reverts automatically.
6. Leaves the old color running so `./deploy.sh rollback` is instant.

The database (Redis) is shared by both colors and lives in a named volume, so there is no data loss when switching.

## Quick start

Requirements: Docker with the Compose plugin, `curl`, `git`.

```bash
./deploy.sh deploy v1      # first deploy -> blue
curl localhost:8080/       # {"color":"blue","hits":1,"version":"v1",...}

./deploy.sh deploy v2      # builds green, switches when healthy
curl localhost:8080/       # {"color":"green","hits":2,"version":"v2",...}  (counter kept)

./deploy.sh rollback       # back to blue instantly
./deploy.sh status         # active color + container states
./deploy.sh stop-idle      # free resources used by the non-live color
```

Without an argument, `deploy` uses the current git short SHA as the version. The response header `X-Active-Color` also tells you which color served a request.

> Always use `deploy.sh`, not a bare `docker compose up`: Nginx needs the `upstream.conf` it generates.

## Zero-downtime test

`scripts/e2e.sh` runs the whole flow in an isolated Compose project (own port, own volumes) and asserts that:

- the first deploy lands on blue and the second on green;
- **no request fails** while a continuous stream of traffic runs through the switch;
- the Redis hit counter survives the switch (no data loss);
- rollback works;
- a deliberately broken release is rejected and live traffic is unaffected.

```bash
./scripts/e2e.sh
```

## CI/CD (GitHub Actions)

`.github/workflows/ci-cd.yml`:

| Job | Runs on | What it does |
|---|---|---|
| `test` | every push / PR | unit tests (`pytest`) |
| `e2e` | after `test` | `scripts/e2e.sh` blue-green switch test |
| `deploy` | push to `main` only, after the above | SSH into the server, check out the pushed commit, run `./deploy.sh deploy <sha>` |

Server setup: install Docker, clone this repo to a directory, and add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `SSH_HOST` | server address |
| `SSH_USER` | deploy user (must be able to run `docker`) |
| `SSH_KEY` | private key whose public half is in the user's `authorized_keys` |
| `SSH_KNOWN_HOSTS` | output of `ssh-keyscan <host>`, so the host key is pinned |
| `DEPLOY_PATH` | absolute path of the clone on the server |

## Monitoring

Optional stack: Prometheus, Grafana and an Nginx exporter.

```bash
docker compose --profile monitoring up -d prometheus grafana nginx-exporter
```

- Prometheus: http://localhost:9090 (scrapes both colors, Nginx, and itself; alert rules in `monitoring/prometheus/alerts.yml`)
- Grafana: http://localhost:3000 (login `admin` / `$GRAFANA_PASSWORD`, default `admin`), with a pre-provisioned "Blue-Green Deployment" dashboard: instances up, requests per second by color/version, uptime (resets show deploys), Nginx traffic.

Both ports are bound to `127.0.0.1` on purpose; on a remote server use an SSH tunnel (`ssh -L 3000:localhost:3000 user@host`) or put them behind authentication before exposing them.

## Project layout

```
app/                  Flask app, Dockerfile, tests (/, /health, /metrics)
nginx/nginx.conf      reverse proxy; includes the generated upstream.conf
deploy.sh             deploy | rollback | status | stop-idle
scripts/e2e.sh        zero-downtime / rollback / failed-release test
docker-compose.yml    redis, app-blue, app-green, nginx (+ monitoring profile)
monitoring/           Prometheus rules and Grafana provisioning + dashboard
.github/workflows/    CI/CD pipeline
```

## Caveats worth knowing

- **Database migrations** must be backward compatible: for a while the old and new version run against the same data, and rollback must keep working. Use expand/contract migrations (add first, remove in a later release).
- This is a single-host setup: the server itself is still a single point of failure. Blue-green removes deployment downtime, not hardware failures.
- Both colors run briefly side by side, so the host needs enough memory for two app instances.
