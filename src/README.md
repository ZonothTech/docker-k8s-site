# Pinboard — the course sample application

A tiny three-tier app used in every lab of the Containers & Kubernetes course.

```
browser ──► pinboard-web (nginx :8080) ──/api/*──► pinboard-api (Go :8080) ──► postgres (:5432)
```

| Component | Folder | Image | Notes |
|---|---|---|---|
| API | `pinboard-api/` | `pinboard-api:<ver>` — multi-stage, distroless, ~10 MB, non-root | In-memory store when `DATABASE_URL` is empty |
| Web | `pinboard-web/` | `pinboard-web:<ver>` — nginx 1.28-alpine, non-root, :8080 | `API_URL` env → proxied under `/api/` |
| DB | `db/` | `postgres:17-alpine` | `init.sql` optional bootstrap |

## API reference

| Method & path | Purpose |
|---|---|
| `GET /` | Text banner: version, hostname, store |
| `GET /healthz` | Liveness — 200 once the process is up |
| `GET /readyz` | Readiness — 200 when the store answers, else 503 |
| `GET /api/info` | JSON: version, hostname, store, theme, greeting, uptime |
| `GET /api/notes` · `POST /api/notes {"text","author"}` · `DELETE /api/notes/{id}` | Notes CRUD |
| `GET /api/burn?ms=200` | Burn CPU for `ms` ms (autoscaling lab) |

### Environment variables (API)

| Variable | Default | Used in |
|---|---|---|
| `PORT` | `8080` | — |
| `DATABASE_URL` | *(empty → memory)* | Lab 03, 04, 08+ |
| `APP_VERSION` | build arg / `dev` | Rollouts |
| `APP_THEME` | `emerald` (`amber`, `rose`, `sky`) | Rolling-update visibility |
| `APP_GREETING` | `Welcome to Pinboard` | ConfigMap lab |
| `LOG_FORMAT` | `text` (`json`) | Observability |
| `SHUTDOWN_GRACE` | `10s` | Graceful shutdown demo |
| `FAIL_READY_AFTER` | *(off)* seconds | Readiness demo |
| `CRASH_ON_START` | `false` | Rollback demo |

## Build

```bash
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 ./pinboard-api
docker build -t pinboard-api:1.1 --build-arg APP_VERSION=1.1 ./pinboard-api
docker build -t pinboard-web:1.0 ./pinboard-web
docker compose up -d --wait && open http://localhost:8080
```
