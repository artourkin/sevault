#!/bin/bash
set -euo pipefail

PLUGIN_NAME="${PLUGIN_NAME:-sevault}"
COMPOSE_FILE="${COMPOSE_FILE:-tests/docker-compose.plugin-test.yml}"
PACKAGE_DIR="sevault-plugin-package"
MOUNT_HELPER_IMAGE="${MOUNT_HELPER_IMAGE:-alpine:3.20}"
GO_BUILDER_IMAGE="${GO_BUILDER_IMAGE:-golang:1.22-alpine}"
REQUIRE_NFS_KERNEL_MODULE="${REQUIRE_NFS_KERNEL_MODULE:-true}"

cleanup() {
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans >/dev/null 2>&1 || true
    docker plugin disable "${PLUGIN_NAME}" >/dev/null 2>&1 || true
    docker plugin rm "${PLUGIN_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info() {
    echo "==> $*"
}

ensure_go_binary() {
    info "Building sevaultd"
    if CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o sevaultd ./cmd/sevaultd 2>/dev/null; then
        return
    fi
    info "Local Go build failed; using Docker builder"
    docker run --rm \
        -v "$(pwd)":/workspace \
        -w /workspace \
        "${GO_BUILDER_IMAGE}" \
        /bin/sh -c "CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o sevaultd ./cmd/sevaultd"
}

write_mount_helper() {
    info "Fetching mount.nfs helper from ${MOUNT_HELPER_IMAGE}"
    docker run --rm "${MOUNT_HELPER_IMAGE}" \
        /bin/sh -c "apk add --no-cache nfs-utils >/dev/null && cat /sbin/mount.nfs" \
        > "${PACKAGE_DIR}/rootfs/sbin/mount.nfs"
    chmod +x "${PACKAGE_DIR}/rootfs/sbin/mount.nfs"
}

package_plugin() {
    info "Preparing plugin rootfs"
    rm -rf "${PACKAGE_DIR}"
    mkdir -p "${PACKAGE_DIR}/rootfs/sbin"
    mkdir -p "${PACKAGE_DIR}/rootfs/var/lib/sevault/mounts"
    cp sevaultd "${PACKAGE_DIR}/rootfs/sevaultd"
    write_mount_helper
    cp plugin-config.json "${PACKAGE_DIR}/config.json"
}

install_plugin() {
    info "Installing plugin ${PLUGIN_NAME}"
    docker plugin disable "${PLUGIN_NAME}" >/dev/null 2>&1 || true
    docker plugin rm "${PLUGIN_NAME}" >/dev/null 2>&1 || true
    docker plugin create "${PLUGIN_NAME}" "${PACKAGE_DIR}"
    docker plugin enable "${PLUGIN_NAME}"
}

ensure_nfs_kernel_modules() {
    if [ "${REQUIRE_NFS_KERNEL_MODULE}" != "true" ]; then
        return
    fi
    local missing=()
    for mod in nfs nfsd; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "${mod}"; then
            continue
        fi
        info "Loading kernel module ${mod}..."
        if modprobe "${mod}" 2>/dev/null; then
            continue
        fi
        if command -v sudo >/dev/null 2>&1 && sudo modprobe "${mod}"; then
            continue
        fi
        missing+=("${mod}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing kernel modules: ${missing[*]} (try: sudo modprobe <module>)." >&2
        exit 1
    fi
}

start_nfs_stack() {
    info "Starting NFS server stack"
    ensure_nfs_kernel_modules

    export TESTS_NFS_SERVER_IMAGE="${TESTS_NFS_SERVER_IMAGE:-erichough/nfs-server:latest}"
    export TESTS_NFS_EXPORT_VOLUME="${TESTS_NFS_EXPORT_VOLUME:-sevault-test-nfs-share}"
    export TESTS_NFS_EXPORT_PATH="${TESTS_NFS_EXPORT_PATH:-/exports}"
    export TESTS_NETWORK_NAME="${TESTS_NETWORK_NAME:-test-plugin-net}"
    export TESTS_CLIENT_IMAGE="${TESTS_CLIENT_IMAGE:-alpine:3.20}"
    export TESTS_PLUGIN_NAME="${PLUGIN_NAME}"
    export TESTS_NFS_VERSION="${TESTS_NFS_VERSION:-3}"

    docker compose -f "${COMPOSE_FILE}" up -d test-nfs-server
    sleep 5
    local server_id
    server_id=$(docker compose -f "${COMPOSE_FILE}" ps -q test-nfs-server)
    if [ -z "${server_id}" ]; then
        echo "Failed to discover NFS server container ID" >&2
        exit 1
    fi
    TESTS_NFS_SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${server_id}")
    if [ -z "${TESTS_NFS_SERVER_IP}" ]; then
        echo "Failed to read server IP address" >&2
        exit 1
    fi
    export TESTS_NFS_SERVER_IP
}

run_test() {
    export TESTS_PLUGIN_NAME="${PLUGIN_NAME}"
    info "Running client test"
    docker compose -f "${COMPOSE_FILE}" up --abort-on-container-exit test-nfs-client
}

ensure_go_binary
package_plugin
install_plugin
start_nfs_stack
run_test

info "Plugin test completed successfully"
