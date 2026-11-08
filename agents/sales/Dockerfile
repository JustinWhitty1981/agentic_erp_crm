# The sales and procurement agent: React UI, Go backend, one image. The build is the same three
# stages as its two siblings because it is the same program with a different domain package.
#
# Three stages, and the second one is where the interesting part of this build lives.

# Stage 1: the UI.
FROM node:20-alpine AS frontend-builder
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install
COPY frontend/ ./
RUN npm run build

# Stage 2: the Go binary.
FROM golang:1.23-alpine AS backend-builder

WORKDIR /app/backend_go

# The module cache is warmed before the sources are copied, so editing a .go file does not re-download
# pgx. This is also where the dependencies are resolved rather than vendored: go.sum is in the
# repository and the proxy is reachable, and a vendor/ directory that drifted from go.sum is a build
# that fails in a way nothing explains.
COPY backend_go/go.mod backend_go/go.sum ./
RUN go mod download

COPY backend_go/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /jada-server ./cmd/server/main.go

# Stage 3: the runtime.
FROM alpine:latest

WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata wget

# `go build` above produced a static binary, so nothing else from the toolchain is needed and the
# compiler does not belong in an image that runs on a server.
COPY --from=backend-builder /jada-server /app/jada-server
COPY --from=frontend-builder /app/backend_go/static /app/static

# The CA for the database connection is NOT copied into the image. It is bind-mounted by
# docker-compose.yml from dev/tls/, because `scripts/db/init.sh` re-exports it from the container each
# time it provisions - and an image carrying its own copy would keep trusting an authority that no
# longer exists.
#
# That means sslmode=verify-full requires the mount, and the error you get without it is
# "certificate signed by unknown authority" - which reads like a network fault and is not one. The
# binary says so in its own words at startup; see pkg/db's tlsConfig.

# No memory_store directory is created, because MEMORY_DRIVER=db writes what the agent remembers into
# agent_memories. A directory here would suggest the file store is still the deployment's state.

ENV HOST=0.0.0.0
ENV PORT=8000
# The container's trust store, for the model server's TLS if it ever has any. The database does not
# use it: it has AFPC_PG_SSLROOTCERT, which points at the mounted CA.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

EXPOSE 8000

# The binary exits on SIGTERM after draining in-flight turns, so a `docker stop` finishes the
# conversation it is in the middle of rather than cutting it. init(1)-style signal forwarding is not
# needed because the process is the direct CMD.
STOPSIGNAL SIGTERM

CMD ["/app/jada-server"]
