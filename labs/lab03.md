# Lab 03 – Wire Pinboard together by hand

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare, and check your images](#step-01-prepare-and-check-your-images)
  - [Step 02: Create the network and the volume, run the database](#step-02-create-the-network-and-the-volume-run-the-database)
  - [Step 03: Run the API against the database](#step-03-run-the-api-against-the-database)
  - [Step 04: Run the web tier and pin some notes](#step-04-run-the-web-tier-and-pin-some-notes)
  - [Step 05: Prove the DNS from a busybox container](#step-05-prove-the-dns-from-a-busybox-container)
  - [Step 06: Destroy the database — the notes survive](#step-06-destroy-the-database--the-notes-survive)
  - [Step 07: Move the configuration into an `--env-file`](#step-07-move-the-configuration-into-an---env-file)
  - [Step 08: Signals — exec form vs shell form](#step-08-signals--exec-form-vs-shell-form)
  - [Step 09: Guardrails — memory limit, restart policy, health](#step-09-guardrails--memory-limit-restart-policy-health)
  - [Step 10: Bind-mount the web folder for live editing](#step-10-bind-mount-the-web-folder-for-live-editing)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Run all three Pinboard tiers as containers on a user-defined network and have them
  find each other **by name**.
- Give the database a **named volume** so the notes survive `docker rm -f`.
- Configure containers with `-e` and then with `--env-file`.
- See what exec form vs shell form does to SIGTERM, measured with `time docker stop`.
- Apply the operational knobs: `--memory`, `--restart`, `HEALTHCHECK`, bind mounts.

## Pre-requisites

- [Lab 02](lab02.md) finished. Check now — this lab cannot start without them:
  `docker image ls 'pinboard-*'` must list `pinboard-api:1.0` and `pinboard-web:1.0`.
- `postgres:17-alpine`, `alpine:3.22` and `busybox:1.37` available (Lab 01 pulled the
  first two; busybox is pulled on demand).
- Port **8080** and **8081** free on your host.

> **Continuity.** Lab 01 left you with a database whose data died with the
> container. Lab 02 produced the two Pinboard images but nothing to talk to. This
> lab connects everything: `pinboard-db` + `pinboard-api` + `pinboard-web` on the
> `pinboard-net` network, with the notes stored in the `pinboard-data` volume. At
> the end you will have typed roughly forty flags by hand — which is exactly the
> motivation for Lab 04, where the same stack becomes one `compose.yaml`.

## Guide

### Step 01: Prepare, and check your images

```bash
mkdir -p ~/pinboard-labs/lab03
cd ~/pinboard-labs/lab03
docker image ls 'pinboard-*'
```

```text
REPOSITORY     TAG          IMAGE ID       CREATED        SIZE
pinboard-api   1.0          0f7a2b3c4d5e   1 hour ago     12.8MB
pinboard-api   1.1          5e6f7a8b9c0d   1 hour ago     12.8MB
pinboard-api   1.2-broken   7a8b9c0d1e2f   1 hour ago     12.8MB
pinboard-web   1.0          2b3c4d5e6f70   1 hour ago     58.4MB
```

Missing? Rebuild them with
`bash ~/docker-kubernetes-training/labs/extras/build-all.sh` before going on.

### Step 02: Create the network and the volume, run the database

Two named resources first. A **user-defined bridge network** is what gives containers
DNS resolution by name (the legacy default bridge does not). A **named volume** is
storage you control, independent of any container's lifetime.

```bash
docker network create pinboard-net
docker volume create pinboard-data
docker network ls
docker volume ls
```

```text
c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829304a5b
pinboard-data
NETWORK ID     NAME           DRIVER    SCOPE
a1b2c3d4e5f6   bridge         bridge    local
c7d8e9f0a1b2   pinboard-net   bridge    local
f0e1d2c3b4a5   host           host      local
9a8b7c6d5e4f   none           null      local
DRIVER    VOLUME NAME
local     pinboard-data
```

Now the database, attached to the network and with the volume mounted at Postgres'
data directory. `--mount` is the explicit, self-documenting syntax — prefer it over
`-v a:b:c`, whose meaning depends on how many colons you typed.

```bash
docker run -d \
  --name pinboard-db \
  --network pinboard-net \
  --mount type=volume,src=pinboard-data,dst=/var/lib/postgresql/data \
  -e POSTGRES_USER=pinboard \
  -e POSTGRES_PASSWORD=pinboard-secret \
  -e POSTGRES_DB=pinboard \
  postgres:17-alpine
```

```text
4f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0
```

Confirm the mount is the volume you created — not an anonymous one like in Lab 01:

```bash
docker inspect pinboard-db --format '{{range .Mounts}}{{.Type}} {{.Name}} → {{.Destination}}{{end}}'
docker volume inspect pinboard-data --format '{{.Mountpoint}}'
```

```text
volume pinboard-data → /var/lib/postgresql/data
/var/lib/docker/volumes/pinboard-data/_data
```

Wait until Postgres is accepting connections:

```bash
until docker exec pinboard-db pg_isready -U pinboard -d pinboard -q; do sleep 1; done
echo "database ready"
```

```text
database ready
```

### Step 03: Run the API against the database

The API needs exactly one thing to switch from its in-memory store to Postgres:
`DATABASE_URL`. The host part of that URL is **`pinboard-db`** — the container name,
resolved by Docker's embedded DNS on `pinboard-net`. No IP addresses anywhere.

```bash
docker run -d \
  --name pinboard-api \
  --network pinboard-net \
  -e DATABASE_URL=postgres://pinboard:pinboard-secret@pinboard-db:5432/pinboard \
  -e APP_THEME=emerald \
  pinboard-api:1.0
docker logs pinboard-api
```

```text
time=2026-08-20T11:04:12.318Z level=INFO msg="pinboard-api starting" version=1.0 theme=emerald store=postgres addr=:8080 hostname=8c3f5a1b9e07
```

`store=postgres` — that one word is the whole point of the step. The API also created
the `notes` table itself on connect, so no `psql` is needed this time.

> **Note.** No `-p` here. The API is only ever called by the web tier, from inside
> the network, so it stays unpublished — the same reasoning as the database in
> Lab 01. In Kubernetes this becomes a ClusterIP Service (Session 07).

### Step 04: Run the web tier and pin some notes

The web container is the only one that gets published to your host. `API_URL` tells
its nginx where to proxy `/api/`; it is substituted into the config template at
start-up by the official image's entrypoint.

```bash
docker run -d \
  --name pinboard-web \
  --network pinboard-net \
  -e API_URL=http://pinboard-api:8080 \
  -p 8080:8080 \
  pinboard-web:1.0
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
```

```text
NAMES          IMAGE                STATUS                            PORTS
pinboard-web   pinboard-web:1.0     Up 6 seconds (health: starting)   0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
pinboard-api   pinboard-api:1.0     Up 2 minutes
pinboard-db    postgres:17-alpine   Up 4 minutes                      5432/tcp
```

Open **<http://localhost:8080>** in a browser. You should see the Pinboard header in
emerald, the greeting, and the API version/hostname/store in the meta line. Pin a
couple of notes through the form.

Then do the same from the command line, through the *web* container's proxy — which
proves the whole chain browser → nginx → API → Postgres:

```bash
curl -s -X POST http://localhost:8080/api/notes \
  -H 'content-type: application/json' \
  -d '{"text":"three containers, one network","author":"ana"}' | jq -c
curl -s http://localhost:8080/api/notes | jq -c '.[]'
curl -s http://localhost:8080/api/info | jq -c
```

```text
{"id":2,"text":"three containers, one network","author":"ana","createdAt":"2026-08-20T11:07:44.512843Z"}
{"id":2,"text":"three containers, one network","author":"ana","createdAt":"2026-08-20T11:07:44.512843Z"}
{"id":1,"text":"hello from the browser","author":"me","createdAt":"2026-08-20T11:06:58.104221Z"}
{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"8c3f5a1b9e07","store":"postgres","theme":"emerald","uptime":"3m21s","version":"1.0"}
```

And the rows really are in Postgres:

```bash
docker exec pinboard-db psql -U pinboard -d pinboard -c 'SELECT id, author, text FROM notes ORDER BY id;'
```

```text
 id | author |              text
----+--------+--------------------------------
  1 | me     | hello from the browser
  2 | ana    | three containers, one network
(2 rows)
```

### Step 05: Prove the DNS from a busybox container

Attach a throwaway container to the same network and look the others up by name:

```bash
docker run --rm -it --network pinboard-net busybox:1.37 sh
```

```sh
nslookup pinboard-api
wget -qO- http://pinboard-api:8080/api/info
wget -qO- http://pinboard-web:8080/healthz
nc -z -w2 pinboard-db 5432 && echo "db port open"
exit
```

```text
Server:		127.0.0.11
Address:	127.0.0.11:53

Non-authoritative answer:
Name:	pinboard-api
Address: 172.19.0.3

{"app":"pinboard-api","greeting":"Welcome to Pinboard","hostname":"8c3f5a1b9e07","store":"postgres","theme":"emerald","uptime":"5m02s","version":"1.0"}
ok
db port open
```

`127.0.0.11` is Docker's embedded DNS server, present on every user-defined network.
Now the contrast — the **default** bridge has no such thing:

```bash
docker run --rm busybox:1.37 nslookup pinboard-api
```

```text
Server:		192.168.1.1
Address:	192.168.1.1:53

** server can't find pinboard-api.: NXDOMAIN
```

<details>
<summary><strong>Check yourself:</strong> <code>wget http://pinboard-api:8080/api/info</code> works from busybox, but <code>curl http://pinboard-api:8080/api/info</code> fails from your host shell. Why?</summary>

The name `pinboard-api` only exists in the DNS of the `pinboard-net` network, and the
container's IP (`172.19.0.3`) is only routable from that network's namespace. Your
host is not on the network — it reaches containers only through **published ports**,
and only `pinboard-web` published one (`-p 8080:8080`). That is the intended shape:
one entry point, everything else internal. If you *want* host access to the API for
debugging, republish it deliberately (`-p 18080:8080`) rather than by default.
</details>

### Step 06: Destroy the database — the notes survive

This is the experiment that failed in Lab 01. Delete the database container outright:

```bash
docker rm -f pinboard-db
docker volume ls
```

```text
pinboard-db
DRIVER    VOLUME NAME
local     pinboard-data
```

The container is gone; the volume is not. Recreate the container with the same
command as in Step 02:

```bash
docker run -d --name pinboard-db --network pinboard-net \
  --mount type=volume,src=pinboard-data,dst=/var/lib/postgresql/data \
  -e POSTGRES_USER=pinboard -e POSTGRES_PASSWORD=pinboard-secret -e POSTGRES_DB=pinboard \
  postgres:17-alpine
until docker exec pinboard-db pg_isready -U pinboard -d pinboard -q; do sleep 1; done
docker logs pinboard-db 2>&1 | grep -E 'skipping initialization|ready to accept'
```

```text
PostgreSQL Database directory appears to contain a database; Skipping initialization

2026-08-20 11:12:30.551 UTC [1] LOG:  database system is ready to accept connections
```

`Skipping initialization` means Postgres found an existing data directory in the
volume — your notes:

```bash
curl -s http://localhost:8080/api/notes | jq -c '.[]'
```

```text
{"id":2,"text":"three containers, one network","author":"ana","createdAt":"2026-08-20T11:07:44.512843Z"}
{"id":1,"text":"hello from the browser","author":"me","createdAt":"2026-08-20T11:06:58.104221Z"}
```

Both notes are back, from the volume — and you did not touch the API. Its connection
pool noticed the old connections were dead and reconnected to **`pinboard-db` by name**:
the new container may even have a new IP, and nobody had to care.

> **Note.** If the first `curl` instead answers `{"error":"store unavailable"}` (or
> hangs for a few seconds), the pool was still holding a connection to the container
> that no longer exists. Repeat the `curl`; if it keeps failing, restart the client
> by hand with `docker restart pinboard-api`. Remember that feeling: "a dependency was
> replaced and its clients had to be checked, by a human" is precisely the class of work
> Kubernetes automates (Services, endpoints, readiness probes, restarts).

<details>
<summary><strong>Check yourself:</strong> what exactly made the difference between Lab 01 and now?</summary>

In Lab 01 the data lived in an **anonymous** volume that Docker created because the
image declares `VOLUME /var/lib/postgresql/data`. It had a random name, was tied to
that one container, and the replacement container got a brand-new empty one. Here you
mounted a **named** volume, `pinboard-data`, at the same path: it exists
independently of any container, and re-attaching it to a new container re-attaches
the data. Same image, same path — the only change is who named the storage.
</details>

### Step 07: Move the configuration into an `--env-file`

Five `-e` flags is already a lot to retype, and the password is in your shell history.
Put the configuration in a file instead.

Create `~/pinboard-labs/lab03/pinboard.env`:

```text
# Pinboard API configuration — passed with `docker run --env-file pinboard.env`.
# Format: one KEY=VALUE per line. No `export`, no quotes (they become part of the
# value), no variable expansion, no spaces around `=`.
DATABASE_URL=postgres://pinboard:pinboard-secret@pinboard-db:5432/pinboard
APP_THEME=amber
APP_GREETING=Notes from Lab 03
LOG_FORMAT=json
SHUTDOWN_GRACE=10s
```

Recreate the API with it:

```bash
docker rm -f pinboard-api
docker run -d --name pinboard-api --network pinboard-net --env-file pinboard.env pinboard-api:1.0
docker logs pinboard-api
curl -s http://localhost:8080/api/info | jq -c
```

```text
pinboard-api
{"time":"2026-08-20T11:18:03.774Z","level":"INFO","msg":"pinboard-api starting","version":"1.0","theme":"amber","store":"postgres","addr":":8080","hostname":"b7e4d0c2a915"}
{"app":"pinboard-api","greeting":"Notes from Lab 03","hostname":"b7e4d0c2a915","store":"postgres","theme":"amber","uptime":"4s","version":"1.0"}
```

Two changes in one go: `LOG_FORMAT=json` turned the logs into JSON (what a log
collector wants), and `APP_THEME=amber` changed the UI. **Reload
<http://localhost:8080>** — the header is now amber and the greeting is "Notes from
Lab 03", with the same notes underneath. That visible colour is what makes rolling
updates obvious in Session 06.

> **Warning.** An `.env` file is *not* a secret store: it sits in plain text next to
> your code, and `docker inspect` still shows every value. It keeps credentials out
> of your shell history and out of the command line — nothing more. Add `*.env` to
> `.gitignore` and `.dockerignore` (you did the latter in Lab 02). Session 08 covers
> Kubernetes Secrets and why base64 is not encryption either.

### Step 08: Signals — exec form vs shell form

`docker stop` sends **SIGTERM** to PID 1 and waits (default 10 s) before SIGKILL.
Whether your process ever *sees* that signal depends on one Dockerfile detail. Build
two nearly identical images to see it.

```bash
mkdir -p ~/pinboard-labs/lab03/signals && cd ~/pinboard-labs/lab03/signals
```

Create `app.sh`:

```bash
#!/bin/sh
# A "server" that shuts down cleanly when it is asked to.
trap 'echo "SIGTERM received — shutting down cleanly"; exit 0' TERM
echo "up as PID $$ — waiting for signals"
while true; do sleep 1; done
```

Create `Dockerfile.shell`:

```dockerfile
FROM alpine:3.22
COPY app.sh /app.sh
RUN chmod +x /app.sh
# SHELL form: Docker runs  /bin/sh -c 'echo starting…; /app.sh; echo …'
# → PID 1 is sh; app.sh is a child; sh does not forward SIGTERM to it.
CMD echo "starting…"; /app.sh; echo "app.sh has exited"
```

Create `Dockerfile.exec`:

```dockerfile
FROM alpine:3.22
COPY app.sh /app.sh
RUN chmod +x /app.sh
# EXEC form (JSON array): no shell at all — app.sh IS PID 1 and its trap runs.
CMD ["/app.sh"]
```

Build and race them:

```bash
chmod +x app.sh
docker build -f Dockerfile.shell -t sig:shell .
docker build -f Dockerfile.exec  -t sig:exec  .

docker run -d --name sig-shell sig:shell
docker run -d --name sig-exec  sig:exec
sleep 2
time docker stop sig-shell
time docker stop sig-exec
```

```text
sig-shell
real	0m10.412s
user	0m0.021s
sys	0m0.014s
sig-exec
real	0m0.294s
user	0m0.018s
sys	0m0.012s
```

**Ten seconds versus a third of a second.** Look at what each container logged and how
it died:

```bash
docker logs sig-shell; docker inspect sig-shell --format 'exit={{.State.ExitCode}}'
docker logs sig-exec;  docker inspect sig-exec  --format 'exit={{.State.ExitCode}}'
```

```text
starting…
up as PID 7 — waiting for signals
exit=137
up as PID 1 — waiting for signals
SIGTERM received — shutting down cleanly
exit=0
```

The shell-form script never saw SIGTERM (`PID 7`, no trap message) and was
**SIGKILLed** after the grace period: exit `137` = 128 + 9. The exec-form container
was PID 1, ran its cleanup, and exited `0`.

> **Note.** Why the trailing `echo "app.sh has exited"` in the shell form? Busybox's
> `sh` `exec`s the *last* command of `sh -c '…'` (bash does the same for a single
> command), so `CMD echo "starting…"; /app.sh` would quietly turn `/app.sh` into PID 1
> and the problem would disappear — which is why this bug is so slippery in real life.
> As soon as anything has to run *after* your program (a second command, a pipe, an
> `&&`, a wrapper script that does not `exec`), the shell stays around as PID 1.

This is why the Pinboard API's Dockerfile ends with
`ENTRYPOINT ["/pinboard-api"]`. Watch it behave:

```bash
time docker stop pinboard-api
docker logs --tail 3 pinboard-api
docker start pinboard-api
```

```text
pinboard-api
real	0m0.331s
{"time":"2026-08-20T11:24:51.117Z","level":"INFO","msg":"signal received, shutting down gracefully","grace":"10s"}
{"time":"2026-08-20T11:24:51.118Z","level":"INFO","msg":"bye"}
pinboard-api
```

In Kubernetes this same mechanism is what makes a rolling update seamless: a Pod is
sent SIGTERM, finishes its in-flight requests within
`terminationGracePeriodSeconds`, and exits. Shell form breaks it.

Clean up the two demo containers (keep the images if you like):

```bash
docker rm sig-shell sig-exec
cd ~/pinboard-labs/lab03
```

### Step 09: Guardrails — memory limit, restart policy, health

A container with no limits can take the whole host down. Recreate the API with a
memory cap and a restart policy:

```bash
docker rm -f pinboard-api
docker run -d --name pinboard-api --network pinboard-net \
  --env-file pinboard.env \
  --memory=32m \
  --restart unless-stopped \
  pinboard-api:1.0
docker stats --no-stream
```

```text
CONTAINER ID   NAME           CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O   PIDS
b9d1c7e30f42   pinboard-api   0.00%     9.492MiB / 32MiB      29.66%    3.21kB / 1.87kB   0B / 0B     8
5a2f8e1c4b60   pinboard-web   0.00%     6.113MiB / 15.55GiB   0.04%     18.4kB / 22.1kB   0B / 0B     9
4f1e2d3c4b5a   pinboard-db    0.15%     34.87MiB / 15.55GiB   0.22%     41.2kB / 33.7kB   0B / 0B     7

```

The Go API happily fits in 32 MiB; the two containers without a limit show the host's
total RAM, which is exactly the problem. `docker stats` (no `--no-stream`) is a live
view — `Ctrl+C` to leave it.

Read the settings back, and check whether the kernel has killed anything:

```bash
docker inspect pinboard-api \
  --format 'memory={{.HostConfig.Memory}} restart={{.HostConfig.RestartPolicy.Name}} oomkilled={{.State.OOMKilled}}'
```

```text
memory=33554432 restart=unless-stopped oomkilled=false
```

Now test the restart policy the rude way — SIGKILL the process from the host, as if it
had crashed on its own:

```bash
sudo kill -9 "$(docker inspect --format '{{.State.Pid}}' pinboard-api)"
sleep 3
docker ps --filter name=pinboard-api --format '{{.Names}} · {{.Status}}'
docker inspect pinboard-api --format 'restarts={{.RestartCount}} exit={{.State.ExitCode}} status={{.State.Status}}'
```

```text
pinboard-api · Up 2 seconds
restarts=1 exit=0 status=running
```

> **Note.** Why not `docker kill`? Docker treats `docker stop` *and* `docker kill` as a
> deliberate, manual stop, and a restart policy never undoes a manual stop — the
> container would simply stay `Exited (137)`. `.State.Pid` is the API's PID as seen from
> the host; killing it there is indistinguishable from a real crash.

Docker restarted it automatically. `unless-stopped` means "always restart, unless a
human ran `docker stop`" — so a reboot brings your stack back, but a deliberate stop
stays stopped. This is Docker's whole self-healing story, and it stops at one host:
if the *machine* dies, nothing moves your containers elsewhere. That is Session 05.

Finally, health. `pinboard-web:1.0` declares a `HEALTHCHECK` (Lab 02, Step 08), so
Docker runs it every 10 s and reports the result:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect pinboard-web --format '{{.State.Health.Status}} after {{len .State.Health.Log}} checks'
```

```text
NAMES          IMAGE                STATUS
pinboard-web   pinboard-web:1.0     Up 22 minutes (healthy)
pinboard-api   pinboard-api:1.0     Up 3 minutes
pinboard-db    postgres:17-alpine   Up 14 minutes
```

```text
healthy after 5 checks
```

> **Note.** `pinboard-api` shows **no** health state: distroless has no shell, no
> `wget` and no `curl`, so a `HEALTHCHECK` cannot be expressed in that image at all.
> Docker has no way to probe it from outside. Kubernetes does — an HTTP `readinessProbe`
> is executed by the kubelet, not inside the container. That single difference is a
> good answer to "why not just use Compose in production?".

### Step 10: Bind-mount the web folder for live editing

> **Optional** — skip this step if you are past ~35 minutes; you saw it in Demo 2 and
> Lab 04 does live editing again with `docker compose watch`.

A **bind mount** maps a host directory into the container: no copy, no rebuild, edits
are visible instantly. Perfect for developing the static front-end, wrong for
shipping it.

Start a *second* web container beside the first, on port 8081, serving the files
straight from your clone:

```bash
docker run -d \
  --name pinboard-web-dev \
  --network pinboard-net \
  -e API_URL=http://pinboard-api:8080 \
  -p 8081:8080 \
  --mount type=bind,src=$HOME/docker-kubernetes-training/src/pinboard-web/html,dst=/usr/share/nginx/html,ro \
  pinboard-web:1.0
curl -s http://localhost:8081 | grep '<h1>'
```

```text
  <h1>📌 Pinboard</h1>
```

Edit the file **on the host** and reload — no rebuild, no restart, no `docker cp`:

```bash
sed -i 's|<h1>📌 Pinboard</h1>|<h1>📌 Pinboard (live edit)</h1>|' \
  ~/docker-kubernetes-training/src/pinboard-web/html/index.html
curl -s http://localhost:8081 | grep '<h1>'
curl -s http://localhost:8080 | grep '<h1>'
```

```text
  <h1>📌 Pinboard (live edit)</h1>
  <h1>📌 Pinboard</h1>
```

Port 8081 (bind-mounted) changed; port 8080 (baked into the image at build time) did
not. Both talk to the same API and show the same notes. Open both in the browser side
by side if you want the picture.

Put your clone back the way you found it:

```bash
git -C ~/docker-kubernetes-training checkout -- src/pinboard-web/html/index.html
docker rm -f pinboard-web-dev
```

> **Warning.** `ro` in the mount means the *container* cannot write to your source
> tree — a habit worth keeping. Bind mounts also inherit host permissions and paths,
> which is why they do not survive the move to another machine (or to Kubernetes).
> Compose formalises this in Lab 04 (`docker compose watch`); in production the files
> belong in the image.

## Stretch goal

> **Optional — only if you finish early.** Nothing in Lab 04 depends on these exercises,
> so skip them freely. If you do one, follow its clean-up so the next lab starts from
> the expected state.

1. **Back up the volume with a throwaway container.** The classic pattern — mount the
   volume *and* a host folder into a temporary container and tar one into the other:

   ```bash
   docker run --rm \
     --mount type=volume,src=pinboard-data,dst=/data,ro \
     --mount type=bind,src=$PWD,dst=/backup \
     alpine:3.22 tar czf /backup/pinboard-data.tgz -C /data .
   ls -lh pinboard-data.tgz
   ```

   For a database, do it properly with `docker exec pinboard-db pg_dump -U pinboard pinboard > dump.sql`
   — a file-level copy of a *running* Postgres is not a consistent backup.

2. **Force an OOM kill.** The Go API is too frugal to make the point (it idles at a few
   MiB and survives even `--memory=6m`, Docker's minimum), so use a deliberate memory hog —
   `tail` buffers `/dev/zero` forever, looking for a newline:

   ```bash
   docker run -d --name hog --memory=32m --memory-swap=32m busybox:1.37 tail /dev/zero
   sleep 3
   docker inspect hog --format '{{.State.OOMKilled}} {{.State.ExitCode}}'
   docker rm hog
   ```

   It reports `true 137`. In Session 09 you will meet the same event as `OOMKilled` in
   `kubectl describe pod`.

3. **Count the flags.** Write down every flag you typed in Steps 02–09 to bring the
   stack up. Then look at `~/docker-kubernetes-training/src/compose.yaml` — the same
   stack, declaratively, in 50 lines. That is Lab 04.

4. **Inspect the network.** `docker network inspect pinboard-net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'`
   lists every attached container and its IP. Try `docker network disconnect pinboard-net pinboard-db`
   and watch the API fail; reconnect it and restart the API.

## Conclusion

**What you have now**

Pinboard runs for real: a browser on <http://localhost:8080> reaches nginx, which
proxies `/api/` to the Go API by container name, which stores notes in Postgres, whose
data lives in a volume that outlives its container. You configured it with `-e` and
then with `--env-file`, capped its memory, gave it a restart policy, watched its
health, and proved why `ENTRYPOINT ["…"]` matters.

**Cleanup — containers only.** Remove the containers but **keep the network, the
volume and the images**: Lab 04 rebuilds this stack with Compose and the stretch goals
above reuse the volume.

```bash
docker rm -f pinboard-web pinboard-api pinboard-db
docker ps -a
docker network ls --filter name=pinboard-net
docker volume ls
docker image ls 'pinboard-*'
```

```text
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
NETWORK ID     NAME           DRIVER    SCOPE
c7d8e9f0a1b2   pinboard-net   bridge    local
DRIVER    VOLUME NAME
local     pinboard-data
REPOSITORY     TAG          IMAGE ID       CREATED        SIZE
pinboard-api   1.0          0f7a2b3c4d5e   2 hours ago    12.8MB
pinboard-api   1.1          5e6f7a8b9c0d   2 hours ago    12.8MB
pinboard-api   1.2-broken   7a8b9c0d1e2f   2 hours ago    12.8MB
pinboard-web   1.0          2b3c4d5e6f70   2 hours ago    58.4MB
```

> **Warning.** Do **not** run `docker volume prune --all` or `docker system prune
> --volumes` from here on: `pinboard-data` holds your notes, and the four
> `pinboard-*` images are needed all the way to the capstone.

Next: **[Lab 04 – Pinboard in one file](lab04.md)** — everything you just typed by
hand, expressed once in `compose.yaml`, with health-gated startup ordering and a
single `docker compose up -d --wait`.
