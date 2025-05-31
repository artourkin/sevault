#!/bin/bash
set -eo pipefail # Exit on error, treat unset variables as an error, and propagate pipeline failures

cleanup() {
    echo "INFO: Running cleanup..."
    docker-compose -f docker-compose.yml down --volumes 2>/dev/null || true # Stop test client
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
        sudo rm -rf ./nfs_share_test # May require sudo if files were created as root by NFS
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
    # Remove the temporary compose file if it exists
    if [ -f "./docker-compose.test.yml" ]; then
        echo "INFO: Removing temporary docker-compose.test.yml..."
        rm -f ./docker-compose.test.yml
    fi
    echo "INFO: Cleanup finished."
}

trap cleanup EXIT # Register cleanup function to run on script exit (normal or error)

# 0. Configuration
NFS_IMAGE="erichough/nfs-server:latest" # Using a specific well-known image
NFS_SERVER_NAME="test-nfs-server"
NFS_EXPORT_DIR="/tmp/nfs_share_test_$(date +%s)" # Unique export dir for the server
LOCAL_NFS_SHARE_DIR="./nfs_share_test" # Local dir to be mounted into NFS server
PLUGIN_NAME="sevault"
TEST_NETWORK_NAME="test-plugin-net"

echo "INFO: Starting local plugin test..."

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
mkdir -p sevault-plugin-package/rootfs/sbin # Ensure sbin exists for mount helpers
cp ./sevaultd sevault-plugin-package/rootfs/sevaultd

#    Extract mount.nfs and mount.cifs from an Alpine image
echo "INFO: Extracting mount.nfs and mount.cifs..."
# Using --platform linux/amd64 for erichough/nfs-server to ensure compatibility on non-amd64 hosts for extraction
docker run --rm --platform linux/amd64 --entrypoint /bin/sh "${NFS_IMAGE}" -c "tar -cC /sbin mount.nfs mount.cifs" | tar -vxf - -C sevault-plugin-package/rootfs/sbin/
if [ ! -f "sevault-plugin-package/rootfs/sbin/mount.nfs" ] || [ ! -f "sevault-plugin-package/rootfs/sbin/mount.cifs" ]; then
    echo "ERROR: Failed to extract mount.nfs or mount.cifs."
    exit 1
fi
cp plugin-config.json sevault-plugin-package/config.json
echo "INFO: Plugin package prepared."

# 3. Setup Docker network
echo "INFO: Setting up Docker network ${TEST_NETWORK_NAME}..."
if ! docker network inspect "${TEST_NETWORK_NAME}" > /dev/null 2>&1; then
    docker network create "${TEST_NETWORK_NAME}"
else
    echo "INFO: Network ${TEST_NETWORK_NAME} already exists."
fi


# 4. Start NFS Server
echo "INFO: Starting NFS server container (${NFS_SERVER_NAME})..."
mkdir -p ${LOCAL_NFS_SHARE_DIR}
# The erichough/nfs-server image needs SHARED_DIRECTORY to be set.
# The path used for SHARED_DIRECTORY must exist within the container.
# We mount our local share to /exports inside the container, and tell the image to share /exports.
# Adding --platform linux/amd64 for erichough/nfs-server for wider compatibility
docker run -d --name ${NFS_SERVER_NAME} \
    --platform linux/amd64 \
    --network ${TEST_NETWORK_NAME} \
    -v "${PWD}/${LOCAL_NFS_SHARE_DIR}:/exports:rw" \
    -e SHARED_DIRECTORY=/exports \
    --cap-add SYS_ADMIN --cap-add NFS_SERVER \
    --privileged \
    ${NFS_IMAGE}

# Wait for NFS server to be ready - simple sleep, could be more sophisticated
echo "INFO: Waiting for NFS server to start..."
sleep 10
if ! docker ps --format '{{.Names}}' | grep -q "^${NFS_SERVER_NAME}$"; then
    echo "ERROR: NFS Server container ${NFS_SERVER_NAME} failed to start or is not running."
    docker logs ${NFS_SERVER_NAME}
    exit 1
fi
NFS_SERVER_IP=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" ${NFS_SERVER_NAME})
if [ -z "${NFS_SERVER_IP}" ]; then
    echo "ERROR: Could not determine NFS server IP address."
    docker logs ${NFS_SERVER_NAME}
    exit 1
fi
echo "INFO: NFS server started. IP: ${NFS_SERVER_IP}, Exporting host dir ${LOCAL_NFS_SHARE_DIR} as /exports"

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
#    Temporarily modify docker-compose.yml or use env vars if supported by compose file.
#    For now, we'll create a temporary compose file with the correct host IP.
echo "INFO: Preparing temporary docker-compose file for test..."
cat > docker-compose.test.yml <<EOL
services:
  test-nfs-client:
    image: alpine:3.20
    # network_mode: "container:${NFS_SERVER_NAME}" # Join NFS server's network to use localhost - alternative using network
    network: "${TEST_NETWORK_NAME}"
    depends_on:
      - ${NFS_SERVER_NAME} # This is illustrative; direct container dependency not strictly needed here due to IP usage
    volumes:
      - testvol:/mnt
    # Add a simple test command
    command: |
      sh -c "
        # Wait a bit for volume to be ready, especially if NFS server is slow
        sleep 5
        echo 'Attempting to write to /mnt/testfile.txt...'
        touch /mnt/testfile.txt && \
        echo 'Successfully created /mnt/testfile.txt.' && \
        echo 'Test data' > /mnt/testfile.txt && \
        echo 'Contents of /mnt/testfile.txt:' && \
        cat /mnt/testfile.txt && \
        echo 'Directory listing of /mnt:' && \
        ls -l /mnt && \
        echo 'Test successful!' || \
        (echo 'Test FAILED.' && exit 1)
      "
volumes:
  testvol:
    driver: ${PLUGIN_NAME}
    driver_opts:
      host: "${NFS_SERVER_IP}" # Use the dynamically obtained IP of the NFS server
      export: "/exports" # This is the path *inside* the NFS server container
      # type: "nfs" # Optional, as it defaults to nfs
EOL

echo "INFO: Running Docker Compose test..."
# The test-nfs-client will run, execute its command, and its exit code will determine success.
# Using `docker-compose -f docker-compose.test.yml up --exit-code-from test-nfs-client`
# ensures compose itself exits with the test container's code.
docker-compose -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from test-nfs-client

COMPOSE_EXIT_CODE=$?
# rm docker-compose.test.yml # Keep it for inspection if needed, cleanup trap will get it

if [ ${COMPOSE_EXIT_CODE} -ne 0 ]; then
    echo "ERROR: Docker Compose test failed with exit code ${COMPOSE_EXIT_CODE}."
    # Show logs from the client container for debugging
    docker-compose -f docker-compose.test.yml logs test-nfs-client
    exit 1
fi

echo "INFO: Docker Compose test successful."
echo "INFO: Local plugin test completed successfully!"
# Cleanup is handled by trap

exit 0

```
