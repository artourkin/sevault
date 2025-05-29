# Sevault – Docker‑Native Remote Volume Driver

> **Version 0.1 (May 2025)** – Apache‑2.0

Sevault is a lightweight **Docker Volume Plugin** that turns ordinary **NFS v3/v4** and **SMB 3.x (CIFS)** shares into first‑class Docker volumes with automatic re‑mounting and zero Kubernetes dependence.

* **Single static binary** (`sevaultd`, ≈ 7 MB)
* **Managed‑plugin install** (`docker plugin install …`)
* Works with *docker run*, *Docker Compose*, and *Swarm*
* Persists metadata in a tiny BoltDB file (`/var/lib/sevault/state.db`)
* Soft‑mount options (`vers=4,soft,timeo=30`) provide graceful NAS outages

---

## 1  Architecture (host view)

```
               ┌──────────────────────────────────────────┐
               │              Remote Storage             │
               │  NFS v4 or SMB 3.x server on LAN/WAN     │
               └───────────────▲──────────▲──────────────┘
                               │          │ (TCP 2049 / 445)
                               │          │
        docker.volumedriver ⇢  │          │  ⇠  kernel NFS/SMB client
/run/docker/plugins/sevault.sock
┌────────────────────────┐ socket JSON calls  ┌────────────────────────┐
│        Dockerd         │───────────────────▶│      sevaultd          │
│  (volume lifecycle)    │   Create/Mount     │  (plugin container)    │
└───────────┬────────────┘                   └──────────┬─────────────┘
            │  bind‑mount /var/lib/sevault/mounts/VOL   │ executes
            │                                           │   mount(8)
     ┌──────▼───────┐                                  │
     │  Container   │  ⇠ bind ⇢ /var/lib/sevault/… ────┘
     │   (app)      │
     └──────────────┘
```

### Component table

| Abbrev         | Process/Binary                                              | Purpose                                                                     |
| -------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------- |
| **dockerd**    | Docker Engine                                               | Calls the VolumeDriver API on every `create`, `mount`, `unmount`, `remove`. |
| **sevaultd**   | Static Go binary running **inside a managed‑plugin rootfs** | Implements the API, stores metadata, executes `mount.nfs`/`mount.cifs`.     |
| **Remote NAS** | Any NFS/SMB server (containerised or hardware)              | Stores the actual data blocks.                                              |

---

## 2  Main logic flow

1. **Install plugin** once per host

   ```bash
   docker plugin install \
     --alias sevault \
     --grant-all-permissions \
     docker.io/<user>/sevault-plugin:v0.1.0
   ```
2. **Create a volume** (metadata only)

   ```bash
   docker volume create -d sevault \
     -o host=192.168.1.100 \
     -o export=/srv/projects \
     -o vers=4 \
     projectdata
   ```

   *Sevault* stores the option map and makes an empty mount‑point directory.
3. **Run container / Compose up** → Dockerd issues **Mount**.
   *Sevault* executes:
   `mount -t nfs -o vers=4,soft,timeo=30 192.168.1.100:/srv/projects /var/lib/sevault/mounts/projectdata`
4. Kernel VFS serves I/O; *sevaultd* is **not** in the data path.
5. **Unmount** on container stop, **Remove** on `docker volume rm`.

---

## 3  Quick start with Compose demo

**infra‑stack.yml** (local NFS server)

```yaml
version: "3.9"
services:
  nfs-server:
    image: itsthenetwork/nfs-server-alpine:latest
    privileged: true
    network_mode: host
    environment:
      - SHARED_DIRECTORY=/srv/nfsdata
    volumes:
      - /srv/nfsdata:/srv/nfsdata
```

**app‑stack.yml** (Nginx + BusyBox client)

```yaml
version: "3.9"
services:
  web:
    image: nginx:1.27-alpine
    ports: ["8080:80"]
    volumes: [nfsdata:/usr/share/nginx/html:ro]
  client:
    image: busybox:1.36
    command: ["sh","-c","while true; do ls /data; sleep 5; done"]
    volumes: [nfsdata:/data]
volumes:
  nfsdata:
    driver: sevault
    driver_opts:
      host: 127.0.0.1
      export: /srv/nfsdata
      vers: "4"
```

```bash
# 1) start NFS service
sudo mkdir -p /srv/nfsdata && echo hello > /srv/nfsdata/index.html
docker compose -f infra-stack.yml up -d
# 2) launch workload stack
docker compose -f app-stack.yml up -d
```

Point browser to [**http://localhost:8080**](http://localhost:8080) and watch `docker logs -f client` – both containers see the same NFS share through Sevault.

---

## 4  Feature roadmap (summary)

| Phase | Planned feature                                            |
| ----- | ---------------------------------------------------------- |
|  v0.2 | Web‑UI & REST on :8777 (volume list, metrics, logs)        |
|  v0.3 | SFTP backend via `sshfs` adapter                           |
|  v0.4 | S3/MinIO backend via `rclone mount --vfs-cache-mode write` |
|  v0.5 | Multi‑node lock‑manager & volume replication               |

---

## 5  Project status & license

* **Status**: MVP ready for LAN production workloads (databases, CMS, CI caches).
* **License**: Apache 2.0.  Contributions welcome via pull requests.

---

*Generated 2025‑05‑29.  This README is canonical—embed as‑is when sharing Sevault with other LLMs or documentation systems.*
