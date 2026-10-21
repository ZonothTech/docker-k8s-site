# Lab 01 – Run the Pinboard database tier

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare your working folder and pull the image](#step-01-prepare-your-working-folder-and-pull-the-image)
  - [Step 02: Run Postgres as a container](#step-02-run-postgres-as-a-container)
  - [Step 03: Read the logs](#step-03-read-the-logs)
  - [Step 04: Create the `notes` table with `docker exec`](#step-04-create-the-notes-table-with-docker-exec)
  - [Step 05: Inspect the container with `--format`](#step-05-inspect-the-container-with---format)
  - [Step 06: Stop and start — the data survives](#step-06-stop-and-start--the-data-survives)
  - [Step 07: Remove the container — the data is gone](#step-07-remove-the-container--the-data-is-gone)
  - [Step 08: Lifecycle practice with nginx and alpine](#step-08-lifecycle-practice-with-nginx-and-alpine)
  - [Step 09: Take stock and clean up](#step-09-take-stock-and-clean-up)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Run a real database as a container, configured entirely through environment variables.
- Practise the container lifecycle: `run`, `logs`, `exec`, `inspect`, `stop`, `start`, `rm`.
- Read a container's configuration and state with `docker inspect --format`.
- See with your own eyes **where the data lives** — and why it disappears when the
  container is removed (the motivation for volumes in Lab 03).
- Pull an image by **digest**, and account for your disk with `docker system df` / `prune`.

## Pre-requisites

- [Lab 00 – Course setup](lab00-setup.md) finished: Docker Engine 28+ runs without `sudo`.
- The course repo cloned at `~/docker-kubernetes-training`.
- Nothing else is listening on port **8080** on your machine (Step 08 publishes it).

> **Continuity.** Pinboard is a three-tier app — web → API → database — and we build
> it from the bottom up. This lab stands up the **database tier only**: a
> `postgres:17-alpine` container with the `notes` table that the Pinboard API will
> read and write from Lab 03 onwards. You are not building any image yet (that is
> Lab 02) and nothing is wired together yet (that is Lab 03). By the end of this
> lab the database will be *gone* — on purpose.

## Guide

### Step 01: Prepare your working folder and pull the image

All the work you do by hand in this course lives under `~/pinboard-labs/labNN/`.
Keeping it out of the cloned repo means you can always `git pull` the course repo
without conflicts.

```bash
mkdir -p ~/pinboard-labs/lab01
cd ~/pinboard-labs/lab01
```

Pull the database image explicitly, before running anything. `docker run` would pull
it anyway, but doing it separately shows you the layers and the digest.

```bash
docker pull postgres:17-alpine
```

```text
17-alpine: Pulling from library/postgres
9824c27679d3: Pull complete
7c34eb1b1e4d: Pull complete
8f2b9b6f9c95: Pull complete
d0a1c8ba5b1a: Pull complete
Digest: sha256:1f2c5d3a7f8f5a4d2e0e3f5b8a6c9d7e4b2a1c0f9e8d7c6b5a4f3e2d1c0b9a87
Status: Downloaded newer image for postgres:17-alpine
docker.io/library/postgres:17-alpine
```

That last line is the full name Docker actually used: `docker.io/library/postgres:17-alpine`
— registry / namespace / repository : tag. The `Digest:` line is the **content
address** of that image: it cannot change, while the tag `17-alpine` will point at a
new build next month. Pin by digest when you need reproducibility:

```bash
DIGEST=$(docker image inspect postgres:17-alpine --format '{{index .RepoDigests 0}}')
echo "$DIGEST"
docker pull "$DIGEST"
```

```text
postgres@sha256:1f2c5d3a7f8f5a4d2e0e3f5b8a6c9d7e4b2a1c0f9e8d7c6b5a4f3e2d1c0b9a87
docker.io/library/postgres@sha256:1f2c5d3a7f8f5a4d2e0e3f5b8a6c9d7e4b2a1c0f9e8d7c6b5a4f3e2d1c0b9a87: Pulling from library/postgres
Digest: sha256:1f2c5d3a7f8f5a4d2e0e3f5b8a6c9d7e4b2a1c0f9e8d7c6b5a4f3e2d1c0b9a87
Status: Image is up to date for postgres@sha256:1f2c5d...
```

Nothing was downloaded — you already have exactly those bytes.

> **Note.** Your digest will be different from the one printed above; images are
> rebuilt regularly. Always read yours from `docker image inspect`, never copy one
> out of a lab sheet.

### Step 02: Run Postgres as a container

The official Postgres image is configured **only** through environment variables. No
config file, no installer, no `initdb` by hand: you pass three variables and the
image's entrypoint bootstraps a cluster on first start.

```bash
docker run -d \
  --name pinboard-db \
  -e POSTGRES_USER=pinboard \
  -e POSTGRES_PASSWORD=pinboard-secret \
  -e POSTGRES_DB=pinboard \
  postgres:17-alpine
```

```text
6b0a2fd4c9e3b1a75f2c8d0e4a6b9c1d3e5f7a8b0c2d4e6f8a0b1c3d5e7f9a2b
```

The long hex string is the container ID; `-d` means it runs in the background
("detached"). Check it is up:

```bash
docker ps
```

```text
CONTAINER ID   IMAGE                COMMAND                  CREATED         STATUS         PORTS      NAMES
6b0a2fd4c9e3   postgres:17-alpine   "docker-entrypoint.s…"   8 seconds ago   Up 7 seconds   5432/tcp   pinboard-db
```

> **Note.** `5432/tcp` under PORTS is the port the image *declares* (`EXPOSE`), not a
> published one — there is no `->` arrow, so nothing on your host can reach it. That
> is deliberate: only the Pinboard API needs the database, and from Lab 03 it will
> reach it over a Docker network. A database on `localhost:5432` is a habit worth
> not forming.

### Step 03: Read the logs

A container's logs are simply whatever PID 1 wrote to stdout/stderr. Docker captures
them for you — no log file to find, no `journalctl`.

```bash
docker logs pinboard-db | tail -12
```

```text
PostgreSQL init process complete; ready for start up.

2026-08-20 09:14:22.184 UTC [1] LOG:  starting PostgreSQL 17.6 on x86_64-pc-linux-musl, compiled by gcc (Alpine 14.2.0) 14.2.0, 64-bit
2026-08-20 09:14:22.185 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
2026-08-20 09:14:22.185 UTC [1] LOG:  listening on IPv6 address "::", port 5432
2026-08-20 09:14:22.188 UTC [1] LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"
2026-08-20 09:14:22.190 UTC [1] LOG:  database system was shut down at 2026-08-20 09:14:21 UTC
2026-08-20 09:14:22.194 UTC [1] LOG:  database system is ready to accept connections
```

`database system is ready to accept connections` is the line to wait for. Useful
variants — try `docker logs --tail 5 pinboard-db`, `docker logs --since 2m pinboard-db`,
and `docker logs -f pinboard-db` (follow; `Ctrl+C` to stop following — it does **not**
stop the container).

### Step 04: Create the `notes` table with `docker exec`

`docker exec` starts an **extra** process inside an already-running container. `-it`
gives it a terminal, exactly like `ssh` would — except there is no ssh daemon, no
extra port and no second user account.

```bash
docker exec -it pinboard-db psql -U pinboard -d pinboard
```

```text
psql (17.6)
Type "help" for help.

pinboard=#
```

At the `pinboard=#` prompt, create the table Pinboard uses. This is the same DDL as
`~/docker-kubernetes-training/src/db/init.sql`):

```sql
CREATE TABLE IF NOT EXISTS notes (
  id         BIGSERIAL PRIMARY KEY,
  text       TEXT NOT NULL,
  author     TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

```text
CREATE TABLE
```

Add a few notes:

```sql
INSERT INTO notes (text, author) VALUES
  ('A container is just a process with its own view of the system', 'ana'),
  ('Images are layers; containers add a thin writable one on top', 'bruno'),
  ('Hello from init.sql', 'postgres');
```

```text
INSERT 0 3
```

Check what you have, then leave psql:

```sql
\dt
SELECT id, text, author FROM notes ORDER BY id;
\q
```

```text
        List of relations
 Schema | Name  | Type  |  Owner
--------+-------+-------+----------
 public | notes | table | pinboard
(1 row)

 id |                             text                              |  author
----+---------------------------------------------------------------+----------
  1 | A container is just a process with its own view of the system | ana
  2 | Images are layers; containers add a thin writable one on top   | bruno
  3 | Hello from init.sql                                            | postgres
(3 rows)
```

You can also run a single statement without an interactive session — handy in scripts:

```bash
docker exec pinboard-db psql -U pinboard -d pinboard -c 'SELECT count(*) FROM notes;'
```

```text
 count
-------
     3
(1 row)
```

<details>
<summary><strong>Check yourself:</strong> why is it <code>docker exec</code> here and not <code>docker run</code>?</summary>

`docker run` always creates a **new container** from an image — a brand-new,
freshly-initialised, empty database in this case. `docker exec` runs a command
**inside a container that already exists and is running**, so it sees the same
filesystem and the same running Postgres server. Rule of thumb: `run` = new
container, `exec` = visit a running one, `start` = wake an existing stopped one.
</details>

### Step 05: Inspect the container with `--format`

`docker inspect` prints the container's complete state and configuration as JSON —
several hundred lines. `--format` (a Go template) picks out just what you need, and
is the same syntax you will use in scripts and CI.

```bash
docker inspect pinboard-db --format '{{.State.Status}}'
docker inspect pinboard-db --format '{{.State.StartedAt}}'
docker inspect pinboard-db --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
docker inspect pinboard-db --format '{{.Config.Image}} → {{.Image}}'
docker inspect pinboard-db --format '{{range .Config.Env}}{{println .}}{{end}}'
```

```text
running
2026-08-20T09:14:21.905517293Z
172.17.0.2
postgres:17-alpine → sha256:6c1e5d9a3b2f4c8e7d0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60
POSTGRES_USER=pinboard
POSTGRES_PASSWORD=pinboard-secret
POSTGRES_DB=pinboard
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PG_MAJOR=17
PG_VERSION=17.6
PGDATA=/var/lib/postgresql/data
```

Two things to notice:

1. The container has its **own IP** (`172.17.0.2`) on Docker's default bridge. That
   is why nothing had to be published for `psql` inside the container to work.
2. Your **password is in plain text** in the container's configuration, readable by
   anyone who can run `docker inspect`; it also sits in the process environment
   (`/proc/<pid>/environ`, readable by root on the host) and in your shell history. Session 08 covers
   how Kubernetes handles this (and why Secrets are *encoded*, not encrypted).

Now the interesting one — where does the data actually live?

```bash
docker inspect pinboard-db --format '{{range .Mounts}}{{.Type}} {{.Name}} → {{.Destination}}{{end}}'
```

```text
volume 6f5c4e3d2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e → /var/lib/postgresql/data
```

The Postgres image declares `VOLUME /var/lib/postgresql/data` in its Dockerfile, so
Docker created an **anonymous volume** with a random name and mounted it there. Keep
that name in mind — Step 07 comes back to it.

### Step 06: Stop and start — the data survives

`docker stop` sends **SIGTERM** to PID 1 and waits (10 s by default) before
SIGKILL. Postgres treats SIGTERM as "shut down cleanly", so this is a real database
shutdown, not a power cut.

```bash
docker stop pinboard-db
docker ps -a --filter name=pinboard-db
```

```text
pinboard-db
CONTAINER ID   IMAGE                COMMAND                  CREATED         STATUS                     PORTS     NAMES
6b0a2fd4c9e3   postgres:17-alpine   "docker-entrypoint.s…"   5 minutes ago   Exited (0) 3 seconds ago             pinboard-db
```

`Exited (0)` — exit code 0, a clean stop. The container still exists; it is just not
running. Note that `docker ps` alone would not have shown it: you need `-a`.

```bash
docker start pinboard-db
sleep 3
docker exec pinboard-db psql -U pinboard -d pinboard -c 'SELECT count(*) FROM notes;'
```

```text
pinboard-db
 count
-------
     3
(1 row)
```

Your three notes are still there. `stop`/`start` is not destructive — the container's
filesystem (and its mounted volume) is untouched.

### Step 07: Remove the container — the data is gone

Now remove it. `-f` stops it first if needed.

```bash
docker rm -f pinboard-db
```

```text
pinboard-db
```

Run a fresh one with exactly the same command as in Step 02, and look for your notes:

```bash
docker run -d --name pinboard-db \
  -e POSTGRES_USER=pinboard -e POSTGRES_PASSWORD=pinboard-secret -e POSTGRES_DB=pinboard \
  postgres:17-alpine
sleep 5
docker exec pinboard-db psql -U pinboard -d pinboard -c 'SELECT count(*) FROM notes;'
```

```text
ERROR:  relation "notes" does not exist
LINE 1: SELECT count(*) FROM notes;
                             ^
```

The table is gone, the notes are gone. The new container got a **new, empty**
anonymous volume — and the old one is still sitting on your disk with your data in
it, orphaned and unreachable:

```bash
docker volume ls
```

```text
DRIVER    VOLUME NAME
local     6f5c4e3d2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e
local     b2a1c0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1
```

> **Warning.** This is the single most common beginner accident: `docker rm` a
> database container and lose the data, while the disk quietly fills up with
> anonymous volumes nobody can identify. The fix is to mount a **named** volume
> yourself, so that the storage has a name you chose, outlives any container, and
> can be re-attached to the next one. That is exactly what Lab 03 does with
> `--mount type=volume,src=pinboard-data,...` — the notes you pin there will survive
> `docker rm -f pinboard-db`.

<details>
<summary><strong>Check yourself:</strong> the container's writable layer survived <code>stop</code>/<code>start</code> in Step 06 but the data still vanished in Step 07. What is the actual rule?</summary>

Two different storage areas were in play. Anything a container writes goes to its
**writable layer**, which is created with the container and **deleted with it** —
`stop`/`start` keeps it, `rm` destroys it. But `/var/lib/postgresql/data` was not on
the writable layer at all: the image declares a `VOLUME` there, so Docker mounted an
anonymous volume. Volumes outlive containers, but an **anonymous** one is bound to
the container that created it by name-you-never-saw: the replacement container in
Step 07 created its own. Either way the lesson is the same — if you care about the
data, name the volume and mount it on purpose.
</details>

Remove the second container too; we are done with databases in this lab:

```bash
docker rm -f pinboard-db
```

### Step 08: Lifecycle practice with nginx and alpine

Same lifecycle, two very different containers. First a long-running server, with a
**published port** this time (`-p HOST:CONTAINER`):

```bash
docker run -d --name web-demo -p 8080:80 nginx:1.28-alpine
docker ps --filter name=web-demo
curl -s http://localhost:8080 | head -5
```

```text
CONTAINER ID   IMAGE                COMMAND                   CREATED         STATUS         PORTS                                     NAMES
9d3e1f7a4c02   nginx:1.28-alpine    "/docker-entrypoint.…"    3 seconds ago   Up 2 seconds   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp   web-demo
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

Now `0.0.0.0:8080->80/tcp` *does* have an arrow: traffic to port 8080 on your host is
forwarded to port 80 inside the container.

Change the page from inside the container — nginx serves files from
`/usr/share/nginx/html`:

```bash
docker exec web-demo sh -c 'echo "<h1>Pinboard is coming soon</h1>" > /usr/share/nginx/html/index.html'
curl -s http://localhost:8080
```

```text
<h1>Pinboard is coming soon</h1>
```

> **Note.** You just modified the container's **writable layer**, not the image.
> `docker run --rm nginx:1.28-alpine` would still serve the stock page, and this edit
> dies with the container. Editing files inside a running container is a debugging
> move, never a deployment method — Lab 02 bakes changes into an image, Lab 03
> mounts them from the host.

Watch the access log you just generated, then stop and remove the container:

```bash
docker logs --tail 3 web-demo
docker stop web-demo
docker rm web-demo
```

```text
172.17.0.1 - - [20/Aug/2026:09:31:02 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.5.0" "-"
172.17.0.1 - - [20/Aug/2026:09:31:20 +0000] "GET / HTTP/1.1" 200 33 "-" "curl/8.5.0" "-"
web-demo
web-demo
```

Now the opposite kind of container: interactive and disposable. `-it` attaches your
terminal, `--rm` deletes the container the moment you exit.

```bash
docker run -it --rm alpine:3.22 sh
```

Inside it, prove that a container is just an isolated process:

```sh
hostname
cat /etc/os-release | head -2
ps -ef
ls /
exit
```

```text
3f8c1b2d4e6a
NAME="Alpine Linux"
ID=alpine
PID   USER     TIME  COMMAND
    1 root      0:00 sh
    7 root      0:00 ps -ef
bin    dev    etc    home   lib    media  mnt    opt    proc   root   run    sbin   srv    sys    tmp    usr    var
```

Your shell is **PID 1** and it can see exactly two processes — its own PID namespace.
Meanwhile on the host, that same shell is an ordinary process (`ps -ef | grep sh`).
The hostname is the container ID. And because of `--rm`, the container is already
gone:

```bash
docker ps -a --filter ancestor=alpine:3.22
```

```text
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

### Step 09: Take stock and clean up

List **everything**, including stopped containers, with a readable format:

```bash
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

```text
NAMES     IMAGE     STATUS
```

Now account for the disk. This is the command to reach for when a lab machine runs
out of space:

```bash
docker system df
```

```text
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          4         0         281.4MB   281.4MB (100%)
Containers      0         0         0B        0B
Local Volumes   2         0         84.2MB    84.2MB (100%)
Build Cache     0         0         0B        0B
```

Remove stopped containers, then the two orphaned Postgres volumes:

```bash
docker container prune -f
docker volume prune -f
docker system df
```

```text
Total reclaimed space: 0B
Deleted Volumes:
6f5c4e3d2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e
b2a1c0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1

Total reclaimed space: 84.2MB
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          4         0         281.4MB   281.4MB (100%)
Containers      0         0         0B        0B
Local Volumes   0         0         0B        0B
Build Cache     0         0         0B        0B
```

> **Warning.** `docker volume prune` removes **anonymous** volumes only, which is
> safe here. From Lab 03 you will own a *named* volume called `pinboard-data` with
> notes in it — plain `prune` leaves it alone, but `docker volume prune --all` and
> `docker system prune --volumes` would delete it. Never type either of those on a
> machine that matters.

**Keep your images.** Do not run `docker image prune -a`: `postgres:17-alpine`,
`nginx:1.28-alpine` and `alpine:3.22` are used again in Labs 02–04.

## Stretch goal

Stretch goals 2 and 3 need a running `pinboard-db`: start it again with the Step 02
command first. When you are done, remove it (`docker rm -f pinboard-db`) and repeat the
Step 09 clean-up so you end the lab with no containers and no volumes.

1. **Let the image create the table for you.** Postgres runs any `*.sql` in
   `/docker-entrypoint-initdb.d/` on **first** start. Try it with a bind mount:

   ```bash
   docker run -d --name db-init \
     -e POSTGRES_USER=pinboard -e POSTGRES_PASSWORD=pinboard-secret -e POSTGRES_DB=pinboard \
     -v ~/docker-kubernetes-training/src/db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro \
     postgres:17-alpine
   sleep 5
   docker exec db-init psql -U pinboard -d pinboard -c 'SELECT text, author FROM notes;'
   docker rm -f db-init
   ```

   Then re-run it against an *existing* data directory and confirm the script is
   **not** executed a second time — a classic production surprise.

2. **Wait properly instead of `sleep 5`.** The image ships `pg_isready`:

   ```bash
   until docker exec pinboard-db pg_isready -U pinboard -d pinboard -q; do sleep 1; done
   ```

   This is the same idea as a container **health check** (Lab 03) and a Kubernetes
   **readiness probe** (Session 06).

3. **Watch resources live.** With the database running, run `docker stats` in a
   second terminal while you insert a few thousand rows with
   `INSERT INTO notes (text) SELECT 'note ' || g FROM generate_series(1,5000) g;`.
   Note the memory number — Lab 03 puts a limit on it.

## Conclusion

**What you have now**

- Hands-on with the whole container lifecycle: `pull` (by tag and by digest), `run -d`,
  `ps`/`ps -a`, `logs`, `exec`, `inspect --format`, `stop`, `start`, `rm`, `prune`.
- A concrete answer to "where does the data live?": the writable layer dies with the
  container, and an *anonymous* volume is barely better. Named volumes (Lab 03) are
  the fix.
- The images `postgres:17-alpine`, `nginx:1.28-alpine` and `alpine:3.22` cached
  locally — **keep them**.

**State on disk:** no containers, no volumes, images only. Pinboard has no database
yet, and that is fine: Lab 02 builds the application images, and Lab 03 brings the
database back — this time with storage that survives.

Next: **[Lab 02 – Build the Pinboard images](lab02.md)**.
