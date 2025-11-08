# Sevault – Minimal NFS Volume Driver

Sevault is a tiny Docker volume plugin that turns an existing NFS export into a Docker-managed volume. The current codebase intentionally keeps the feature set small so it is easy to audit and hack on—only NFS is supported, there is no clustering logic, and the plugin stores nothing beyond mountpoints.

## What You Get
- Single static binary (`sevaultd`) compiled with Go 1.22
- Works anywhere Docker can run managed plugins
- Only two required inputs when creating a volume: `host` and `export`

## Build the Binary
```bash
CGO_ENABLED=0 go build -o sevaultd ./cmd/sevaultd
```

## Package the Docker Plugin
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

## Install & Enable
```bash
cd sevault-plugin
docker plugin create sevault .
docker plugin enable sevault
```

## Use the Driver
```bash
docker volume create -d sevault \
  --name data \
  -o host=192.168.1.10 \
  -o export=/srv/share \
  -o vers=4 \
  -o ro=false

docker run -it --rm -v data:/mnt alpine ls /mnt
```

### Supported Volume Options
| Option  | Required | Description |
| ------- | -------- | ----------- |
| `host`  | ✅ | IPv4/IPv6 address or hostname of the NFS server. |
| `export`| ✅ | Export path on the server (e.g. `/srv/share`). |
| `vers`  | ❌ | NFS protocol version, defaults to `4`. |
| `ro`    | ❌ | When set to `true`, Sevault mounts the export read-only. |
| `options` | ❌ | Comma separated string passed straight to `mount.nfs`. |

All volumes mount under `/var/lib/sevault/mounts/<name>` on the host, and Docker bind-mounts that path into containers as needed.

## Development Tips
- Run `GOCACHE=$(pwd)/.gocache go test ./...` if your environment blocks writes to the default Go build cache.
- `test-plugin.sh` provisions a throwaway NFS server, packages the plugin, installs it locally, and runs a quick end-to-end check.
