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

## 2  Docker Plugin: Build, Install, Use

This section provides detailed instructions for building the Sevault Docker plugin from source, installing it, and using it to manage volumes.

### 2.1 Building the Plugin

The plugin is defined by `Dockerfile.plugin` (which assembles the root filesystem) and `plugin-config.json` (which provides metadata to Docker).

**Steps to build the plugin package:**

1.  **Build the `sevaultd` Go binary:**
    This binary is the core of the plugin.
    ```bash
    CGO_ENABLED=0 go build -o sevaultd ./cmd/sevaultd
    ```

2.  **Prepare the plugin rootfs using `Dockerfile.plugin`:**
    This step creates a temporary Docker image from `Dockerfile.plugin` and then extracts its contents to a local directory which will serve as the plugin's root filesystem.
    ```bash
    # Create a temporary builder image
    docker build -t sevault-plugin-builder -f Dockerfile.plugin .

    # Create an empty directory for the rootfs
    mkdir -p plugin-rootfs

    # Extract the contents from the builder image
    docker container create --name temp_sevault_plugin sevault-plugin-builder
    docker container export temp_sevault_plugin | tar -x -C plugin-rootfs
    docker container rm temp_sevault_plugin
    ```
    The `plugin-rootfs` directory now contains the `sevaultd` binary and the necessary mount helpers (`mount.nfs`, `mount.cifs`).

3.  **Assemble the plugin package:**
    Docker requires a specific directory structure for plugin creation: a main directory containing `config.json` and a subdirectory named `rootfs`.
    ```bash
    # Create the main package directory
    mkdir -p sevault-plugin-package

    # Move the extracted rootfs into the package directory
    mv plugin-rootfs sevault-plugin-package/rootfs

    # Copy the plugin configuration file into the package directory, renaming it to config.json
    cp plugin-config.json sevault-plugin-package/config.json
    ```
    You should now have a directory structure like this:
    ```
    sevault-plugin-package/
    ├── config.json
    └── rootfs/
        ├── sevaultd
        └── sbin/
            ├── mount.cifs
            └── mount.nfs
    ```

### 2.2 Installing and Managing the Plugin

Once the plugin package is built and structured correctly:

1.  **Navigate to the plugin package directory:**
    ```bash
    cd sevault-plugin-package
    ```

2.  **Create the plugin:**
    This command tells Docker to register the plugin from the current directory (`.`).
    ```bash
    docker plugin create sevault .
    ```
    *Note: Replace `sevault` with `<your-dockerhub-username>/sevault` if you plan to push it to Docker Hub.*

3.  **List plugins to verify installation:**
    ```bash
    docker plugin ls
    ```
    You should see `sevault` (or your namespaced version) in the list with `enabled: false`.

4.  **Enable the plugin:**
    Plugins must be enabled before they can be used.
    ```bash
    docker plugin enable sevault
    ```

5.  **Disable the plugin (when needed):**
    ```bash
    docker plugin disable sevault
    ```

6.  **Remove the plugin (when needed):**
    Ensure the plugin is disabled before removing.
    ```bash
    docker plugin rm sevault
    ```

### 2.3 Using the Plugin

Once the plugin is installed and enabled:

1.  **Create a volume:**
    Use `docker volume create` with the `-d sevault` driver option.
    ```bash
    docker volume create -d sevault --name mynfsvolume \
      -o host=<nfs-server-ip> \
      -o export=<export-path> \
      # -o type=nfs # This is optional, defaults to nfs
      # -o vers=4 # Also optional, defaults to 4 for NFS
    ```

2.  **Driver Options (`-o` or `driver_opts`):**
    *   `host`: (Required) The IP address or hostname of the NFS/CIFS server.
    *   `export`: (Required) The exported directory path on the server (e.g., `/srv/share`, `//server/share`).
    *   `type`: (Optional) Specify the backend type. Currently, "nfs" is fully supported. "cifs" can be specified, and `mount.cifs` is included in the plugin's rootfs, but the driver logic for CIFS-specific options or mount procedures might be minimal initially. Defaults to "nfs" if not provided.
    *   Other options (like `vers` for NFS) can also be passed and will be used by the respective mount helper if supported.

3.  **Run a container with the volume:**
    ```bash
    docker run -it --rm -v mynfsvolume:/mnt/data alpine ash
    ```
    Inside the container, `/mnt/data` will be the mounted remote share.

### 2.4 Testing with Docker Compose

The `docker-compose.yml` file in the repository can be used to test the *installed and enabled* `sevault` plugin.

1.  **Ensure the `sevault` plugin is installed and enabled** as described in section 2.2.
2.  **Review `docker-compose.yml`:**
    ```yaml
    services:
      test-nfs-client:
        image: alpine:3.20
        volumes:
          - testvol:/mnt

    volumes:
      testvol:
        driver: sevault
        driver_opts:
          host: "127.0.0.1" # Adjust if your NFS server is elsewhere
          export: "/tmp"     # Adjust to match an actual export on your NFS server
          # type: "nfs"      # Optional, defaults to nfs
    ```
3.  **Important Note on `driver_opts`:**
    The default `driver_opts` in `docker-compose.yml` are `host: "127.0.0.1"` and `export: "/tmp"`. This implies you need an NFS server running on your local machine (the Docker host) and exporting its `/tmp` directory.
    **You will likely need to adjust `host` and `export` to match your actual NFS server setup.** For example, if you have an NFS server at `192.168.1.100` exporting `/srv/data`:
    ```yaml
          host: "192.168.1.100"
          export: "/srv/data"
    ```

4.  **Run Docker Compose:**
    Once `docker-compose.yml` is configured for your environment:
    ```bash
    docker-compose up
    ```
    The `test-nfs-client` service will start, and Docker will attempt to provision the `testvol` using the `sevault` plugin and the specified `driver_opts`. You can then exec into the container to check `/mnt`.
    ```bash
    docker-compose exec test-nfs-client sh
    # Inside the container:
    # ls /mnt
    # df -h
    ```

---

## 3  Feature roadmap (summary)

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
