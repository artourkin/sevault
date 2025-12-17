---
layout: default
title: Sevault – Minimal NFS Volume Driver
description: Ship a minimal Docker volume plugin that turns an existing NFS export into a Docker-managed volume.
---

# Sevault

Sevault is a tiny Docker volume plugin that turns an existing NFS export into a Docker-managed volume. The feature set stays intentionally small so it is easy to audit and hack on—only NFS is supported, there is no clustering logic, and the plugin stores nothing beyond mountpoints.

## What you get
- Single static binary (`sevaultd`) compiled with Go 1.22.
- Works anywhere Docker can run managed plugins.
- Only two required inputs when creating a volume: `host` and `export`.

## Build the binary
```bash
CGO_ENABLED=0 go build -o sevaultd ./cmd/sevaultd
```

## Package the Docker plugin
Use the provided multi-stage Dockerfile to assemble a root filesystem that contains the Sevault binary and the kernel `mount.nfs` helper:
```bash
docker build -t sevault-plugin-builder -f Dockerfile.plugin .
mkdir -p sevault-plugin/rootfs
docker container create --name sevault-plugin-stage sevault-plugin-builder
docker container export sevault-plugin-stage | tar -x -C sevault-plugin/rootfs
docker container rm sevault-plugin-stage
cp plugin-config.json sevault-plugin/config.json
```

You now have a plugin package with this shape:
```
sevault-plugin/
├── config.json
└── rootfs/
    ├── sevaultd
    └── sbin/mount.nfs
```

## Install and enable
```bash
cd sevault-plugin
docker plugin create sevault .
docker plugin enable sevault
```

## Create and use a volume
```bash
docker volume create -d sevault \
  --name data \
  -o host=192.168.1.10 \
  -o export=/srv/share \
  -o vers=4 \
  -o ro=false

docker run -it --rm -v data:/mnt alpine ls /mnt
```

### Supported volume options
| Option    | Required | Description |
| --------- | -------- | ----------- |
| `host`    | ✅ | IPv4/IPv6 address or hostname of the NFS server. |
| `export`  | ✅ | Export path on the server (e.g. `/srv/share`). |
| `vers`    | ❌ | NFS protocol version, defaults to `4`. |
| `ro`      | ❌ | When set to `true`, Sevault mounts the export read-only. |
| `options` | ❌ | Comma separated string passed straight to `mount.nfs`. |

All volumes mount under `/var/lib/sevault/mounts/<name>` on the host, and Docker bind-mounts that path into containers as needed.

## WebUI (optional)
The Web UI lists, creates, and deletes Sevault volumes through the Docker API.

### Run on the host
```bash
CGO_ENABLED=0 go build -o webui ./cmd/webui
PLUGIN_NAME=sevault WEBUI_ADDR=:8080 ./webui
# open http://localhost:8080
```

### Run in Docker
```bash
docker build -t sevault-webui -f Dockerfile.webui .
docker run --rm \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e PLUGIN_NAME=sevault \
  sevault-webui
# open http://localhost:8080
```

Notes:
- The Web UI needs access to the Docker API socket to manage volumes.
- It only manages volumes for the configured driver (`PLUGIN_NAME`, default `sevault`).

## Development tips
- Run `GOCACHE=$(pwd)/.gocache go test ./...` if your environment blocks writes to the default Go build cache.
- `test-plugin.sh` provisions a throwaway NFS server, packages the plugin, installs it locally, and runs a quick end-to-end check.
