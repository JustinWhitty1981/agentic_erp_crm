# The inventory agent: Go backend and the schedule, one image, no UI.
#
# Two stages, and the shape of the Go one is copied from agents/customer_service/Dockerfile on
# purpose - module cache warmed before sources, static binary, no toolchain in the runtime. The
# third stage that file has (the React build) is absent because this agent is answered through
# the same chat endpoints and has no page of its own; pickStatic finds no directory and the root
# route degrades to the JSON service note, which is behaviour the backend already had.

# Stage 1: the Go binary.
FROM golang:1.23-alpine AS backend-builder

WORKDIR /app/backend_go

# The module cache is warmed before the sources are copied, so editing a .go file does not
# re-download pgx. Dependencies are resolved rather than vendored for the same reasons the
# customer service agent's file states; go.sum is this module's own, and it happens to be
# identical because the code base is - this image and that one are two binaries of one lineage.
COPY backend_go/go.mod backend_go/go.sum ./
RUN go mod download

COPY backend_go/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /jada-server ./cmd/server/main.go

# Stage 2: the runtime.
FROM alpine:latest

WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata wget

COPY --from=backend-builder /jada-server /app/jada-server

# The CA is bind-mounted by docker-compose.yml from dev/tls/, not baked in, for the customer
# service agent's stated reason: init.sh re-exports it on every provision, and a stale copy in
# an image keeps validating a dead authority.

ENV HOST=0.0.0.0
ENV PORT=8000
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

EXPOSE 8000

# SIGTERM drains in-flight turns; the timer goroutine dies with the process, and a tick is
# idempotent by design, so a stop between "scan" and "record" costs nothing a retry would not.
STOPSIGNAL SIGTERM

CMD ["/app/jada-server"]
