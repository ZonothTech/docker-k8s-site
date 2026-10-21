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
