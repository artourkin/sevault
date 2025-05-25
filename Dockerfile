# Dockerfile for Sevault plugin
FROM golang:1.21-alpine as builder
WORKDIR /app
COPY . .
RUN go build -o rvsd ./cmd/rvsd

FROM alpine:3.19
WORKDIR /app
COPY --from=builder /app/rvsd ./rvsd
ENTRYPOINT ["./rvsd"]
