# The inventory agent: Go backend, React UI, one image. Same three stages as
# agents/customer_service/Dockerfile - the UI was copied rather than rewritten because it is the
# same loop behind the same SSE contract, and four identity strings are the whole difference.
#
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

# The module cache is warmed before the sources are copied, so editing a .go file does not
# re-download pgx. Dependencies are resolved rather than vendored for the same reasons the
# customer service agent's file states; go.sum is this module's own, and it happens to be
# identical because the code base is - this image and that one are two binaries of one lineage.
COPY backend_go/go.mod backend_go/go.sum ./
RUN go mod download

COPY backend_go/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /jada-server ./cmd/server/main.go

# Stage 3: the runtime.
FROM alpine:latest

WORKDIR /app

RUN apk --no-cache add ca-certificates tzdata wget

COPY --from=backend-builder /jada-server /app/jada-server
COPY --from=frontend-builder /app/backend_go/static /app/static

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
