#!/usr/bin/env bash
# =============================================================================
# Build every Pinboard image the rest of the course needs (what Lab 02 builds):
#
#     pinboard-api:1.0          multi-stage, distroless, non-root  (~13 MB)
#     pinboard-api:1.1          same source, APP_VERSION=1.1       (rollouts)
#     pinboard-api:1.2-broken   1.0 + ENV CRASH_ON_START=true      (rollback)
#     pinboard-web:1.0          nginx 1.28-alpine, non-root, :8080
#
# Use it to recover after a rebuilt VM or a too-enthusiastic `docker image prune`:
#
#     bash ~/docker-kubernetes-training/labs/extras/build-all.sh
#
# Add --naive to also build the 412 MB single-stage image for comparison.
# =============================================================================
set -euo pipefail

REPO="${REPO:-$HOME/docker-kubernetes-training}"
API_SRC="${REPO}/src/pinboard-api"
WEB_SRC="${REPO}/src/pinboard-web"

[[ -d "${API_SRC}" ]] || { echo "cannot find ${API_SRC} — set REPO=/path/to/repo" >&2; exit 1; }

echo "==> pinboard-api:1.0"
docker build -t pinboard-api:1.0 --build-arg APP_VERSION=1.0 "${API_SRC}"

echo "==> pinboard-api:1.1"
docker build -t pinboard-api:1.1 --build-arg APP_VERSION=1.1 "${API_SRC}"

# Lab 02 Step 07: only ENV reaches the running container (a --build-arg would not).
echo "==> pinboard-api:1.2-broken"
docker build -t pinboard-api:1.2-broken - <<'DOCKERFILE'
FROM pinboard-api:1.0
ENV CRASH_ON_START=true
DOCKERFILE

echo "==> pinboard-web:1.0"
docker build -t pinboard-web:1.0 "${WEB_SRC}"

if [[ "${1:-}" == "--naive" ]]; then
  # Lab 02 Step 02: the "before" picture — Go toolchain, sources and root in the image.
  echo "==> pinboard-api:naive (single stage, for the size comparison)"
  docker build -t pinboard-api:naive -f - "${API_SRC}" <<'DOCKERFILE'
FROM golang:1.25-alpine
WORKDIR /src
COPY . .
ENV CGO_ENABLED=0
RUN go build -o /pinboard-api .
EXPOSE 8080
CMD ["/pinboard-api"]
DOCKERFILE
fi

echo
docker image ls 'pinboard-*'
