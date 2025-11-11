#!/bin/bash
set -eo pipefail # Exit on error, treat unset variables as an error, and propagate pipeline failures

COMPOSE_FILE_PATH="./tests/docker-compose.plugin-test.yml"

cleanup() {
    echo "INFO: Running cleanup..."
    local plugin_ref=${PLUGIN_NAME:-sevault}
    local nfs_volume_ref=${NFS_EXPORT_VOLUME:-test-nfs-share-volume}
    # Use docker compose v2 syntax
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        docker compose --file "${COMPOSE_FILE_PATH}" down --volumes --remove-orphans 2>/dev/null || true
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then # Fallback for v1
        docker-compose --file "${COMPOSE_FILE_PATH}" down --volumes --remove-orphans 2>/dev/null || true
    fi
    local network_ref=${TEST_NETWORK_NAME:-test-plugin-net}
    if docker network ls --format '{{.Name}}' | grep -q "^${network_ref}$"; then
        echo "INFO: Removing Docker network ${network_ref}..."
        docker network rm "${network_ref}" 2>/dev/null || true
    fi
    if docker volume inspect "${nfs_volume_ref}" >/dev/null 2>&1; then
        echo "INFO: Removing Docker volume ${nfs_volume_ref}..."
        docker volume rm "${nfs_volume_ref}" 2>/dev/null || true
    fi
    if [ -d "./nfs_share_test" ]; then
        echo "INFO: Removing legacy local NFS share directory ./nfs_share_test..."
        rm -rf ./nfs_share_test || sudo rm -rf ./nfs_share_test 2>/dev/null || true
    fi
    if docker plugin inspect "${plugin_ref}" >/dev/null 2>&1; then
        echo "INFO: Disabling and removing sevault plugin..."
        docker plugin disable "${plugin_ref}" 2>/dev/null || true
        docker plugin rm "${plugin_ref}" 2>/dev/null || true
    fi
    if [ -d "./sevault-plugin-package" ]; then
        echo "INFO: Removing plugin package directory..."
        rm -rf ./sevault-plugin-package
    fi
    if [ -f "./sevaultd" ]; then
        echo "INFO: Removing sevaultd binary..."
        rm -f ./sevaultd
    fi
    echo "INFO: Cleanup finished."
}

trap cleanup EXIT

# 0. Configuration
NFS_IMAGE_ALPINE="alpine:3.20"
TEST_NFS_CLIENT_IMAGE="alpine:3.20"
NFS_SERVER_IMAGE="erichough/nfs-server:latest" # Platform will be linux/amd64 for this image
NFS_EXPORT_VOLUME="sevault-test-nfs-share"
NFS_EXPORT_PATH="/exports"
PLUGIN_NAME="sevault"
TEST_NETWORK_NAME="test-plugin-net"
SERVER_READINESS_TOKEN="SERVER STARTUP COMPLETE"
SERVER_MAX_WAIT_SECONDS=20
DEFAULT_COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-sevault_plugin_test}"
PLUGIN_TEST_PROJECT="${PLUGIN_TEST_PROJECT:-${DEFAULT_COMPOSE_PROJECT}}"
export COMPOSE_PROJECT_NAME="${PLUGIN_TEST_PROJECT}"

# Function to check and use correct docker compose command
get_compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "ERROR: Neither 'docker compose' (v2) nor 'docker-compose' (v1) found. Please install Docker Compose." >&2
        exit 1
    fi
}
COMPOSE_CMD_STR=$(get_compose_cmd)
# Convert COMPOSE_CMD_STR to an array for easier execution
read -r -a COMPOSE_CMD <<< "$COMPOSE_CMD_STR"


echo "INFO: Starting local plugin test..."
echo "INFO: Using Docker Compose command: ${COMPOSE_CMD_STR}"
echo "INFO: Compose project name: ${COMPOSE_PROJECT_NAME}"
echo "INFO: Docker version:"
docker --version
echo "INFO: Docker Compose version:"
"${COMPOSE_CMD[@]}" version


