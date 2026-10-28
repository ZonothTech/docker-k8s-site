# Lab 04 – Pinboard in one file

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare the lab folder](#step-01-prepare-the-lab-folder)
  - [Step 02: The first service — the database](#step-02-the-first-service--the-database)
  - [Step 03: Add the API and wait for the database](#step-03-add-the-api-and-wait-for-the-database)
  - [Step 04: Add the web front end](#step-04-add-the-web-front-end)
  - [Step 05: Move the credentials into `.env`](#step-05-move-the-credentials-into-env)
  - [Step 06: Day-two commands: ps, logs, exec](#step-06-day-two-commands-ps-logs-exec)
  - [Step 07: Scale the API and watch the round-robin](#step-07-scale-the-api-and-watch-the-round-robin)
  - [Step 08: The developer loop with `docker compose watch`](#step-08-the-developer-loop-with-docker-compose-watch)
  - [Step 09: A `tools` profile for one-off containers](#step-09-a-tools-profile-for-one-off-containers)
  - [Step 10: Tear it down — `down` vs `down -v`](#step-10-tear-it-down--down-vs-down--v)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Describe the whole Pinboard stack (db + api + web) in a single `compose.yaml`
- Use `healthcheck` + `depends_on: condition: service_healthy` so services start in the right order
- Keep credentials out of the compose file with `.env` and variable interpolation
- Scale a service and observe client-side load balancing
- Edit the web page and see it live with `docker compose watch`, then clean up with `down` vs `down -v`

## Pre-requisites

- Have finished [Lab 03](lab03.md)
- Docker Engine 28+ with the Compose plugin, v2 or later (`docker compose version`), from [Lab 00 – Course setup](lab00-setup.md)
- The course repo cloned at `~/docker-kubernetes-training`

> **Continuity.** In Lab 03 you wired Pinboard together by hand: `docker network create`,
> `docker volume create`, three `docker run` commands with the right flags in the right
> order. It worked — and it was six commands you had to remember and repeat. This lab
> replaces all of them with one file you can commit. The images you built in Lab 02
> (`pinboard-api:1.0`, `pinboard-api:1.1`, `pinboard-web:1.0`) are reused as-is, and the
> Docker network and volume from Lab 03 stay where they are; Compose creates its own.

## Guide

### Step 01: Prepare the lab folder

All the work of this lab happens in `~/pinboard-labs/lab04/`.

```bash
mkdir -p ~/pinboard-labs/lab04
cd ~/pinboard-labs/lab04
```

Compose mounts files from the project folder, so copy the two pieces of the sample app
you need: the database bootstrap SQL, and the whole `pinboard-web` folder (you will
build and live-edit it in Step 08).

```bash
cp -r ~/docker-kubernetes-training/src/db ./db
cp -r ~/docker-kubernetes-training/src/pinboard-web ./pinboard-web
ls -R . | head -20
```

Check that the images from Lab 02 are still there and that nothing is running:

```bash
docker image ls 'pinboard-*'
docker ps
```

```text
REPOSITORY     TAG          IMAGE ID       CREATED        SIZE
pinboard-api   1.0          0f7a2b3c4d5e   2 hours ago    12.8MB
pinboard-api   1.1          5e6f7a8b9c0d   2 hours ago    12.8MB
pinboard-api   1.2-broken   7a8b9c0d1e2f   2 hours ago    12.8MB
pinboard-web   1.0          2b3c4d5e6f70   2 hours ago    58.4MB
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

> **Note.** If `pinboard-api:1.0` is missing, rebuild it:
> `docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 ~/docker-kubernetes-training/src/pinboard-api`

### Step 02: The first service — the database

Build the file one service at a time so you can see each piece work. Create
`compose.yaml`:

```yaml
name: pinboard

services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: pinboard
      POSTGRES_PASSWORD: pinboard-secret
      POSTGRES_DB: pinboard
    volumes:
      - pinboard-data:/var/lib/postgresql/data
      - ./db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 10
    restart: unless-stopped

volumes:
  pinboard-data:
```

Three things deserve a second look:

- There is **no `version:` key**. It was a Compose v1 artefact; the Compose Specification
  dropped it and Compose v2 warns if you keep it.
- `name: pinboard` pins the *project name* (otherwise the folder name, `lab04`, is used).
  Every container, network and volume is prefixed with it.
- `$${POSTGRES_USER}` has a **doubled dollar**. A single `$` would be interpolated by
  Compose itself (and would be empty); doubling it passes a literal `$POSTGRES_USER`
  into the container, where the shell running `pg_isready` expands it.

Start it:

```bash
docker compose up -d --wait
```

```text
[+] Running 3/3
 ✔ Network pinboard_default   Created                                      0.1s
 ✔ Volume "pinboard_pinboard-data"  Created                                0.0s
 ✔ Container pinboard-db-1    Healthy                                     11.4s
```

`--wait` does not return until every service is *healthy* (for services with a
healthcheck) or *running* (for the others). Without it, `up -d` returns as soon as the
containers are created — which is why so many CI scripts have a `sleep 10` in them.

Look at the healthcheck through `docker compose ps`:

```bash
docker compose ps
```

```text
NAME              IMAGE                COMMAND                  SERVICE   CREATED          STATUS                    PORTS
pinboard-db-1     postgres:17-alpine   "docker-entrypoint.s…"   db        22 seconds ago   Up 21 seconds (healthy)   5432/tcp
```

> **Note.** The volume is called `pinboard_pinboard-data`, not `pinboard-data`: Compose
> prefixes volumes and networks with the project name. Your hand-made Lab 03 volume
> `pinboard-data` is a different, untouched volume — check with `docker volume ls`.

### Step 03: Add the API and wait for the database

Add the `api` service to `compose.yaml`, between `db` and the `volumes:` block:

```yaml
  api:
    image: pinboard-api:1.0
    environment:
      DATABASE_URL: postgres://pinboard:pinboard-secret@db:5432/pinboard
      APP_THEME: emerald
      APP_GREETING: Welcome to Pinboard (Compose)
    depends_on:
      db:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 128M
    restart: unless-stopped
```

Notes on what you just wrote:

- **`image:` and no `build:`.** The image already exists locally from Lab 02, so Compose
  will use it. (A service can have both — `build:` says how to make the image, `image:`
  says how to tag it.)
- The API connects to the database at the host name **`db`** — the service name. Compose
  puts every service on the project network `pinboard_default`, where Docker's embedded
  DNS resolves service names. Exactly what you did by hand with `--network pinboard-net`
  in Lab 03.
- `depends_on … condition: service_healthy` is the part plain `docker run` cannot do:
  the API container is not even created until Postgres answers `pg_isready`. Plain
  `depends_on: [db]` would only wait for the container to *start*, which is not the same
  thing at all.
- `deploy.resources.limits.memory` is the Compose equivalent of `--memory 128m`.

```bash
docker compose up -d --wait
docker compose ps
```

```text
[+] Running 2/2
 ✔ Container pinboard-db-1   Healthy                                       0.5s
 ✔ Container pinboard-api-1  Started                                       0.9s
NAME              IMAGE                COMMAND                  SERVICE   CREATED          STATUS                    PORTS
pinboard-api-1    pinboard-api:1.0     "/pinboard-api"          api       6 seconds ago    Up 5 seconds              8080/tcp
pinboard-db-1     postgres:17-alpine   "docker-entrypoint.s…"   db        3 minutes ago    Up 3 minutes (healthy)    5432/tcp
```

The API has no `(healthy)` marker: its image is distroless, with no shell and no `curl`,
so it carries no `HEALTHCHECK`. The web container in the next step does have one.

### Step 04: Add the web front end

Add the last service, again before `volumes:`:

```yaml
  web:
    image: pinboard-web:1.0
    environment:
      API_URL: http://api:8080
    ports:
      - "8080:8080"
    depends_on:
      - api
    restart: unless-stopped
```

Only `web` publishes a port. `db` and `api` are reachable *inside* the project network on
5432 and 8080 but are not exposed on your laptop — the smallest possible attack surface,
and the same shape you will build in Kubernetes with Services and one Ingress.

```bash
docker compose up -d --wait
curl -s localhost:8080/api/info
```

```text
{"app":"pinboard-api","greeting":"Welcome to Pinboard (Compose)","hostname":"a4f83c9e1b27","store":"postgres","theme":"emerald","uptime":"12s","version":"1.0"}
```

`"store":"postgres"` proves the API found the database. Open <http://localhost:8080> in
the browser and pin a note; then check that it really landed in Postgres:

```bash
curl -s localhost:8080/api/notes
```

```text
[{"id":2,"text":"Compose is one file","author":"you","createdAt":"2026-05-04T09:15:02Z"},
 {"id":1,"text":"Hello from init.sql 👋","author":"postgres","createdAt":"2026-05-04T09:12:44Z"}]
```

The API returns the newest note first, so the one at the *bottom* (`id: 1`) is the one
that came from `db/init.sql`, mounted into `/docker-entrypoint-initdb.d/` — Postgres runs
everything in that folder the first time it initialises an empty data directory.

<details>
<summary><b>Check yourself:</b> you delete the note, then run <code>docker compose down</code> and <code>up -d</code> again. Does the <code>init.sql</code> note come back?</summary>

No. `/docker-entrypoint-initdb.d/` scripts run **only when the data directory is empty**.
`down` removes the containers but keeps the volume `pinboard_pinboard-data`, so Postgres
starts on an existing database and skips initialisation entirely. Only `down -v` (Step 10)
wipes the volume and makes `init.sql` run again.
</details>

### Step 05: Move the credentials into `.env`

Hard-coded passwords in a file you commit is exactly what you do not want. Compose
interpolates `${VAR}` from the environment and from a `.env` file in the project folder.

Create `.env`:

```text
# Lab 04 — values interpolated into compose.yaml (${VAR}).
# `.env` is read by the Compose CLI itself; it is NOT passed to the containers
# unless a service references the variable. Never commit real credentials.
POSTGRES_USER=pinboard
POSTGRES_PASSWORD=pinboard-secret
POSTGRES_DB=pinboard
APP_THEME=emerald
APP_GREETING=Welcome to Pinboard (Compose)
```

Now replace the literals in `compose.yaml` with interpolations. The `${VAR:-default}`
form keeps the file working even when `.env` is missing:

```yaml
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-pinboard}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-pinboard-secret}
      POSTGRES_DB: ${POSTGRES_DB:-pinboard}
```

and, in the `api` service:

```yaml
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER:-pinboard}:${POSTGRES_PASSWORD:-pinboard-secret}@db:5432/${POSTGRES_DB:-pinboard}
      APP_THEME: ${APP_THEME:-emerald}
      APP_GREETING: ${APP_GREETING:-Welcome to Pinboard (Compose)}
```

Ask Compose what it actually understood — this is the single most useful debugging
command in Compose:

```bash
docker compose config
```

```text
name: pinboard
services:
  api:
    depends_on:
      db:
        condition: service_healthy
        required: true
    environment:
      APP_GREETING: Welcome to Pinboard (Compose)
      APP_THEME: emerald
      DATABASE_URL: postgres://pinboard:pinboard-secret@db:5432/pinboard
    image: pinboard-api:1.0
...
```

`config` renders the *merged, interpolated* model: every override file applied, every
variable substituted, every default filled in. If something in Compose surprises you,
run this first.

> **Warning.** `.env` is read by the Compose CLI, not injected into containers. A variable
> lands in a container only if a service mentions it (`environment:`) or you use
> `env_file:`. And `.env` belongs in `.gitignore` — commit a `.env.example` instead, like
> `src/.env.example` in the course repo.

Recreate the stack so the new values take effect:

```bash
docker compose up -d --wait
```

### Step 06: Day-two commands: ps, logs, exec

Compose gives you the familiar Docker verbs, scoped to the project — no container IDs to
copy around.

```bash
docker compose logs -f api
```

```text
api-1  | time=2026-05-04T09:15:57.113Z level=INFO msg="pinboard-api starting" version=1.0 theme=emerald store=postgres addr=:8080 hostname=a4f83c9e1b27
api-1  | time=2026-05-04T09:16:02.884Z level=INFO msg=request method=GET path=/api/info status=200 duration=412.6µs
```

Press `Ctrl-C` to stop following (the container keeps running). `docker compose logs`
without `-f` prints everything; without a service name it interleaves all services with a
colour per service.

Open a `psql` shell inside the database container:

```bash
docker compose exec db psql -U pinboard -d pinboard -c 'SELECT id, author, text FROM notes;'
```

```text
 id | author   | text
----+----------+-----------------------
  1 | postgres | Hello from init.sql 👋
  2 | you      | Compose is one file
(2 rows)
```

Drop the `-c '…'` for an interactive session (`\dt`, `\q` to leave).

```bash
docker compose top api
```

```text
pinboard-api-1
UID    PID     PPID    C    STIME   TTY   TIME       CMD
65532  184213  184190  0    09:15   ?     00:00:00   /pinboard-api
```

One process, PID 1 in its own namespace, running as UID 65532 — the `nonroot` user baked
into the distroless image.

### Step 07: Scale the API and watch the round-robin

The `api` service publishes no ports and has no fixed container name, which is precisely
what makes it scalable:

```bash
docker compose up -d --wait --scale api=3
docker compose ps api
```

```text
NAME              IMAGE              COMMAND           SERVICE   CREATED          STATUS          PORTS
pinboard-api-1    pinboard-api:1.0   "/pinboard-api"   api       4 minutes ago    Up 4 minutes    8080/tcp
pinboard-api-2    pinboard-api:1.0   "/pinboard-api"   api       6 seconds ago    Up 5 seconds    8080/tcp
pinboard-api-3    pinboard-api:1.0   "/pinboard-api"   api       6 seconds ago    Up 5 seconds    8080/tcp
```

The name `api` now resolves to three IP addresses. nginx in the web container re-resolves
it (`resolver … valid=10s`) and follows Docker's DNS, so requests are spread over the
three containers. The `hostname` field of `/api/info` is the container ID, so you can see
which one answered. Wait ten seconds first (see the note below), then count who answered
30 requests:

```bash
sleep 10
for i in $(seq 1 30); do curl -s localhost:8080/api/info | jq -r .hostname; done | sort | uniq -c
```

```text
     11 a4f83c9e1b27
      9 c7b21d4e8f90
     10 e19a6c30b5d4
```

> **Note.** No `jq`? Use `grep`:
> `curl -s localhost:8080/api/info | grep -o '"hostname":"[^"]*"'`.

> **Note.** nginx caches the DNS answer for `valid=10s`, so for up to ten seconds after
> scaling, every request still goes to `pinboard-api-1` — that is why you waited. After
> that, nginx holds all three addresses and picks one per request, so the counts come out
> roughly even (not a strict rotation). This *is* load balancing — but DNS-based: nginx
> only learns about new or removed replicas when its cache expires, and nothing checks
> whether a replica is ready. Kubernetes Services (Lab 07) and readiness probes (Lab 06)
> fix both.

Map the container IDs back to Compose names:

```bash
docker ps --filter label=com.docker.compose.service=api --format '{{.ID}}  {{.Names}}'
```

```text
e19a6c30b5d4  pinboard-api-3
c7b21d4e8f90  pinboard-api-2
a4f83c9e1b27  pinboard-api-1
```

Scale back down before continuing:

```bash
docker compose up -d --wait --scale api=1
```

<details>
<summary><b>Check yourself:</b> why would <code>--scale web=3</code> fail?</summary>

Because `web` publishes `8080:8080`. Only one container can hold host port 8080, so the
second one fails with `Bind for 0.0.0.0:8080 failed: port is already allocated`. A
service is only horizontally scalable if it does not claim a fixed host resource — a
published port, a `container_name:`, or an exclusive bind mount. Getting past that limit
(one address, many replicas, on many hosts) is a large part of why Kubernetes exists.
</details>

### Step 08: The developer loop with `docker compose watch`

Compose reads `compose.override.yaml` automatically and merges it on top of
`compose.yaml`. This is the standard way to keep developer-only settings out of the
file you ship. Create `compose.override.yaml`:

```yaml
services:
  web:
    build: ./pinboard-web
    develop:
      watch:
        - action: sync
          path: ./pinboard-web/html
          target: /usr/share/nginx/html
        - action: rebuild
          path: ./pinboard-web/Dockerfile
```

`watch` needs to know how the image is built, hence the `build:` line — the override turns
`web` into a service built from your copy of the sources. `action: sync` copies changed
files into the running container (milliseconds, no restart); `action: rebuild` rebuilds
the image and recreates the container, which is what a change to the `Dockerfile`
requires.

Confirm the merge before running anything:

```bash
docker compose config | grep -A6 'develop:'
```

Now start the watcher — it runs in the foreground and prints what it does:

```bash
docker compose watch
```

```text
 Image pinboard-web:1.0 Built
 Container pinboard-web-1  Recreated
 Container pinboard-web-1  Started
Watch enabled
```

`watch` first builds the services that have a `build:` and brings the stack up to date,
then waits for file changes. (The exact wording varies between Compose releases.)

In a **second terminal**, edit the page title:

```bash
cd ~/pinboard-labs/lab04
sed -i 's|<h1>📌 Pinboard</h1>|<h1>📌 Pinboard — live edit</h1>|' pinboard-web/html/index.html
```

The first terminal reacts immediately:

```text
Syncing service "web" after 1 changes were detected
```

Reload <http://localhost:8080> — the heading changed, and no container was rebuilt or
restarted. Now touch the Dockerfile to see the other action:

```bash
touch pinboard-web/Dockerfile
```

```text
Rebuilding service(s) ["web"] after changes were detected...
service(s) ["web"] successfully built
 Container pinboard-web-1  Recreated
 Container pinboard-web-1  Started
```

Stop the watcher with `Ctrl-C` (the containers keep running).

That rebuild was tagged `pinboard-web:1.0` — the `image:` name in `compose.yaml` — so your
edited heading is now baked into the image that Lab 05 loads into Kubernetes. Put the page
back and rebuild once more:

```bash
sed -i 's|<h1>📌 Pinboard — live edit</h1>|<h1>📌 Pinboard</h1>|' pinboard-web/html/index.html
docker compose build web
```

> **Warning.** `watch` is a *development* tool. It syncs from your working copy into a
> running container, so the container's content no longer matches the image. Never rely
> on it for anything you deploy — build an image and ship that.

### Step 09: A `tools` profile for one-off containers

> **Optional** — skip to Step 10 if you are past ~30 minutes; profiles were shown in the
> session (slide 16) and nothing later depends on this step.

Not every service should start with `up`. `profiles:` marks services as opt-in. Add the
two below to `compose.yaml` (before the `volumes:` block):

```yaml
  psql:
    image: postgres:17-alpine
    profiles: ["tools"]
    environment:
      PGPASSWORD: ${POSTGRES_PASSWORD:-pinboard-secret}
    entrypoint:
      ["psql", "-h", "db", "-U", "${POSTGRES_USER:-pinboard}", "-d", "${POSTGRES_DB:-pinboard}"]
    depends_on:
      db:
        condition: service_healthy

  adminer:
    image: adminer:5
    profiles: ["tools"]
    environment:
      ADMINER_DEFAULT_SERVER: db
    ports:
      - "8081:8080"
    depends_on:
      db:
        condition: service_healthy
```

A plain `docker compose up -d` ignores both — check with `docker compose ps`. To use the
`psql` client as a throwaway container:

```bash
docker compose run --rm psql -c 'SELECT count(*) AS notes FROM notes;'
```

```text
 notes
-------
     2
(1 row)
```

`run --rm` starts one container for one command and deletes it afterwards; it does not
publish the service's ports and does not join the `up` lifecycle. This is the Compose
answer to "I need a client container on the app network for two minutes".

To get the graphical variant, start the profile explicitly:

```bash
docker compose --profile tools up -d adminer
```

```text
[+] Running 1/1
 ✔ Container pinboard-adminer-1  Started                                   0.6s
```

Open <http://localhost:8081> (system *PostgreSQL*, server `db`, user/password/database
`pinboard`) and browse the `notes` table. Then stop it again:

```bash
docker compose stop adminer && docker compose rm -f adminer
```

```text
[+] Stopping 1/1
 ✔ Container pinboard-adminer-1  Stopped                                   0.3s
Going to remove pinboard-adminer-1
[+] Removing 1/1
 ✔ Container pinboard-adminer-1  Removed                                   0.1s
```

### Step 10: Tear it down — `down` vs `down -v`

```bash
docker compose down
```

```text
[+] Running 4/4
 ✔ Container pinboard-web-1   Removed                                      0.4s
 ✔ Container pinboard-api-1   Removed                                      0.3s
 ✔ Container pinboard-db-1    Removed                                      0.3s
 ✔ Network pinboard_default   Removed                                      0.2s
```

`down` removes containers and networks — **not** volumes. Prove it:

```bash
docker volume ls --filter name=pinboard
docker compose up -d --wait
curl -s localhost:8080/api/notes | head -c 120
```

The notes are still there: the data lived in `pinboard_pinboard-data`, which survived.

> **Note.** The API stopped in a fraction of a second, and cleanly: the Go process traps
> SIGTERM, drains in-flight requests (for at most `SHUTDOWN_GRACE`, default `10s`) and
> exits 0 — the exec-form `ENTRYPOINT` from Lab 03, Step 08. A process that ignored
> SIGTERM would hold `down` for the full 10 s and then be SIGKILLed. The same contract is
> what `terminationGracePeriodSeconds` controls in Kubernetes.

Now do the destructive version:

```bash
docker compose down -v
docker volume ls --filter name=pinboard
```

```text
[+] Running 4/4
 ✔ Container pinboard-web-1          Removed                               0.4s
 ✔ Container pinboard-api-1          Removed                               0.3s
 ✔ Container pinboard-db-1           Removed                               0.3s
 ✔ Volume pinboard_pinboard-data     Removed                               0.1s
 ✔ Network pinboard_default          Removed                               0.2s
DRIVER    VOLUME NAME
local     pinboard-data
```

Only the hand-made Lab 03 volume `pinboard-data` remains — Compose only ever touches what
it created. Keep it, and keep your images: Lab 05 loads them into Kubernetes.

## Stretch goal

> **Optional — only if you finish early.** Nothing in Lab 05 depends on these exercises,
> so skip them freely. If you do one, follow its clean-up so the next lab starts from
> the expected state.

1. **Prove the ordering guarantee.** Temporarily break the database health check: in
   `compose.yaml` set the `db` healthcheck to `test: ["CMD", "false"]` and `retries: 3`,
   then run `docker compose up -d --wait`. After ~15 s `--wait` fails with
   `dependency failed to start: container pinboard-db-1 is unhealthy`, and
   `docker compose ps -a` shows `api` and `web` stuck in `Created` — they were never
   started. (A wrong `POSTGRES_PASSWORD` would *not* show this: `pg_isready` does not log
   in, so the DB still reports healthy.) Put the healthcheck back and `docker compose down`.
2. **Make the version a variable.** Change the API service to
   `image: pinboard-api:${API_TAG:-1.0}`, then run
   `API_TAG=1.1 APP_THEME=amber docker compose up -d --wait` — a shell variable beats
   `.env`, so you get the 1.1 image with an amber header without editing a file. Reload
   the page and watch the header colour change; that is the "visible rolling update" you
   will do properly in Lab 06. Put it back with `docker compose up -d --wait`.
3. **Second override file.** Create `compose.ci.yaml` that removes the published port and
   sets `restart: "no"`, and render it with
   `docker compose -f compose.yaml -f compose.ci.yaml config`. Note that `-f` replaces the
   automatic `compose.override.yaml` merge — with explicit `-f` flags, nothing is implicit.

When you are done with the stretch goals, take the stack down again (`docker compose down`)
— Lab 05 starts with no Compose stack running.

## Conclusion

**What you have now**

- `~/pinboard-labs/lab04/compose.yaml` — the whole Pinboard stack in one declarative
  file: healthcheck, dependency condition, named volume, init SQL, resource limit,
  a published port on the web tier only, and (if you did Step 09) a `tools` profile.
- `.env` + interpolation, so no credential is written in the compose file.
- `compose.override.yaml` with `develop.watch` for a sync-on-save developer loop.
- The muscle memory for `up -d --wait`, `ps`, `logs -f`, `exec`, `config`, `run --rm`,
  `down` and `down -v`.

**Clean-up state.** Containers, the Compose network and the Compose volume are gone.
Your images (`pinboard-api:1.0`, `1.1`, `1.2-broken`, `pinboard-web:1.0`) and the Lab 03
volume `pinboard-data` are kept — the next lab needs the images.

**What Compose still cannot do**, and why the rest of the course exists: it runs on one
host, it does not reschedule containers when that host dies, `--scale` is manual, there
are no rolling updates and no readiness gate, and `.env` is not a secret store. That list
is the job description of Kubernetes.

Next: [Lab 05 – Pinboard meets Kubernetes](lab05.md).
