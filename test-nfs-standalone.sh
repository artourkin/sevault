#!/usr/bin/env bash
set -euo pipefail

# Standalone test that relies on Docker Compose to orchestrate an NFS server,
# a privileged client workload, and a post-run verifier.

COMPOSE_FILE_PATH="./tests/docker-compose.nfs-standalone.yml"

NFS_SERVER_IMAGE="${NFS_SERVER_IMAGE:-erichough/nfs-server:latest}"
NFS_CLIENT_IMAGE="${NFS_CLIENT_IMAGE:-alpine:3.20}"
NFS_CHECKER_IMAGE="${NFS_CHECKER_IMAGE:-alpine:3.20}"
NFS_EXPORT_VOLUME="${NFS_EXPORT_VOLUME:-standalone-nfs-volume}"
EXPORT_PATH="${EXPORT_PATH:-/exports}"
READINESS_TOKEN="${READINESS_TOKEN:-SERVER STARTUP COMPLETE}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-25}"
TEST_FILENAME="${TEST_FILENAME:-standalone-nfs-test.txt}"
NETWORK_NAME="${NETWORK_NAME:-standalone-nfs-net}"
SERVER_HOST="${SERVER_HOST:-nfs-server}"
PROJECT_NAME="${PROJECT_NAME:-sevault_nfs_standalone}"

COMPOSE_CMD=()

cleanup() {
    local exit_code=$1
    set +e
    echo "INFO: Cleaning up standalone NFS test resources..."
    if [ "${#COMPOSE_CMD[@]}" -gt 0 ] && [ -f "${COMPOSE_FILE_PATH}" ]; then
        "${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" down --volumes --remove-orphans >/dev/null 2>&1
    fi
    set -e
    if [ "${exit_code}" -eq 0 ]; then
        echo "INFO: Standalone NFS test completed successfully."
    else
        echo "WARN: Standalone NFS test failed (see logs above)."
    fi
}

get_compose_cmd() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "ERROR: Neither 'docker compose' (v2) nor 'docker-compose' (v1) found. Please install Docker Compose." >&2
        exit 1
    fi
}

echo "INFO: Starting standalone NFS server/client connectivity test (Compose edition)..."
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker CLI not found in PATH."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Unable to communicate with the Docker daemon. Please ensure Docker is running."
    exit 1
fi
if [ ! -f "${COMPOSE_FILE_PATH}" ]; then
    echo "ERROR: Expected compose file ${COMPOSE_FILE_PATH} not found."
    exit 1
fi

COMPOSE_CMD_STR=$(get_compose_cmd)
read -r -a COMPOSE_CMD <<< "${COMPOSE_CMD_STR}"
trap 'cleanup "$?"' EXIT

export TESTS_NFS_SERVER_IMAGE="${NFS_SERVER_IMAGE}"
export TESTS_NFS_CLIENT_IMAGE="${NFS_CLIENT_IMAGE}"
export TESTS_NFS_CHECKER_IMAGE="${NFS_CHECKER_IMAGE}"
export TESTS_NFS_EXPORT_VOLUME="${NFS_EXPORT_VOLUME}"
export TESTS_EXPORT_PATH="${EXPORT_PATH}"
export TESTS_TEST_FILENAME="${TEST_FILENAME}"
export TESTS_NETWORK_NAME="${NETWORK_NAME}"
export TESTS_NFS_SERVER_HOST="${SERVER_HOST}"
export COMPOSE_PROJECT_NAME="${PROJECT_NAME}"

echo "INFO: Using Docker Compose command: ${COMPOSE_CMD_STR}"
echo "INFO: Compose project name: ${PROJECT_NAME}"

echo "INFO: Ensuring clean slate for compose project..."
"${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" down --volumes --remove-orphans >/dev/null 2>&1 || true

echo "INFO: Launching NFS server service via Docker Compose..."
"${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" up -d nfs-server

SERVER_CONTAINER_ID=$("${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" ps -q nfs-server | head -n 1)
if [ -z "${SERVER_CONTAINER_ID}" ]; then
    echo "ERROR: Unable to determine NFS server container ID."
    exit 1
fi

echo "INFO: Waiting for NFS server to become ready (timeout: ${MAX_WAIT_SECONDS}s)..."
server_ready=0
for second in $(seq 1 "${MAX_WAIT_SECONDS}"); do
    if docker logs "${SERVER_CONTAINER_ID}" 2>&1 | grep -q "${READINESS_TOKEN}"; then
        server_ready=1
        break
    fi
    sleep 1
done

if [ "${server_ready}" -ne 1 ]; then
    echo "ERROR: NFS server did not report readiness within ${MAX_WAIT_SECONDS}s."
    docker logs "${SERVER_CONTAINER_ID}"
    exit 1
fi

NFS_SERVER_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "'"${NETWORK_NAME}"'"}}{{.IPAddress}}{{end}}' "${SERVER_CONTAINER_ID}")
if [ -z "${NFS_SERVER_IP}" ]; then
    echo "ERROR: Failed to determine NFS server IP on network ${NETWORK_NAME}."
    docker logs "${SERVER_CONTAINER_ID}"
    exit 1
fi
echo "INFO: NFS server is up at ${NFS_SERVER_IP}:${EXPORT_PATH}"

echo "INFO: Running NFS client workload through Docker Compose..."
"${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" run --rm nfs-client

echo "INFO: Verifying test file from server-side volume..."
"${COMPOSE_CMD[@]}" --project-name "${PROJECT_NAME}" --file "${COMPOSE_FILE_PATH}" run --rm nfs-checker

echo "INFO: Standalone NFS server/client test passed."
