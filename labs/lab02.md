# Lab 02 – Build the Pinboard images

## Table of Contents

- [Goals](#goals)
- [Pre-requisites](#pre-requisites)
- [Guide](#guide)
  - [Step 01: Prepare your working folder](#step-01-prepare-your-working-folder)
  - [Step 02: Write the naive Dockerfile](#step-02-write-the-naive-dockerfile)
  - [Step 03: Find out where those megabytes went](#step-03-find-out-where-those-megabytes-went)
  - [Step 04: Rewrite it as a multi-stage build](#step-04-rewrite-it-as-a-multi-stage-build)
  - [Step 05: Compare the two images](#step-05-compare-the-two-images)
  - [Step 06: Run the API and call it](#step-06-run-the-api-and-call-it)
  - [Step 07: Build `1.1` and `1.2-broken`](#step-07-build-11-and-12-broken)
  - [Step 08: Build `pinboard-web:1.0`](#step-08-build-pinboard-web10)
  - [Step 09: Layer caching and `.dockerignore`](#step-09-layer-caching-and-dockerignore)
  - [Step 10 (optional): Publish to Docker Hub](#step-10-optional-publish-to-docker-hub)
- [Stretch goal](#stretch-goal)
- [Conclusion](#conclusion)

## Goals

- Write a working Dockerfile the naive way, and measure how bad it is (≈ 400 MB).
- Rewrite it as a **multi-stage** build ending in a distroless, non-root image (≈ 13 MB),
  understanding every block: dependency caching, `ARG`, `ENTRYPOINT` exec form, OCI labels.
- Build the four images every later lab depends on: `pinboard-api:1.0`, `1.1`,
  `1.2-broken` and `pinboard-web:1.0`.
- Read image metadata with `docker image ls`, `docker history` and `docker image inspect --format`.
- See BuildKit's layer cache being used — and being invalidated — and fix the build
  context with `.dockerignore`.

## Pre-requisites

- [Lab 01](lab01.md) finished; Docker Engine 28+ with the Buildx plugin
  (`docker buildx version` works).
- The course repo at `~/docker-kubernetes-training`.
- Internet access for the first build (Go modules and base images are downloaded once).
- For the **optional** Step 10 only: a free Docker Hub account (see Lab 00).

> **Continuity.** In Lab 01 you ran somebody else's image. Pinboard's own two
> images do not exist yet — this lab creates them. Nothing is wired together here:
> the API runs alone, with its in-memory store, because `DATABASE_URL` is unset.
> Lab 03 connects these images to the database over a Docker network.

## Guide

### Step 01: Prepare your working folder

Work in `~/pinboard-labs/lab02/` and copy the API sources there, so the pristine copy
in the repo stays untouched.

```bash
mkdir -p ~/pinboard-labs/lab02
cp -r ~/docker-kubernetes-training/src/pinboard-api ~/pinboard-labs/lab02/pinboard-api
cd ~/pinboard-labs/lab02/pinboard-api
ls -l
```

```text
total 40
-rw-r--r-- 1 student student  1418 Aug 20 10:02 Dockerfile
-rw-r--r-- 1 student student   331 Aug 20 10:02 go.mod
-rw-r--r-- 1 student student  2044 Aug 20 10:02 go.sum
-rw-r--r-- 1 student student 11982 Aug 20 10:02 main.go
```

The copy already contains the finished Dockerfile. Move it out of the way so you can
write your own — and so BuildKit does not pick it up by accident. The copy also brought
a hidden `.dockerignore` (`ls -la` shows it); delete it — you will write your own in
Step 09 and see why it matters:

```bash
mv Dockerfile Dockerfile.reference
rm .dockerignore
```

> **Note.** No Go knowledge is needed in this course. All you need to know about
> `main.go` is that it compiles to a single self-contained binary, listens on
> `PORT` (8080), and is configured by environment variables (`src/README.md` has
> the table). Peek at `Dockerfile.reference` only after Step 04 — writing it
> yourself first is the point of the exercise.

### Step 02: Write the naive Dockerfile

This is what almost everyone writes the first time: take the language's official
image, copy the source in, build, run.

Create `Dockerfile`:

```dockerfile
# The obvious first attempt: one stage, the full Go toolchain, ship everything.
FROM golang:1.25-alpine

WORKDIR /src

# Copy the whole build context in one go.
COPY . .

# CGO off → a statically linked binary (the alpine image has no C compiler).
ENV CGO_ENABLED=0
RUN go build -o /pinboard-api .

EXPOSE 8080
CMD ["/pinboard-api"]
```

Build it. The final `.` is the **build context**: the directory whose contents are
sent to the builder.

```bash
docker build -t pinboard-api:naive .
```

```text
[+] Building 51.7s (9/9) FINISHED                                        docker:default
 => [internal] load build definition from Dockerfile                               0.0s
 => [internal] load metadata for docker.io/library/golang:1.25-alpine              1.1s
 => [internal] load .dockerignore                                                  0.0s
 => [1/4] FROM docker.io/library/golang:1.25-alpine@sha256:8a1f2e3c4d5b6a7e...    14.6s
 => [internal] load build context                                                  0.1s
 => => transferring context: 15.98kB                                               0.0s
 => [2/4] WORKDIR /src                                                             0.1s
 => [3/4] COPY . .                                                                 0.0s
 => [4/4] RUN go build -o /pinboard-api .                                         33.9s
 => exporting to image                                                             1.9s
 => => writing image sha256:3a9c7e12b04f1d8e5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a0f       0.0s
 => => naming to docker.io/library/pinboard-api:naive                              0.0s
```

It works. Now look at the price:

```bash
docker image ls pinboard-api
```

```text
REPOSITORY     TAG      IMAGE ID       CREATED          SIZE
pinboard-api   naive    3a9c7e12b04f   12 seconds ago   412MB
```

**412 MB to ship a 10 MB program.** Every one of those megabytes is pulled on every
node, scanned by every security scanner, and stored in every registry.

> **Note.** On a fresh Docker 29 install (containerd image store, check with
> `docker info -f '{{.Driver}}'` → `overlayfs`) `docker image ls` prints `DISK USAGE` and
> `CONTENT SIZE` columns instead of `SIZE` — roughly 590 MB / 120 MB here and 20 MB /
> 4.5 MB for the multi-stage image in Step 05. Different numbers, same lesson.

> **Note.** If the build log ever shows `go: downloading go1.x (linux/amd64)`, that is
> Go's toolchain switch: `go.mod` asked for a newer Go than the base image ships, so
> the toolchain fetches itself — another ~250 MB living in your image for no runtime
> reason. Pin the base image to the Go version in `go.mod` to avoid it.

### Step 03: Find out where those megabytes went

`docker history` shows the layers of an image, newest first, with the instruction
that produced each one.

```bash
docker history pinboard-api:naive
```

```text
IMAGE          CREATED         CREATED BY                                      SIZE      COMMENT
3a9c7e12b04f   1 minute ago    CMD ["/pinboard-api"]                           0B        buildkit.dockerfile.v0
<missing>      1 minute ago    EXPOSE map[8080/tcp:{}]                         0B        buildkit.dockerfile.v0
<missing>      1 minute ago    RUN /bin/sh -c go build -o /pinboard-api . #…   276MB     buildkit.dockerfile.v0
<missing>      1 minute ago    ENV CGO_ENABLED=0                               0B        buildkit.dockerfile.v0
<missing>      1 minute ago    COPY . . # buildkit                             16kB      buildkit.dockerfile.v0
<missing>      1 minute ago    WORKDIR /src                                    0B        buildkit.dockerfile.v0
<missing>      5 days ago      ...golang toolchain...                          128MB
<missing>      5 days ago      ...alpine base...                               8.4MB
```

Three lessons in one screen:

1. The `RUN go build` layer is **276 MB** — it contains the compiler's output *and*
   the downloaded modules and the build cache. Anything a
   `RUN` writes stays in the layer forever, even if a later instruction deletes it.
2. The `golang` base itself is ~136 MB of compiler, linker and standard library —
   things a *running* API never needs.
3. Layers are **additive**. You cannot make an image smaller by removing files in a
   later step; you have to not put them in.

The fix is not to clean up. The fix is to **build in one image and ship from another**.

### Step 04: Rewrite it as a multi-stage build

Replace the contents of `Dockerfile` with the version below — this is the real
Pinboard API Dockerfile (identical to `Dockerfile.reference` you moved aside):

```dockerfile
# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Pinboard API — multi-stage build
#   stage "build":   compile a static Go binary (needs the Go toolchain, ~300 MB)
#   stage "runtime": copy ONLY the binary into a distroless image (~10 MB)
# ---------------------------------------------------------------------------
FROM golang:1.25-alpine AS build
WORKDIR /src

# 1. Download dependencies first so this layer is cached until go.mod changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# 2. Now copy the source; a code change only invalidates from here on.
COPY . .
ARG APP_VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags="-s -w -X main.defaultVersion=${APP_VERSION}" \
      -o /out/pinboard-api .

# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="pinboard-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/ZonothTech/docker-k8s-site" \
      org.opencontainers.image.description="Pinboard API — Containers & Kubernetes course sample"

ENV PORT=8080 APP_VERSION=${APP_VERSION}
COPY --from=build /out/pinboard-api /pinboard-api
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/pinboard-api"]
```

Read it block by block — every line is there for a reason:

| Block | What it does | Why it matters |
|---|---|---|
| `# syntax=docker/dockerfile:1` | Pins the Dockerfile frontend; enables `RUN --mount` and friends | Without it, `--mount=type=cache` is a syntax error |
| `FROM golang:1.25-alpine AS build` | First stage, **named** `build` | Named stages can be targeted (`--target build`) and copied from |
| `COPY go.mod go.sum ./` then `RUN go mod download` | Dependencies are their own layer | Editing `main.go` does **not** re-download modules — the single biggest build-time win |
| `COPY . .` **after** the dependency layer | Source comes last | Cache invalidation flows downwards: put what changes often at the bottom |
| `RUN --mount=type=cache,...` | BuildKit cache mounts for `/go/pkg/mod` and the build cache | Fast rebuilds **without** baking caches into a layer |
| `ARG APP_VERSION=dev` | A **build-time** variable, set with `--build-arg` | `ARG` exists only during the build; it is *not* in the running container |
| `-ldflags="-s -w -X main.defaultVersion=${APP_VERSION}"` | Strips debug info and stamps the version into the binary | This is how `1.0` and `1.1` differ from the same source |
| `FROM gcr.io/distroless/static-debian12:nonroot` | Second stage: the runtime image | No shell, no package manager, no libc gap — ~2 MB of "just enough to run a static binary" |
| `LABEL org.opencontainers.image.*` | Standard **OCI annotations** | Tooling, registries and scanners read these; free provenance |
| `ENV PORT=8080 APP_VERSION=${APP_VERSION}` | Runtime defaults, overridable with `-e` | `ENV` *does* persist into the container, unlike `ARG` |
| `COPY --from=build /out/pinboard-api /pinboard-api` | The only thing that crosses the stage boundary | The toolchain, sources and caches are simply never shipped |
| `USER 65532:65532` | Runs as the distroless `nonroot` user (UID 65532) | A container process is a host process; do not make it root. Numeric IDs matter: Kubernetes' `runAsNonRoot` can only verify a *numeric* UID |
| `ENTRYPOINT ["/pinboard-api"]` | **Exec form** (JSON array) | The binary becomes PID 1 and receives SIGTERM directly — graceful shutdown works. Shell form would put `/bin/sh` in the way (and distroless has no shell at all) |

Build version `1.0`:

```bash
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 .
```

```text
[+] Building 44.1s (16/16) FINISHED                                      docker:default
 => [internal] load build definition from Dockerfile                               0.0s
 => resolve image config for docker-image://docker.io/docker/dockerfile:1          1.3s
 => docker-image://docker.io/docker/dockerfile:1@sha256:9e2c9eca7367393aecc6…      0.9s
 => [internal] load metadata for gcr.io/distroless/static-debian12:nonroot         1.0s
 => [internal] load metadata for docker.io/library/golang:1.25-alpine              0.8s
 => [internal] load .dockerignore                                                  0.0s
 => [build 1/6] FROM docker.io/library/golang:1.25-alpine@sha256:8a1f2e3c4d5b…     0.0s
 => [runtime 1/2] FROM gcr.io/distroless/static-debian12:nonroot@sha256:6f2c…      1.4s
 => [internal] load build context                                                  0.0s
 => => transferring context: 15.98kB                                               0.0s
 => [build 2/6] WORKDIR /src                                                       0.1s
 => [build 3/6] COPY go.mod go.sum ./                                              0.0s
 => [build 4/6] RUN --mount=type=cache,target=/go/pkg/mod go mod download          8.7s
 => [build 5/6] COPY . .                                                           0.0s
 => [build 6/6] RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,…    28.2s
 => [runtime 2/2] COPY --from=build /out/pinboard-api /pinboard-api                0.2s
 => exporting to image                                                             0.4s
 => => writing image sha256:0f7a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70       0.0s
 => => naming to docker.io/library/pinboard-api:1.0                                0.0s
```

### Step 05: Compare the two images

```bash
docker image ls pinboard-api
```

```text
REPOSITORY     TAG      IMAGE ID       CREATED          SIZE
pinboard-api   1.0      0f7a2b3c4d5e   30 seconds ago   12.8MB
pinboard-api   naive    3a9c7e12b04f   6 minutes ago    412MB
```

**412 MB → 12.8 MB**, same program, same source, one Dockerfile. Look at what is
left:

```bash
docker history pinboard-api:1.0
```

```text
IMAGE          CREATED          CREATED BY                                      SIZE      COMMENT
0f7a2b3c4d5e   1 minute ago     ENTRYPOINT ["/pinboard-api"]                    0B        buildkit.dockerfile.v0
<missing>      1 minute ago     USER 65532:65532                                0B        buildkit.dockerfile.v0
<missing>      1 minute ago     EXPOSE map[8080/tcp:{}]                         0B        buildkit.dockerfile.v0
<missing>      1 minute ago     COPY /out/pinboard-api /pinboard-api # buil…    10.4MB    buildkit.dockerfile.v0
<missing>      1 minute ago     ENV PORT=8080 APP_VERSION=1.0                   0B        buildkit.dockerfile.v0
<missing>      1 minute ago     LABEL org.opencontainers.image.title=pinbo…     0B        buildkit.dockerfile.v0
<missing>      1 minute ago     ARG APP_VERSION=dev                             0B        buildkit.dockerfile.v0
<missing>      3 weeks ago      /bin/sh -c #(nop) USER nonroot:nonroot          0B
<missing>      3 weeks ago      ...distroless base (ca-certificates, tzdata…    2.4MB
```

Your binary (10.4 MB) plus 2.4 MB of base. Nothing else. Note the `build` stage does
not appear at all — it was never part of this image.

Now read the metadata you set, without opening the JSON:

```bash
docker image inspect pinboard-api:1.0 --format '{{.Config.User}}'
docker image inspect pinboard-api:1.0 --format '{{json .Config.Entrypoint}}'
docker image inspect pinboard-api:1.0 --format '{{json .Config.Env}}'
docker image inspect pinboard-api:1.0 --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
docker image inspect pinboard-api:1.0 --format '{{.Os}}/{{.Architecture}} · {{len .RootFS.Layers}} layers'
```

```text
65532:65532
["/pinboard-api"]
["PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin","SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt","PORT=8080","APP_VERSION=1.0"]
1.0
linux/amd64 · 3 layers
```

<details>
<summary><strong>Check yourself:</strong> <code>ARG APP_VERSION</code> is declared in <em>both</em> stages. Why not just once?</summary>

An `ARG` is scoped to the stage it is declared in (only `ARG`s before the first
`FROM` are global, and even then they must be re-declared to be used). The `build`
stage needs it to stamp the binary with `-ldflags -X`; the `runtime` stage needs it
independently for the OCI `version` label and the `APP_VERSION` env default. Drop
either declaration and you silently get `dev` in that half of the image — a great
way to ship an image that lies about its own version.
</details>

### Step 06: Run the API and call it

Run it in the foreground so you can watch the logs, publish 8080, and override the
theme with `-e`:

```bash
docker run --rm -p 8080:8080 -e APP_THEME=amber --name pinboard-api pinboard-api:1.0
```

```text
time=2026-08-20T10:21:44.102Z level=WARN msg="DATABASE_URL not set — using in-memory store, notes will be lost on restart"
time=2026-08-20T10:21:44.103Z level=INFO msg="pinboard-api starting" version=1.0 theme=amber store=memory addr=:8080 hostname=7f2c9d1e4a63
```

In a **second terminal**, talk to it:

```bash
curl -s http://localhost:8080/api/info | jq
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/
```

```text
{
  "app": "pinboard-api",
  "greeting": "Welcome to Pinboard",
  "hostname": "7f2c9d1e4a63",
  "store": "memory",
  "theme": "amber",
  "uptime": "35s",
  "version": "1.0"
}
ok
Pinboard API 1.0 on 7f2c9d1e4a63 (store: memory)
```

`"version": "1.0"` is the build arg you passed; `"theme": "amber"` is the `-e` flag;
`"store": "memory"` is what you get with no `DATABASE_URL` — Lab 03 changes that.
Pin a note and read it back:

```bash
curl -s -X POST http://localhost:8080/api/notes \
  -H 'content-type: application/json' \
  -d '{"text":"built my first multi-stage image","author":"me"}'
curl -s http://localhost:8080/api/notes | jq -c '.[]'
```

```text
{"id":1,"text":"built my first multi-stage image","author":"me","createdAt":"2026-08-20T10:22:31.884Z"}
{"id":1,"text":"built my first multi-stage image","author":"me","createdAt":"2026-08-20T10:22:31.884Z"}
```

Try to get a shell inside it — this **must** fail:

```bash
docker exec -it pinboard-api sh
```

```text
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH: unknown
```

> **Note.** There is no shell in a distroless image, on purpose: nothing for an
> attacker to pivot with, and a much smaller scanner report. The price is that
> `docker exec`-style debugging does not work — in Session 09 you will learn the
> Kubernetes answer, `kubectl debug` with an ephemeral container.

Back in the first terminal, press `Ctrl+C` and watch the graceful shutdown that the
`ENTRYPOINT` exec form makes possible:

```text
^Ctime=2026-08-20T10:24:02.551Z level=INFO msg="signal received, shutting down gracefully" grace=10s
time=2026-08-20T10:24:02.552Z level=INFO msg="bye"
```

The container removed itself (`--rm`), and your note is gone with it — the in-memory
store lives and dies with the process.

### Step 07: Build `1.1` and `1.2-broken`

Version `1.1` is the *same source*, built with a different build argument. This is
what makes the rolling-update demo in Session 06 honest — two genuinely different
images, one code base.

```bash
docker build -t pinboard-api:1.1 --build-arg APP_VERSION=1.1 .
docker image inspect pinboard-api:1.1 --format '{{index .Config.Labels "org.opencontainers.image.version"}}'
docker run --rm -d -p 8081:8080 --name api11 pinboard-api:1.1 && sleep 1
curl -s http://localhost:8081/ ; docker stop api11
```

```text
1.1
1c4d8e0b7f32a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4
Pinboard API 1.1 on 1c4d8e0b7f32 (store: memory)
api11
```

Now the deliberately broken one, `1.2-broken`, used for the rollback exercise in
Lab 06. The API crashes on start when `CRASH_ON_START=true`.

> **Warning.** You **cannot** produce this with `--build-arg CRASH_ON_START=true`.
> Build args are build-time only and the Dockerfile never declares that `ARG`, so
> the value would be ignored (BuildKit would even warn: `[Warning] One or more
> build-args were not consumed`). Only `ENV` puts a variable into the *running*
> container's environment.

Create `Dockerfile.broken`:

```dockerfile
FROM pinboard-api:1.0
ENV CRASH_ON_START=true
```

Two lines, and the base is your own local image — no rebuild, no compiler, just one
extra metadata layer:

```bash
docker build -f Dockerfile.broken -t pinboard-api:1.2-broken .
docker run --rm pinboard-api:1.2-broken; echo "exit code: $?"
```

```text
time=2026-08-20T10:29:18.774Z level=ERROR msg="CRASH_ON_START is set — exiting with status 1 (this is on purpose)"
exit code: 1
```

A container that exits non-zero immediately is exactly what `CrashLoopBackOff` looks
like in Kubernetes. Keep this tag; Lab 06 rolls it out and rolls it back.

### Step 08: Build `pinboard-web:1.0`

The web tier is static files served by nginx, with `/api/` proxied to the API. Its
Dockerfile needs `html/` and `nginx/` next to it, so build it straight from the repo
folder — the last argument of `docker build` is the context, and it does not have to
be `.`:

```bash
docker build -t pinboard-web:1.0 ~/docker-kubernetes-training/src/pinboard-web
```

```text
[+] Building 6.9s (12/12) FINISHED                                       docker:default
 => [internal] load build definition from Dockerfile                               0.0s
 => [internal] load metadata for docker.io/library/nginx:1.28-alpine               0.9s
 => [1/6] FROM docker.io/library/nginx:1.28-alpine@sha256:b4d0c2f1e7a3…            2.1s
 => [2/6] RUN rm /etc/nginx/conf.d/default.conf                                    0.3s
 => [3/6] COPY nginx/default.conf.template /etc/nginx/templates/default.conf.…     0.0s
 => [4/6] COPY --chmod=0755 nginx/10-resolver.envsh /docker-entrypoint.d/10-res…  0.0s
 => [5/6] COPY html/ /usr/share/nginx/html/                                        0.0s
 => [6/6] RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx/…    0.4s
 => exporting to image                                                             0.3s
 => => naming to docker.io/library/pinboard-web:1.0                                0.0s
```

Read three things out of that image — they explain how it behaves in every later lab:

```bash
docker image inspect pinboard-web:1.0 --format '{{.Config.User}} · {{json .Config.ExposedPorts}}'
docker image inspect pinboard-web:1.0 --format '{{json .Config.Env}}'
docker image inspect pinboard-web:1.0 --format '{{json .Config.Healthcheck.Test}}'
```

```text
101:101 · {"8080/tcp":{}}
["PATH=/usr/local/sbin:...","NGINX_VERSION=1.28.0","API_URL=http://api:8080","NGINX_ENTRYPOINT_QUIET_LOGS=1"]
["CMD-SHELL","wget -qO- http://127.0.0.1:8080/healthz || exit 1"]
```

- It runs as **UID 101** (the image's `nginx` user), not root — which is why it listens
  on **8080**, not 80 (ports below 1024 need privileges). The Dockerfile writes the
  numeric form `USER 101:101`, which is also what Kubernetes' `runAsNonRoot` can verify
  (Lab 08 sets `runAsUser: 101` for exactly this reason).
- **`API_URL`** is a plain environment variable: the official nginx image renders
  `/etc/nginx/templates/*.template` with `envsubst` at start-up, so you re-point the
  proxy with `-e API_URL=...` and no rebuild. Lab 03 uses that.
- It declares a **`HEALTHCHECK`**, so `docker ps` will show a HEALTH column for it.

Don't run it yet — on its own it has no API to proxy to. That is Lab 03, one step away.

### Step 09: Layer caching and `.dockerignore`

Back in `~/pinboard-labs/lab02/pinboard-api`, simulate a code change and rebuild. Append
a line — `touch` would not do: BuildKit keys `COPY` on file *content*, not timestamps:

```bash
echo '// a code change' >> main.go
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 .
```

```text
[+] Building 24.8s (16/16) FINISHED                                      docker:default
 => CACHED [build 2/6] WORKDIR /src                                                0.0s
 => CACHED [build 3/6] COPY go.mod go.sum ./                                       0.0s
 => CACHED [build 4/6] RUN --mount=type=cache,target=/go/pkg/mod go mod download   0.0s
 => [build 5/6] COPY . .                                                           0.0s
 => [build 6/6] RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,…    21.4s
 => [runtime 2/2] COPY --from=build /out/pinboard-api /pinboard-api                0.2s
 => => naming to docker.io/library/pinboard-api:1.0                                0.0s
```

The dependency download is `CACHED`; only the compile re-ran (and even that was fast,
thanks to the `--mount=type=cache` build cache). Had you written `COPY . .` before
`go mod download`, every one-character edit would re-download every module. **That is
the whole instruction-ordering rule: least-changing first.**

Now the build context. Watch the `transferring context` line — everything in the
folder is sent to the builder, whether the Dockerfile uses it or not:

```bash
mkdir -p notes && dd if=/dev/urandom of=notes/scratch.bin bs=1M count=25 status=none
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 . 2>&1 | grep -A1 'load build context'
```

```text
 => [internal] load build context                                                  0.6s
 => => transferring context: 26.23MB                                               0.5s
```

26 MB uploaded for nothing — and because `COPY . .` copied the junk file, the build
cache was invalidated too. Create `.dockerignore`:

```text
# Everything the build does not need. Same syntax as .gitignore.
.git
.gitignore
.dockerignore
Dockerfile*
*.md
notes/
out/
# never ship credentials, even by accident
.env
*.pem
*.key
```

Rebuild and compare:

```bash
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 . 2>&1 | grep -A1 'load build context'
rm -rf notes
```

```text
 => [internal] load build context                                                  0.0s
 => => transferring context: 15.98kB                                               0.0s
```

> **Note.** `.dockerignore` does three jobs at once: it makes builds faster, it keeps
> the cache stable (an edited `README.md` no longer busts `COPY . .`), and it stops
> secrets and `.git` history from being baked into a layer that anybody who pulls the
> image can extract.

### Step 10 (optional): Publish to Docker Hub

Skip this if you have no Docker Hub account — **no later lab needs it**. From Session
05 on, images go into the kind cluster with `kind load docker-image`, precisely so
the course does not depend on a registry.

An image name carries its destination, so publishing means *renaming* first. Replace
`<DOCKER_ID>` with your Docker Hub user name everywhere below:

```bash
docker login
```

```text
Username: <DOCKER_ID>
Password:
Login Succeeded
```

```bash
docker tag pinboard-api:1.0 <DOCKER_ID>/pinboard-api:1.0
docker image ls | grep pinboard-api
docker push <DOCKER_ID>/pinboard-api:1.0
```

```text
<DOCKER_ID>/pinboard-api   1.0   0f7a2b3c4d5e   12 minutes ago   12.8MB
pinboard-api               1.0   0f7a2b3c4d5e   12 minutes ago   12.8MB
The push refers to repository [docker.io/<DOCKER_ID>/pinboard-api]
b1f2a3c4d5e6: Pushed
9a8b7c6d5e4f: Mounted from library/distroless
1.0: digest: sha256:4d3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c size: 946
```

The two names share one **image ID**: a tag is a label on content, not a copy.

If your Docker Desktop/CLI ships Docker Scout, get a vulnerability summary of what you
just published:

```bash
docker scout quickview <DOCKER_ID>/pinboard-api:1.0
```

```text
    ✓ Image stored for indexing
    ✓ Indexed 2 packages

  Target             │  <DOCKER_ID>/pinboard-api:1.0  │    0C     0H     0M     0L
    digest           │  4d3c2b1a0f9e                  │
  Base image         │  distroless/static-debian12    │    0C     0H     0M     0L
```

Zero findings, because there is almost nothing in the image to find. Run the same
command against `pinboard-api:naive` for a much longer list — that is the security
argument for small base images, in one screen.

> **Note.** `docker scout` may not be installed on a plain Docker Engine
> (`docker: 'scout' is not a docker command`). That is fine — skip it; nothing
> later depends on it.

## Stretch goal

> **Optional — only if you finish early.** Nothing in Lab 03 depends on these exercises,
> so skip them freely. If you do one, follow its clean-up so the next lab starts from
> the expected state.

1. **Stop at a stage.** `docker build --target build -t pinboard-api:builder .`
   builds only the first stage. Run `docker run --rm -it pinboard-api:builder sh`
   and look at `/out/pinboard-api` and the Go toolchain that never ships. Handy in
   CI for running tests in the build stage.
2. **Multi-platform.** This needs a `docker-container` builder. Create one **without**
   `--use` — `--use` would make every later plain `docker build` run on it and stop
   loading images into your local store, which breaks the next labs:

   ```bash
   docker buildx create --name multi --driver docker-container --bootstrap
   docker buildx build --builder multi --platform linux/amd64,linux/arm64 \
     -t pinboard-api:1.0-multi -o type=oci,dest=../pinboard-api-multi.oci.tar .
   tar tf ../pinboard-api-multi.oci.tar | head
   ```

   The result is an **index** (manifest list) pointing at one image per architecture.
   Expect the arm64 half to be slow: this Dockerfile compiles it under QEMU emulation
   (`exec format error` → run `docker run --privileged --rm tonistiigi/binfmt --install arm64` once).
3. **Attestations.** Add `--sbom=true --provenance=true` to the same command (the default
   `docker` builder refuses attestations on the classic image store). If you did Step 10,
   push instead of exporting (`-t <DOCKER_ID>/pinboard-api:1.0-attested --push`) and run
   `docker buildx imagetools inspect <DOCKER_ID>/pinboard-api:1.0-attested`.
   Supply-chain metadata for free.
4. **Make it worse, then better.** Add `RUN apk add --no-cache curl` to the *runtime*
   stage — it will fail, because distroless has no `apk` and no shell. Then think
   about what you actually lose by having no package manager in production.

## Conclusion

**What you have now**

```bash
docker image ls 'pinboard-*'
```

```text
REPOSITORY     TAG          IMAGE ID       CREATED          SIZE
pinboard-api   1.0          0f7a2b3c4d5e   14 minutes ago   12.8MB
pinboard-api   1.1          5e6f7a8b9c0d   9 minutes ago    12.8MB
pinboard-api   1.2-broken   7a8b9c0d1e2f   6 minutes ago    12.8MB
pinboard-web   1.0          2b3c4d5e6f70   4 minutes ago    58.4MB
pinboard-api   naive        3a9c7e12b04f   22 minutes ago   412MB
```

> **Warning.** These four images — `pinboard-api:1.0`, `pinboard-api:1.1`,
> `pinboard-api:1.2-broken` and `pinboard-web:1.0` — are **needed by every lab from
> here to the capstone**. Do not `docker image prune -a`, and do not rebuild your lab
> VM without re-running this lab. If you ever lose them:
> `bash ~/docker-kubernetes-training/labs/extras/build-all.sh` rebuilds all four.

You can drop the oversized experiment, though:

```bash
docker image rm pinboard-api:naive
```

You also learned to read an image (`ls`, `history`, `inspect --format`), to keep the
build cache on your side, and to keep junk out of the context with `.dockerignore`.

Next: **[Lab 03 – Wire Pinboard together by hand](lab03.md)** — a network, a named
volume, and all three tiers talking to each other for the first time.
