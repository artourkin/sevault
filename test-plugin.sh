#!/bin/bash
set -eo pipefail # Exit on error, treat unset variables as an error, and propagate pipeline failures

COMPOSE_FILE_PATH="./tests/docker-compose.plugin-test.yml"

cleanup() {
    local exit_code=${1:-0}
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
        if [ "${KEEP_PLUGIN_ON_FAILURE}" = "true" ] && [ "${exit_code}" -ne 0 ]; then
            echo "INFO: KEEP_PLUGIN_ON_FAILURE=true and script failed; skipping plugin disable/remove for debugging."
        else
            echo "INFO: Disabling and removing sevault plugin..."
            docker plugin disable "${plugin_ref}" 2>/dev/null || true
            docker plugin rm "${plugin_ref}" 2>/dev/null || true
        fi
    fi
    if [ -d "./sevault-plugin-package" ]; then
        if [ "${CACHE_BUILD_ARTIFACTS}" = "true" ]; then
            echo "INFO: Preserving plugin package directory for caching."
        else
            echo "INFO: Removing plugin package directory..."
            rm -rf ./sevault-plugin-package
        fi
    fi
    if [ -f "./sevaultd" ]; then
        if [ "${CACHE_BUILD_ARTIFACTS}" = "true" ]; then
            echo "INFO: Preserving sevaultd binary for caching."
        else
            echo "INFO: Removing sevaultd binary..."
            rm -f ./sevaultd
        fi
    fi
    echo "INFO: Cleanup finished."
    if [ "${exit_code}" -ne 0 ]; then
        echo "INFO: Script exited with status ${exit_code}."
    fi
}

#trap 'cleanup "$?"' EXIT

# 0. Configuration
NFS_IMAGE_ALPINE="alpine:3.20"
TEST_NFS_CLIENT_IMAGE="alpine:3.20"
NFS_SERVER_IMAGE="erichough/nfs-server:latest" # Platform will be linux/amd64 for this image
NFS_EXPORT_VOLUME="sevault-test-nfs-share"
NFS_EXPORT_PATH="/exports"
TEST_NFS_VERSION="${TEST_NFS_VERSION:-3}"
PLUGIN_NAME="sevault"
TEST_NETWORK_NAME="test-plugin-net"
SERVER_READINESS_TOKEN="SERVER STARTUP COMPLETE"
SERVER_MAX_WAIT_SECONDS=20
DEFAULT_COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-sevault_plugin_test}"
PLUGIN_TEST_PROJECT="${PLUGIN_TEST_PROJECT:-${DEFAULT_COMPOSE_PROJECT}}"
export COMPOSE_PROJECT_NAME="${PLUGIN_TEST_PROJECT}"
GO_BUILD_IMAGE="${GO_BUILD_IMAGE:-golang:1.22-alpine}"
REQUIRE_NFS_KERNEL_MODULE="${REQUIRE_NFS_KERNEL_MODULE:-true}"
KEEP_PLUGIN_ON_FAILURE="${KEEP_PLUGIN_ON_FAILURE:-false}"
CACHE_BUILD_ARTIFACTS="${CACHE_BUILD_ARTIFACTS:-true}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"

if [ "${FORCE_REBUILD}" = "true" ]; then
    echo "INFO: FORCE_REBUILD=true; removing cached build artifacts..."
    rm -f ./sevaultd 2>/dev/null || true
    rm -rf ./sevault-plugin-package 2>/dev/null || true
fi

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

build_with_local_go() {
    if ! command -v go >/dev/null 2>&1; then
        echo "INFO: Local Go toolchain not found; skipping direct build."
        return 1
    fi
    echo "INFO: Attempting to build sevaultd using local Go installation..."
    if CGO_ENABLED=0 go build -o sevaultd ./cmd/sevaultd; then
        echo "INFO: Local Go build succeeded."
        return 0
    fi
    echo "WARN: Local Go build failed. Will try Dockerized Go build fallback."
    return 1
}

build_with_docker_go() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: Docker CLI is not available for Dockerized Go build fallback."
        return 1
    fi
    local repo_dir
    repo_dir=$(pwd)
    local uid gid
    uid=$(id -u)
    gid=$(id -g)
    echo "INFO: Building sevaultd using Docker image ${GO_BUILD_IMAGE}..."
    if docker run --rm \
        --user "${uid}:${gid}" \
        -e CGO_ENABLED=0 \
        -v "${repo_dir}":/workspace \
        -w /workspace \
        "${GO_BUILD_IMAGE}" \
        go build -o sevaultd ./cmd/sevaultd; then
        echo "INFO: Dockerized Go build succeeded."
        return 0
    fi
    echo "ERROR: Dockerized Go build failed."
    return 1
}

