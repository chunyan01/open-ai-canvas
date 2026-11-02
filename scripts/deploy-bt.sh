#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTTP_PORT="${CANVAS_HTTP_PORT:-3000}"
DOMAIN="${CANVAS_DOMAIN:-}"
PUBLIC_URL="${CANVAS_PUBLIC_URL:-}"
IMPORT_DATA_DIR="${IMPORT_DATA_DIR:-}"

fail() {
    printf '\nDeployment failed: %s\n' "$1" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "run this script with sudo"
    [[ "$(uname -s)" == "Linux" ]] || fail "this script only supports Linux"
}

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl git openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl git openssl
    else
        fail "install curl, git and openssl manually"
    fi
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        return
    fi
    local installer
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    sh "$installer"
    rm -f "$installer"
    systemctl enable --now docker
    docker compose version >/dev/null 2>&1 || fail "Docker Compose installation failed"
}

prepare_env() {
    cd "$ROOT_DIR"
    if [[ -f .env ]]; then
        return
    fi

    local database_password agent_token updater_token public_base_url cors_origin
    database_password="$(openssl rand -hex 32)"
    agent_token="$(openssl rand -hex 32)"
    updater_token="$(openssl rand -hex 32)"
    if [[ -n "$DOMAIN" ]]; then
        public_base_url="https://${DOMAIN}"
        cors_origin="$public_base_url"
    elif [[ -n "$PUBLIC_URL" ]]; then
        public_base_url="${PUBLIC_URL%/}"
        cors_origin="$public_base_url"
    else
        public_base_url=""
        cors_origin=""
    fi

    umask 077
    cat >.env <<EOF
POSTGRES_DB=open_ai_canvas
POSTGRES_USER=open_ai_canvas
POSTGRES_PASSWORD=${database_password}
DATABASE_URL=postgresql://open_ai_canvas:${database_password}@postgres:5432/open_ai_canvas?sslmode=disable
CANVAS_HTTP_PORT=${HTTP_PORT}
CANVAS_IMAGE_TAG=source
CANVAS_BACKEND_IMAGE=open-ai-canvas-backend:server
CANVAS_WEB_IMAGE=open-ai-canvas-web:server
CANVAS_YINGCE_AGENT_IMAGE=open-ai-canvas-yingce-agent:server
YINGCE_AGENT_TOKEN=${agent_token}
CANVAS_UPDATER_TOKEN=${updater_token}
CANVAS_REGISTRATION_ENABLED=false
CANVAS_ALLOW_PRIVATE_UPSTREAMS=false
CANVAS_ALLOWED_PRIVATE_UPSTREAM_HOSTS=
CANVAS_PUBLIC_BASE_URL=${public_base_url}
CANVAS_CORS_ORIGINS=${cors_origin}
CANVAS_WORKER_CONCURRENCY=1
CANVAS_CHANNEL_CONCURRENCY=1
YINGCE_AGENT_MAX_SESSIONS=3
YINGCE_AGENT_NODE_MEMORY_MB=384
GOPROXY=https://goproxy.cn,direct
EOF
    chmod 600 .env
}

deploy() {
    cd "$ROOT_DIR"
    local compose=(
        docker compose
        --env-file .env
        -f docker-compose.deploy.yml
        -f docker-compose.build.yml
    )

    docker compose --env-file .env -f docker-compose.deploy.yml -f docker-compose.build.yml config --quiet
    COMPOSE_PARALLEL_LIMIT=1 "${compose[@]}" build migrate backend web yingce-agent

    if [[ -n "$IMPORT_DATA_DIR" ]]; then
        [[ -f "${IMPORT_DATA_DIR}/open_ai_canvas.db" ]] || fail "IMPORT_DATA_DIR does not contain open_ai_canvas.db"
        [[ -f "${IMPORT_DATA_DIR}/.settings-key" ]] || fail "IMPORT_DATA_DIR does not contain .settings-key"
        IMPORT_DATA_DIR="$(cd "$IMPORT_DATA_DIR" && pwd)"

        printf '\nStarting an empty PostgreSQL database for data import...\n'
        "${compose[@]}" up -d --wait --wait-timeout 180 postgres redis

        printf '\nImporting local SQLite data and files...\n'
        "${compose[@]}" run --rm --no-deps \
            -v "${IMPORT_DATA_DIR}:/import:ro" \
            --entrypoint sh backend -c \
            'cp -a /import/. /data/ && SQLITE_SOURCE_PATH=/data/open_ai_canvas.db migrate-sqlite-postgres'
    fi

    "${compose[@]}" up -d --remove-orphans --wait --wait-timeout 600
}

main() {
    require_root
    install_packages
    install_docker
    prepare_env
    deploy

    printf '\nDeployment complete.\n'
    printf 'Open: http://SERVER_IP:%s\n' "$HTTP_PORT"
    printf 'Directory: %s\n' "$ROOT_DIR"
    printf 'The first registered account becomes the administrator.\n'
}

main "$@"
