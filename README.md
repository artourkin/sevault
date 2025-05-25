# Sevault

**Sevault** is a Docker-native volume plugin that lets you mount remote
filesystems—NFS v4, CIFS 3.x, and more—into containers with automatic
re-mounting, TLS-ready transport, and a pluggable backend architecture.
It fills the gap between basic NFS mounts and heavyweight
Kubernetes-only storage stacks like Longhorn or Ceph.

| Feature            | Fact (May 2025)                                  |
| ------------------ | ------------------------------------------------ |
| Docker API level   | 1.41+ (works with Docker 20.10 and later)        |
| Plugin scope       | `global` (usable by all containers on the node)  |
| Supported backends | NFS v3/v4, CIFS 3.x (SMB-encrypted), future SFTP |
| License            | Apache-2.0                                       |
