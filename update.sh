#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="xiaotianwm"
REPO_NAME="goRtmp"
ASSET_NAME="goRtmp-linux-amd64.tar.gz"
INSTALL_DIR="${INSTALL_DIR:-/opt/goRtmp}"
SERVICE_NAME="${SERVICE_NAME:-goRtmp}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${ASSET_NAME}"

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 1
  fi
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "please run as root" >&2
    exit 1
  fi
}

stop_existing_processes() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\\.service"; then
    systemctl stop "${SERVICE_NAME}" || true
  fi

  kill_matching_binary "${INSTALL_DIR}/server/server"
  kill_matching_binary "${INSTALL_DIR}/web/web"

  rm -f "${INSTALL_DIR}/server/.server.pid" "${INSTALL_DIR}/web/.web.pid"
}

kill_matching_binary() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    return 0
  fi

  local resolved_target
  resolved_target="$(readlink -f "$target")"

  for proc in /proc/[0-9]*; do
    [[ -L "$proc/exe" ]] || continue
    local exe_path
    exe_path="$(readlink "$proc/exe" 2>/dev/null || true)"
    if [[ "$exe_path" == "$resolved_target" || "$exe_path" == "$resolved_target (deleted)" ]]; then
      kill -9 "${proc##*/}" 2>/dev/null || true
    fi
  done
}

write_service_file() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=goRtmp service
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start.sh --foreground
ExecStop=${INSTALL_DIR}/stop.sh
Restart=always
RestartSec=2
KillMode=control-group
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

copy_release_files() {
  local package_root="$1"

  mkdir -p "${INSTALL_DIR}/server" "${INSTALL_DIR}/web"
  rm -rf "${INSTALL_DIR}/web/dist"

  cp -f "${package_root}/start.sh" "${INSTALL_DIR}/start.sh"
  cp -f "${package_root}/stop.sh" "${INSTALL_DIR}/stop.sh"
  cp -f "${package_root}/server/server" "${INSTALL_DIR}/server/server"
  cp -f "${package_root}/server/app.env.example" "${INSTALL_DIR}/server/app.env.example"
  cp -f "${package_root}/web/web" "${INSTALL_DIR}/web/web"
  cp -f "${package_root}/web/app.env.example" "${INSTALL_DIR}/web/app.env.example"

  chmod +x \
    "${INSTALL_DIR}/start.sh" \
    "${INSTALL_DIR}/stop.sh" \
    "${INSTALL_DIR}/server/server" \
    "${INSTALL_DIR}/web/web"

  if [[ -f "${INSTALL_DIR}/web/app.env" ]]; then
    sed -i '/^STATIC_DIR=/d' "${INSTALL_DIR}/web/app.env" || true
  fi

  if [[ -f "${INSTALL_DIR}/server/app.env" ]] && grep -q '^FFMPEG_PATH=\./bin/ffmpeg\.exe$' "${INSTALL_DIR}/server/app.env"; then
    sed -i 's#^FFMPEG_PATH=\./bin/ffmpeg\.exe$#FFMPEG_PATH=ffmpeg#' "${INSTALL_DIR}/server/app.env"
  fi
}

main() {
  ensure_root
  need_cmd curl
  need_cmd tar
  need_cmd systemctl

  if [[ ! -d "${INSTALL_DIR}" ]]; then
    echo "install dir not found: ${INSTALL_DIR}" >&2
    echo "run install.sh first" >&2
    exit 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT

  local archive_path="${tmp_dir}/${ASSET_NAME}"
  echo "downloading ${DOWNLOAD_URL}"
  curl -fL "${DOWNLOAD_URL}" -o "${archive_path}"

  tar -xzf "${archive_path}" -C "${tmp_dir}"
  local package_root="${tmp_dir}/goRtmp"
  if [[ ! -d "${package_root}" ]]; then
    echo "invalid package layout: ${package_root} not found" >&2
    exit 1
  fi

  stop_existing_processes
  copy_release_files "${package_root}"
  write_service_file

  systemctl daemon-reload
  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"

  echo "updated ${INSTALL_DIR}"
  echo "service: ${SERVICE_NAME}"
}

main "$@"
