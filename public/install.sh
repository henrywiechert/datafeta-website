#!/bin/sh
# Data Slicer server installer.
#
#   curl -fsSL https://datafeta.io/install.sh | sh
#   curl -fsSL https://datafeta.io/install.sh | sh -s -- --uninstall
#
# Pulls the Data Slicer Docker image and runs it as a background container.
# Re-running the script upgrades to the latest image and keeps your data.
#
# Environment overrides:
#   DATAFETA_PORT   host port                (default: 8100)
#   DATAFETA_BIND   host address to bind     (default: 127.0.0.1; use 0.0.0.0 to expose on the network)
#   DATAFETA_HOME   data directory           (default: $HOME/.datafeta)
#   DATAFETA_IMAGE  image to run             (default: ghcr.io/henrywiechert/data-slicer:latest)
#   DATAFETA_NAME   container name           (default: datafeta)

set -eu

PORT="${DATAFETA_PORT:-8100}"
BIND="${DATAFETA_BIND:-127.0.0.1}"
HOME_DIR="${DATAFETA_HOME:-$HOME/.datafeta}"
IMAGE="${DATAFETA_IMAGE:-ghcr.io/henrywiechert/data-slicer:latest}"
NAME="${DATAFETA_NAME:-datafeta}"

info() { printf '==> %s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required but not installed. See https://docs.docker.com/get-docker/"
  docker info >/dev/null 2>&1 || die "Docker is installed but the daemon is not reachable (is it running, and do you have permission?)."
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$NAME"
}

uninstall() {
  need_docker
  if container_exists; then
    info "Removing container '$NAME'"
    docker rm -f "$NAME" >/dev/null
  else
    info "Container '$NAME' not found"
  fi
  info "Your data was left in $HOME_DIR (delete it manually if you no longer need it)"
}

wait_healthy() {
  url="http://127.0.0.1:${PORT}/api/v1/health"
  i=0
  while [ "$i" -lt 60 ]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      err "Container stopped unexpectedly. Last logs:"
      docker logs --tail 30 "$NAME" >&2 || true
      return 1
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

install() {
  need_docker

  case "$PORT" in
    ''|*[!0-9]*) die "DATAFETA_PORT must be a number (got '$PORT')" ;;
  esac

  mkdir -p "$HOME_DIR/snapshots"

  info "Pulling $IMAGE"
  if ! docker pull "$IMAGE"; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Could not pull $IMAGE"
    info "Pull failed; using local image $IMAGE"
  fi

  if container_exists; then
    info "Replacing existing container '$NAME'"
    docker rm -f "$NAME" >/dev/null
  fi

  info "Starting Data Slicer on ${BIND}:${PORT}"
  docker run -d \
    --name "$NAME" \
    --restart unless-stopped \
    -p "${BIND}:${PORT}:8000" \
    -e LOG_LEVEL=info \
    -e PYTHONUNBUFFERED=1 \
    -e SNAPSHOT_STORAGE_DIR=/app/data/snapshots \
    -v "$HOME_DIR/snapshots:/app/data/snapshots" \
    "$IMAGE" >/dev/null || die "Could not start the container (is port $PORT already in use? Try DATAFETA_PORT=...)"

  if wait_healthy; then
    info "Data Slicer is running: http://localhost:${PORT}"
  else
    err "Data Slicer did not become healthy in time. Check: docker logs $NAME"
    exit 1
  fi

  cat <<EOF

Manage it with:
  docker logs -f $NAME      # view logs
  docker stop $NAME         # stop
  docker start $NAME        # start again
Upgrade:   curl -fsSL https://datafeta.io/install.sh | sh
Uninstall: curl -fsSL https://datafeta.io/install.sh | sh -s -- --uninstall
EOF
}

case "${1:-}" in
  --uninstall) uninstall ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
  "") install ;;
  *) die "Unknown option: $1" ;;
esac
