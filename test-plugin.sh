#!/bin/bash
set -eo pipefail # Exit on error, treat unset variables as an error, and propagate pipeline failures

cleanup() {
    echo "INFO: Running cleanup..."
    # Use docker compose v2 syntax
    if command -v docker && docker compose version >/dev/null 2>&1; then
        docker compose -f docker-compose.test.yml down --volumes --remove-orphans 2>/dev/null || true
    elif command -v docker-compose && docker-compose --version >/dev/null 2>&1; then # Fallback for v1
        docker-compose -f docker-compose.test.yml down --volumes --remove-orphans 2>/dev/null || true
    fi

    if [ -f "./docker-compose.test.yml" ]; then
        echo "INFO: Removing temporary docker-compose.test.yml..."
        rm -f ./docker-compose.test.yml
    fi
    if docker ps -a --format '{{.Names}}' | grep -q '^test-nfs-server$'; then
        echo "INFO: Stopping and removing test-nfs-server container..."
        docker stop test-nfs-server 2>/dev/null || true
        docker rm test-nfs-server 2>/dev/null || true
    fi
    if docker network ls --format '{{.Name}}' | grep -q '^test-plugin-net$'; then
        echo "INFO: Removing Docker network test-plugin-net..."
        docker network rm test-plugin-net 2>/dev/null || true
    fi
    if [ -d "./nfs_share_test" ]; then
        echo "INFO: Removing local NFS share directory ./nfs_share_test..."
        rm -rf ./nfs_share_test || sudo rm -rf ./nfs_share_test 2>/dev/null || true
    fi
    if docker plugin ls --format '{{.Name}}' | grep -q '^sevault$'; then
        echo "INFO: Disabling and removing sevault plugin..."
        docker plugin disable sevault 2>/dev/null || true
        docker plugin rm sevault 2>/dev/null || true
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
NFS_SERVER_IMAGE="erichough/nfs-server:latest" # Platform will be linux/amd64 for this image
NFS_SERVER_NAME="test-nfs-server"
LOCAL_NFS_SHARE_DIR="./nfs_share_test"
PLUGIN_NAME="sevault"
TEST_NETWORK_NAME="test-plugin-net"

# Function to check and use correct docker compose command
get_compose_cmd() {
    if command -v docker && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose && docker-compose --version >/dev/null 2>&1; then
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

echo "INFO: Extracting mount.nfs and mount.cifs from ${NFS_IMAGE_ALPINE}..."
EXTRACT_CONTAINER_NAME="mount-utils-extractor-$(date +%s)"
# Use --platform linux/amd64 for alpine if running on ARM host to ensure x86_64 utils
docker create --name ${EXTRACT_CONTAINER_NAME} --platform linux/amd64 ${NFS_IMAGE_ALPINE} /bin/sh -c \
    "apk update >/dev/stderr && apk add --no-cache nfs-utils cifs-utils >/dev/stderr && ls -l /sbin/mount.* >/dev/stderr && tar -cC /sbin mount.nfs mount.cifs"
docker start -a ${EXTRACT_CONTAINER_NAME} | tar -vxf - -C sevault-plugin-package/rootfs/sbin/
docker rm ${EXTRACT_CONTAINER_NAME} > /dev/null

if [ ! -f "sevault-plugin-package/rootfs/sbin/mount.nfs" ] || [ ! -f "sevault-plugin-package/rootfs/sbin/mount.cifs" ]; then
    echo "ERROR: Failed to extract mount.nfs or mount.cifs."
    ls -l sevault-plugin-package/rootfs/sbin/
    exit 1
fi
cp plugin-config.json sevault-plugin-package/config.json
echo "INFO: Plugin package prepared."

# 3. Setup Docker network
echo "INFO: Setting up Docker network ${TEST_NETWORK_NAME}..."
if ! docker network inspect ${TEST_NETWORK_NAME} >/dev/null 2>&1; then
    docker network create ${TEST_NETWORK_NAME}
else
    echo "INFO: Network ${TEST_NETWORK_NAME} already exists."
fi

# 4. Start NFS Server
echo "INFO: Starting NFS server container (${NFS_SERVER_NAME}) using ${NFS_SERVER_IMAGE}..."
mkdir -p ${LOCAL_NFS_SHARE_DIR}
docker run -d --name ${NFS_SERVER_NAME} \
    --network ${TEST_NETWORK_NAME} \
    --platform linux/amd64 \
    -v "${PWD}/${LOCAL_NFS_SHARE_DIR}:/exports:rw" \
    -e NFS_EXPORT_0="/exports *(rw,sync,no_subtree_check,no_root_squash)" \
    --privileged \
    ${NFS_SERVER_IMAGE}

echo "INFO: Waiting for NFS server to start (approx 10-15s)..."
NFS_SERVER_READY=0
for i in {1..15}; do
    # Check logs for a specific message indicating readiness
    if docker logs ${NFS_SERVER_NAME} 2>&1 | grep -q "SERVER STARTUP COMPLETE"; then # Corrected readiness check
        NFS_SERVER_READY=1
        break
    fi
    echo "INFO: Still waiting for NFS server... (${i}s)"
    sleep 1
done

if [ ${NFS_SERVER_READY} -eq 0 ]; then
    echo "ERROR: NFS Server container ${NFS_SERVER_NAME} failed to start or become ready in time."
    echo "NFS server logs:"
    docker logs ${NFS_SERVER_NAME} --tail 50
    exit 1
fi
NFS_SERVER_IP_IN_NETWORK=$(docker inspect -f "{{.NetworkSettings.Networks.${TEST_NETWORK_NAME}.IPAddress}}" ${NFS_SERVER_NAME})
if [ -z "${NFS_SERVER_IP_IN_NETWORK}" ]; then
    echo "ERROR: Could not determine NFS server IP address on network ${TEST_NETWORK_NAME}."
    docker logs ${NFS_SERVER_NAME}
    exit 1
fi
echo "INFO: NFS server started. IP on ${TEST_NETWORK_NAME}: ${NFS_SERVER_IP_IN_NETWORK}"

# 5. Install and Enable Plugin
echo "INFO: Removing existing plugin (if any) and installing new one..."
docker plugin disable ${PLUGIN_NAME} > /dev/null 2>&1 || true
docker plugin rm ${PLUGIN_NAME} > /dev/null 2>&1 || true

echo "INFO: Creating plugin from package ./sevault-plugin-package"
docker plugin create ${PLUGIN_NAME} ./sevault-plugin-package
echo "INFO: Enabling plugin ${PLUGIN_NAME}..."
docker plugin enable ${PLUGIN_NAME}
if ! docker plugin ls --format '{{.Name}}: {{.Enabled}}' | grep -q "^${PLUGIN_NAME}: true$"; then
    echo "ERROR: Plugin ${PLUGIN_NAME} not found or not enabled."
    exit 1
fi
echo "INFO: Plugin ${PLUGIN_NAME} installed and enabled."

# 6. Run Test using Docker Compose
echo "INFO: Preparing temporary docker-compose file (docker-compose.test.yml)..."
cat > docker-compose.test.yml <<EOL
version: '3.8'
services:
  test-nfs-client:
    image: alpine:3.20
    networks:
      - ${TEST_NETWORK_NAME}
    volumes:
      - testvol:/mnt
    command: |
      sh -c "
        echo 'CLIENT: Waiting a bit for volume to be ready...'
        sleep 3
        echo 'CLIENT: Attempting to write to /mnt/testfile.txt...'
        touch /mnt/testfile.txt && \
        echo 'CLIENT: Successfully created /mnt/testfile.txt.' && \
        echo 'Test data from Sevault NFS volume' > /mnt/testfile.txt && \
        echo 'CLIENT: Successfully wrote to /mnt/testfile.txt.' && \
        echo 'CLIENT: Content of /mnt/testfile.txt:' && \
        cat /mnt/testfile.txt && \
        ls -l /mnt && \
        echo 'CLIENT: Test successful!' || \
        (echo 'CLIENT: Test FAILED.' && exit 1)
      "
volumes:
  testvol:
    driver: ${PLUGIN_NAME}
    driver_opts:
      host: "${NFS_SERVER_IP_IN_NETWORK}"
      export: "/exports"
      type: "nfs"
networks:
  ${TEST_NETWORK_NAME}:
    external: true
EOL

echo "INFO: Running Docker Compose test (test-nfs-client)..."
"${COMPOSE_CMD[@]}" -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from test-nfs-client test-nfs-client
COMPOSE_EXIT_CODE=$?

if [ ${COMPOSE_EXIT_CODE} -ne 0 ]; then
    echo "ERROR: Docker Compose test failed with exit code ${COMPOSE_EXIT_CODE}."
    # Get client logs if compose up failed
    CLIENT_CONTAINER_ID=$("${COMPOSE_CMD[@]}" -f docker-compose.test.yml ps -q test-nfs-client)
    if [ -n "${CLIENT_CONTAINER_ID}" ]; then
      echo "test-nfs-client logs:"
      docker logs ${CLIENT_CONTAINER_ID} --tail 50
    fi
    exit 1
fi

echo "INFO: Docker Compose test successful."
echo "INFO: Local plugin test completed successfully!"
exit 0
