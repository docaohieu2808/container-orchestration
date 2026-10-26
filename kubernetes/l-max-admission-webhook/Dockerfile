# Build stage: static binary, no cgo.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/webhook-server .

# Runtime stage: distroless static, non-root (8443 needs no privileges).
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/webhook-server /webhook-server
USER 65532:65532
ENTRYPOINT ["/webhook-server"]