# 1. Build sevaultd binary
echo "INFO: Building sevaultd binary..."
CGO_ENABLED=0 go build -o sevaultd ./cmd/sevaultd
if [ ! -f "./sevaultd" ]; then
    echo "ERROR: sevaultd binary not found after build."
    exit 1
fi
echo "INFO: sevaultd binary built successfully."

# 2. Prepare plugin package
echo "INFO: Preparing Docker plugin package..."
mkdir -p sevault-plugin-package/rootfs/sbin
cp ./sevaultd sevault-plugin-package/rootfs/sevaultd

echo "INFO: Extracting mount.nfs from ${NFS_IMAGE_ALPINE}..."
EXTRACT_CONTAINER_NAME="mount-utils-extractor-$(date +%s)"
# Use --platform linux/amd64 for alpine if running on ARM host to ensure x86_64 utils
docker create --name ${EXTRACT_CONTAINER_NAME} --platform linux/amd64 ${NFS_IMAGE_ALPINE} /bin/sh -c \
    "apk update >/dev/stderr && apk add --no-cache nfs-utils >/dev/stderr && ls -l /sbin/mount.* >/dev/stderr && tar -cC /sbin mount.nfs"
docker start -a ${EXTRACT_CONTAINER_NAME} | tar -vxf - -C sevault-plugin-package/rootfs/sbin/
docker rm ${EXTRACT_CONTAINER_NAME} > /dev/null

if [ ! -f "sevault-plugin-package/rootfs/sbin/mount.nfs" ]; then
    echo "ERROR: Failed to extract mount.nfs."
    ls -l sevault-plugin-package/rootfs/sbin/
    exit 1
fi
cp plugin-config.json sevault-plugin-package/config.json
echo "INFO: Plugin package prepared."

# 3. Ensure NFS export volume exists
echo "INFO: Ensuring Docker volume ${NFS_EXPORT_VOLUME} exists for NFS exports..."
if ! docker volume inspect "${NFS_EXPORT_VOLUME}" >/dev/null 2>&1; then
    docker volume create "${NFS_EXPORT_VOLUME}" >/dev/null
fi

if [ ! -f "${COMPOSE_FILE_PATH}" ]; then
    echo "ERROR: Expected compose file ${COMPOSE_FILE_PATH} not found."
    exit 1
fi

export TESTS_NFS_SERVER_IMAGE="${NFS_SERVER_IMAGE}"
export TESTS_NFS_EXPORT_VOLUME="${NFS_EXPORT_VOLUME}"
export TESTS_NFS_EXPORT_PATH="${NFS_EXPORT_PATH}"
export TESTS_NETWORK_NAME="${TEST_NETWORK_NAME}"
export TESTS_CLIENT_IMAGE="${TEST_NFS_CLIENT_IMAGE}"
export TESTS_PLUGIN_NAME="${PLUGIN_NAME}"

# 4. Start NFS Server via Docker Compose
echo "INFO: Starting NFS server service using Docker Compose..."
"${COMPOSE_CMD[@]}" --file "${COMPOSE_FILE_PATH}" up -d test-nfs-server

SERVER_CONTAINER_ID=$("${COMPOSE_CMD[@]}" --file "${COMPOSE_FILE_PATH}" ps -q test-nfs-server | head -n 1)
if [ -z "${SERVER_CONTAINER_ID}" ]; then
    echo "ERROR: Unable to determine Docker container ID for the NFS server."
    exit 1
fi

echo "INFO: Waiting for NFS server to start (timeout: ${SERVER_MAX_WAIT_SECONDS}s)..."
NFS_SERVER_READY=0
for second in $(seq 1 ${SERVER_MAX_WAIT_SECONDS}); do
    if docker logs "${SERVER_CONTAINER_ID}" 2>&1 | grep -q "${SERVER_READINESS_TOKEN}"; then
        NFS_SERVER_READY=1
        break
    fi
    echo "INFO: Still waiting for NFS server... (${second}s)"
    sleep 1
