# painscaler deploy

Self-hosted stack: Caddy (TLS, forward-auth) + Authelia (login/MFA) + painscaler-api (Go) + painscaler-web (nginx static).

## Quickstart

```bash
cd deploy
make init           # generate .env, secrets, render configs
$EDITOR .env        # fill ZPA_CLIENT_ID, ZPA_CLIENT_SECRET, ZPA_CUSTOMER_ID, ZPA_VANITY, ZPA_IDP
make build
make up
make show-admin     # print generated admin password
make ca             # extract Caddy root CA -> ./painscaler-ca.crt
```

Add to `/etc/hosts` on every client machine:
```
<docker-host-ip>  painscaler.lan auth.lan
```

Trust `painscaler-ca.crt` in your browser/OS, then visit `https://painscaler.lan`.

## First MFA setup

Authelia file-notifier writes TOTP enrolment links + codes to `authelia/notifications.txt`:

```bash
make mfa            # tail it live
```

Open the link from a fresh tab to register your authenticator.

## Common targets

| target          | purpose                                       |
|-----------------|-----------------------------------------------|
| `make help`     | list everything                               |
| `make init`     | env + secrets + rendered configs              |
| `make up`       | start stack                                   |
| `make down`     | stop (keep volumes)                           |
| `make logs`     | tail all logs                                 |
| `make ca`       | extract root CA cert                          |
| `make rotate`   | regenerate all secrets (invalidates sessions) |
| `make hash PASSWORD=xxx` | hash a custom password (argon2id)    |
| `make nuke`     | wipe volumes (DESTRUCTIVE)                    |

## Files

- `secrets/` — generated random secrets (gitignored, mode 600)
- `authelia/configuration.yml` — rendered from `.tmpl` (gitignored)
- `authelia/users_database.yml` — rendered (gitignored)
- `.env` — ZPA credentials (gitignored)

## Identity / audit

Caddy `forward_auth` copies `Remote-User`, `Remote-Email`, `Remote-Groups`, `Remote-Name` from Authelia into upstream requests. nginx forwards them unchanged. Backend reads them per-request:

- `POST /api/v1/simulation/run` — persists `created_by` = `Remote-User`
- `GET /api/v1/me` — returns the current identity (handy for frontend display)

The backend trusts these headers only when the request peer is in `TRUSTED_PROXIES` (set in `docker-compose.yml`, default `172.16.0.0/12,10.0.0.0/8` — covers Docker bridge networks). Untrusted peers get the headers stripped before handlers see them. Direct calls to `painscaler-api:8080` from outside the compose network are blocked at the Docker level (`expose:` not `ports:`).

If you change the docker network range or run behind a different proxy, set `TRUSTED_PROXIES` accordingly (comma-separated IPs or CIDRs).

## Observability

Backend writes structured JSON logs + exposes Prometheus metrics.

### Logs

Rotated JSONL on the `painscaler_data` volume (`/data/logs/painscaler.log`). Errors also mirror to stderr (`docker logs painscaler-api`).

```bash
make logs                                            # all containers, mixed
docker compose exec painscaler-api wget -qO- \
  http://localhost:8080/metrics | head              # quick metrics peek
docker compose exec -T painscaler-api \
  sh -c 'tail -n 200 /data/logs/painscaler.log'    # raw tail (no jq in distroless)
```

For pretty filtering, copy out and pipe through `jq` on the host:

```bash
docker compose cp painscaler-api:/data/logs/painscaler.log - | \
  jq -c 'select(.level=="ERROR")'                  # errors only
docker compose cp painscaler-api:/data/logs/painscaler.log - | \
  jq -r 'select(.msg=="http request") | [.route,.status,.duration_ms] | @tsv' | \
  sort | uniq -c | sort -rn | head                 # hot routes
docker compose cp painscaler-api:/data/logs/painscaler.log - | \
  jq -c 'select(.source=="frontend" and .type=="error")'  # browser errors
```

Tunable env vars on `painscaler-api`:

| var                | default        | meaning                        |
|--------------------|----------------|--------------------------------|
| `LOG_DIR`          | `/data/logs`   | log directory                  |
| `LOG_LEVEL`        | `info`         | `debug` / `info` / `warn` / `error` |
| `LOG_MAX_SIZE_MB`  | `50`           | rotate when current file exceeds this |
| `LOG_MAX_BACKUPS`  | `10`           | keep this many rotated files   |
| `LOG_MAX_AGE_DAYS` | `30`           | delete rotated files older than this |
| `LOG_COMPRESS`     | `true`         | gzip rotated files             |

### Metrics

`painscaler-api:8080/metrics` (in-network only, not behind Caddy):

- `painscaler_http_requests_total{route,method,status}` — counter
- `painscaler_http_request_duration_seconds{route,method}` — histogram
- `painscaler_frontend_events_total{type}` — counter (page views + browser errors)
- `painscaler_build_info{version,commit,date}` — gauge=1

Routes are templated (e.g. `/api/v1/segment/:segmentID/policies`) so path-param cardinality stays bounded.

To scrape, add a `prometheus` service to compose:

```yaml
prometheus:
  image: prom/prometheus
  expose: ["9090"]
  volumes: [./prometheus.yml:/etc/prometheus/prometheus.yml:ro]
  networks: [painscaler]
```

with `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: painscaler
    static_configs:
      - targets: ["painscaler-api:8080"]
```

### Frontend telemetry

Browser posts batched `page_view` + `error` events to `POST /api/v1/telemetry`. Buffered in memory, flushed every 30 s, on tab hide (`sendBeacon`), and on `pagehide`. Server emits one log line per event with `source=frontend` and bumps `painscaler_frontend_events_total`. No payloads or PII — only route / error message / stack.

## Domain note

Default uses `painscaler.lan` / `auth.lan`. Change in `Caddyfile` and `authelia/configuration.yml.tmpl` (`session.cookies[0].domain` + `authelia_url` + `default_redirection_url`) if you want a different suffix.

`.local` triggers mDNS resolution on macOS/Linux — avoid. `.lan` and `.home.arpa` are safe.
