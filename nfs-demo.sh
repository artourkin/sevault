#!/usr/bin/env bash
set -euo pipefail

# Quick demo: start a throwaway NFS server container and mount it via the sevault plugin in a client container.

NETWORK="${NETWORK:-sevault-demo-net}"
EXPORT_VOLUME="${EXPORT_VOLUME:-sevault-demo-export}"
SERVER_CONTAINER="${SERVER_CONTAINER:-sevault-demo-nfs}"
CLIENT_CONTAINER="${CLIENT_CONTAINER:-sevault-demo-client}"
SEVAULT_VOLUME="${SEVAULT_VOLUME:-sevault-demo-vol}"
SEVAULT_PLUGIN="${SEVAULT_PLUGIN:-sevault}"
NFS_IMAGE="${NFS_IMAGE:-erichough/nfs-server:latest}"
CLIENT_IMAGE="${CLIENT_IMAGE:-alpine:3.20}"
EXPORT_PATH="${EXPORT_PATH:-/exports}"
NFS_VERS="${NFS_VERS:-3}"

cleanup() {
    docker rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
    docker rm -f "${SERVER_CONTAINER}" >/dev/null 2>&1 || true
    docker volume rm "${SEVAULT_VOLUME}" >/dev/null 2>&1 || true
    # keep export volume so NFS server can reuse between runs; drop it if you want a clean slate
    # docker volume rm "${EXPORT_VOLUME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}

#trap cleanup EXIT

echo "[+] Ensuring network ${NETWORK} exists"
docker network inspect "${NETWORK}" >/dev/null 2>&1 || docker network create "${NETWORK}" >/dev/null

echo "[+] Ensuring export volume ${EXPORT_VOLUME} exists"
docker volume inspect "${EXPORT_VOLUME}" >/dev/null 2>&1 || docker volume create "${EXPORT_VOLUME}" >/dev/null

echo "[+] Starting NFS server container ${SERVER_CONTAINER}"
docker rm -f "${SERVER_CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${SERVER_CONTAINER}" \
  --privileged \
  --network "${NETWORK}" \
  -v "${EXPORT_VOLUME}:${EXPORT_PATH}:rw" \
  -e "NFS_EXPORT_0=${EXPORT_PATH} *(rw,sync,no_subtree_check,no_root_squash)" \
  --platform linux/amd64 \
  "${NFS_IMAGE}" >/dev/null

sleep 3
SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${SERVER_CONTAINER}")
if [ -z "${SERVER_IP}" ]; then
    echo "[-] Failed to determine NFS server IP"
    exit 1
fi
echo "[+] NFS server running at ${SERVER_IP}:${EXPORT_PATH} (vers=${NFS_VERS})"

echo "[+] Creating Sevault volume ${SEVAULT_VOLUME}"
docker volume rm "${SEVAULT_VOLUME}" >/dev/null 2>&1 || true
docker volume create -d "${SEVAULT_PLUGIN}" \
  --name "${SEVAULT_VOLUME}" \
  -o "host=${SERVER_IP}" \
  -o "export=${EXPORT_PATH}" \
  -o "vers=${NFS_VERS}" >/dev/null

echo "[+] Running client container ${CLIENT_CONTAINER} to write/read test file"
docker rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
docker run --rm --name "${CLIENT_CONTAINER}" \
  --network "${NETWORK}" \
  -v "${SEVAULT_VOLUME}:/mnt" \
  "${CLIENT_IMAGE}" \
  sh -c "set -e; echo 'hello from sevault' > /mnt/demo.txt; cat /mnt/demo.txt; ls -l /mnt"

echo "[+] Demo complete (vol=${SEVAULT_VOLUME}, server=${SERVER_CONTAINER})"