done

if [ ${NFS_SERVER_READY} -eq 0 ]; then
    echo "ERROR: NFS server service failed to start or become ready in time."
    echo "NFS server logs:"
    docker logs "${SERVER_CONTAINER_ID}" --tail 80
    exit 1
fi
NFS_SERVER_IP_IN_NETWORK=$(docker inspect -f '{{with index .NetworkSettings.Networks "'"${TEST_NETWORK_NAME}"'"}}{{.IPAddress}}{{end}}' "${SERVER_CONTAINER_ID}")
if [ -z "${NFS_SERVER_IP_IN_NETWORK}" ]; then
    echo "ERROR: Could not determine NFS server IP address on network ${TEST_NETWORK_NAME}."
    docker logs "${SERVER_CONTAINER_ID}"
    exit 1
fi
echo "INFO: NFS server started. IP on ${TEST_NETWORK_NAME}: ${NFS_SERVER_IP_IN_NETWORK}"

# 5. Install and Enable Plugin
echo "INFO: Removing existing plugin (if any) and installing new one..."
docker plugin disable "${PLUGIN_NAME}" > /dev/null 2>&1 || true
docker plugin rm "${PLUGIN_NAME}" > /dev/null 2>&1 || true

STATE_ROOT="/var/lib/sevault"
echo "INFO: Ensuring host state directory ${STATE_ROOT} exists for plugin mounts..."
if [ ! -d "${STATE_ROOT}" ]; then
    if mkdir -p "${STATE_ROOT}" 2>/dev/null; then
        :
    else
        echo "INFO: Creating ${STATE_ROOT} requires elevated privileges. Trying sudo..."
        sudo mkdir -p "${STATE_ROOT}"
    fi
fi
if [ ! -d "${STATE_ROOT}/mounts" ]; then
    if mkdir -p "${STATE_ROOT}/mounts" 2>/dev/null; then
        :
    else
        echo "INFO: Creating ${STATE_ROOT}/mounts requires elevated privileges. Trying sudo..."
        sudo mkdir -p "${STATE_ROOT}/mounts"
    fi
fi

echo "INFO: Creating plugin from package ./sevault-plugin-package"
docker plugin create "${PLUGIN_NAME}" ./sevault-plugin-package
echo "INFO: Enabling plugin ${PLUGIN_NAME}..."
docker plugin enable "${PLUGIN_NAME}"
PLUGIN_ENABLED=$(docker plugin inspect -f '{{.Enabled}}' "${PLUGIN_NAME}" 2>/dev/null || true)
if [ "${PLUGIN_ENABLED}" != "true" ]; then
    echo "ERROR: Plugin ${PLUGIN_NAME} not found or not enabled."
    docker plugin ls
    exit 1
fi
echo "INFO: Plugin ${PLUGIN_NAME} installed and enabled."

# 6. Run Test using Docker Compose
export TESTS_NFS_SERVER_IP="${NFS_SERVER_IP_IN_NETWORK}"

echo "INFO: Running Docker Compose test (test-nfs-client)..."
"${COMPOSE_CMD[@]}" --file "${COMPOSE_FILE_PATH}" up --abort-on-container-exit test-nfs-client
COMPOSE_EXIT_CODE=$?

if [ ${COMPOSE_EXIT_CODE} -ne 0 ]; then
    echo "ERROR: Docker Compose test failed with exit code ${COMPOSE_EXIT_CODE}."
    # Get client logs if compose up failed
    CLIENT_CONTAINER_ID=$("${COMPOSE_CMD[@]}" --file "${COMPOSE_FILE_PATH}" ps -q test-nfs-client)
    if [ -n "${CLIENT_CONTAINER_ID}" ]; then
      echo "test-nfs-client logs:"
      docker logs ${CLIENT_CONTAINER_ID} --tail 50
    fi
    exit 1
fi

echo "INFO: Docker Compose test successful."
echo "INFO: Local plugin test completed successfully!"
exit 0