build_sevaultd() {
    if build_with_local_go; then
        return 0
    fi
    if build_with_docker_go; then
        return 0
    fi
    return 1
}

remove_existing_plugin() {
    if ! docker plugin inspect "${PLUGIN_NAME}" >/dev/null 2>&1; then
        return 0
    fi
    echo "INFO: Existing plugin ${PLUGIN_NAME} detected. Disabling/removing..."
    docker plugin disable --force "${PLUGIN_NAME}" >/dev/null 2>&1 || true
    docker plugin rm --force "${PLUGIN_NAME}" >/dev/null 2>&1 || true
    if docker plugin inspect "${PLUGIN_NAME}" >/dev/null 2>&1; then
        echo "ERROR: Unable to remove existing plugin ${PLUGIN_NAME}. Please remove it manually and rerun."
        docker plugin ls
        exit 1
    fi
}

ensure_nfs_kernel_modules() {
    if [ "${REQUIRE_NFS_KERNEL_MODULE}" != "true" ]; then
        return 0
    fi

    local modules=("nfs" "nfsd")
    local missing=()

    for module in "${modules[@]}"; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "${module}"; then
            continue
        fi
        if [ "${module}" = "nfs" ] && grep -qE '^[[:space:]]*nfs' /proc/filesystems 2>/dev/null; then
            continue
        fi
        echo "INFO: Kernel module '${module}' not detected. Attempting to load..."
        if modprobe "${module}" 2>/dev/null; then
            echo "INFO: Successfully loaded ${module} kernel module."
            continue
        fi
        if command -v sudo >/dev/null 2>&1 && sudo modprobe "${module}"; then
            echo "INFO: Successfully loaded ${module} kernel module using sudo."
            continue
        fi
        missing+=("${module}")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    cat <<EOF
ERROR: Unable to load kernel module(s) required by the NFS server container: ${missing[*]}
Please load them manually on the host (e.g. run 'sudo modprobe MODULE') or disable this
check via REQUIRE_NFS_KERNEL_MODULE=false if you know the modules are built into your kernel.
EOF
    return 1
}

echo "INFO: Starting local plugin test..."
echo "INFO: Using Docker Compose command: ${COMPOSE_CMD_STR}"
echo "INFO: Compose project name: ${COMPOSE_PROJECT_NAME}"
echo "INFO: Docker version:"
docker --version
echo "INFO: Docker Compose version:"
"${COMPOSE_CMD[@]}" version


# 1. Build sevaultd binary
echo "INFO: Building sevaultd binary..."
if [ "${CACHE_BUILD_ARTIFACTS}" = "true" ] && [ -f "./sevaultd" ]; then
    echo "INFO: Reusing existing sevaultd binary (set FORCE_REBUILD=true to rebuild)."
else
    if ! build_sevaultd; then
        echo "ERROR: Failed to build sevaultd binary using available Go toolchains."
        exit 1
    fi
fi
if [ ! -f "./sevaultd" ]; then
    echo "ERROR: sevaultd binary not found after build."
    exit 1
fi
echo "INFO: sevaultd binary built successfully."

# 2. Prepare plugin package
echo "INFO: Preparing Docker plugin package..."
mkdir -p sevault-plugin-package/rootfs/sbin
mkdir -p sevault-plugin-package/rootfs/var/lib/sevault/mounts
cp ./sevaultd sevault-plugin-package/rootfs/sevaultd

if [ "${CACHE_BUILD_ARTIFACTS}" = "true" ] && [ -f "sevault-plugin-package/rootfs/sbin/mount.nfs" ]; then
    echo "INFO: Reusing cached mount.nfs helper."
else
    echo "INFO: Extracting mount.nfs from ${NFS_IMAGE_ALPINE}..."
    EXTRACT_CONTAINER_NAME="mount-utils-extractor-$(date +%s)"
    docker create --name ${EXTRACT_CONTAINER_NAME} --platform linux/amd64 ${NFS_IMAGE_ALPINE} /bin/sh -c \
        "apk update >/dev/stderr && apk add --no-cache nfs-utils >/dev/stderr && ls -l /sbin/mount.* >/dev/stderr && tar -cC /sbin mount.nfs"
    docker start -a ${EXTRACT_CONTAINER_NAME} | tar -vxf - -C sevault-plugin-package/rootfs/sbin/
    docker rm ${EXTRACT_CONTAINER_NAME} > /dev/null
fi

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

if ! ensure_nfs_kernel_modules; then
    exit 1
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
export TESTS_NFS_VERSION="${TEST_NFS_VERSION}"

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
remove_existing_plugin

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
