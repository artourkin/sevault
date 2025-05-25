FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /bin/sevaultd ./cmd/sevaultd

FROM alpine:3.20
RUN apk add --no-cache nfs-utils
COPY --from=build /bin/sevaultd /usr/bin/sevaultd
ENTRYPOINT ["/usr/bin/sevaultd", "nfs"]