#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# install-server.sh — Install Unica as a remote MCP server
# with SSE transport in a local network.
#
# Usage:
#   sudo ./install-server.sh [options]
#
# Options:
#   -p, --port PORT       HTTP port (default: 3001)
#   --host HOST           Listen interface (default: 0.0.0.0)
#   -u, --unica-dir PATH  Path to installed Unica (default: ~/.local/share/opencode/unica)
#   -y, --yes             Non-interactive mode
#   --help                Show this help
# ============================================================

SERVER_PORT=3001
HOST="0.0.0.0"
UNICA_DIR=""
ASSUME_YES=0
FORK_REPO="vitebc/unica"

usage() {
    cat <<EOF
Usage: sudo ./install-server.sh [options]

Options:
  -p, --port PORT       HTTP port (default: 3001)
  --host HOST           Listen interface (default: 0.0.0.0)
  -u, --unica-dir PATH  Path to installed Unica (default: ~/.local/share/opencode/unica)
  -y, --yes             Non-interactive mode
  --help                Show this help
EOF
    exit 0
}

msg()  { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)        SERVER_PORT="$2"; shift 2 ;;
        --host)           HOST="$2"; shift 2 ;;
        -u|--unica-dir)   UNICA_DIR="$2"; shift 2 ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        --help)           usage ;;
        *)                err "Unknown argument: $1" ;;
    esac
done

TARGET=""
detect_target() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}-${arch}" in
        Linux-x86_64|Linux-amd64)   TARGET="linux-x64" ;;
        Darwin-arm64|Darwin-aarch64) TARGET="darwin-arm64" ;;
        Darwin-x86_64|Darwin-amd64)  TARGET="darwin-arm64" ;;
        *) err "Unsupported platform: ${os}-${arch}" ;;
    esac
    msg "Target: ${TARGET}"
}
detect_target

RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME="$(eval echo "~$RUN_USER")"
msg "Service user: ${RUN_USER} (home: ${RUN_HOME})"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$UNICA_DIR" ]]; then
    UNICA_DIR="${RUN_HOME}/.local/share/opencode/unica"
fi
UNICA_BIN="$UNICA_DIR/unica"

check_sudo() {
    if ! command -v sudo &>/dev/null; then
        if [[ "$(id -u)" -ne 0 ]]; then
            err "sudo is required. Run with sudo or as root."
        fi
    fi
}

PKG_INSTALL=""
OS_FAMILY=""
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="sudo apt-get install -y"; OS_FAMILY="debian"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="sudo dnf install -y"; OS_FAMILY="fedora"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="sudo yum install -y"; OS_FAMILY="rhel"
    elif command -v pacman &>/dev/null; then
        PKG_INSTALL="sudo pacman -S --noconfirm"; OS_FAMILY="arch"
    elif command -v zypper &>/dev/null; then
        PKG_INSTALL="sudo zypper install -y"; OS_FAMILY="suse"
    elif command -v brew &>/dev/null; then
        PKG_INSTALL="brew install"; OS_FAMILY="macos"
    else
        err "No supported package manager found"
    fi
    msg "OS family: ${OS_FAMILY}"
}

install_system_pkg() {
    local pkg_name="$1"
    if command -v "$pkg_name" &>/dev/null; then return 0; fi
    msg "Installing ${pkg_name}..."
    local cmd="$PKG_INSTALL"
    if [[ "$(id -u)" -eq 0 ]]; then cmd="$(echo "$cmd" | sed 's/^sudo //')"; fi
    $cmd "$pkg_name"
}

install_unica() {
    if [[ -f "$UNICA_BIN" ]]; then
        msg "Unica already installed at ${UNICA_BIN}"
        return 0
    fi
    if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
        msg "Running install.sh..."
        bash "$SCRIPT_DIR/install.sh" --unica-dir "$UNICA_DIR" --install-skills $([[ "$ASSUME_YES" -eq 1 ]] && echo "-y")
    else
        msg "Cloning and building from ${FORK_REPO}..."
        local repo_dir="$SCRIPT_DIR/unica-source"
        if [[ ! -d "$repo_dir" ]]; then
            git clone --depth 1 "https://github.com/${FORK_REPO}.git" "$repo_dir"
        fi
        local target_dir="$repo_dir/target"
        if [[ -d "$target_dir" ]]; then
            local owner
            owner="$(stat -c '%u' "$target_dir" 2>/dev/null || stat -f '%u' "$target_dir" 2>/dev/null)"
            if [[ "$owner" != "$(id -u)" ]]; then
                chown -R "$(id -u):$(id -g)" "$target_dir" 2>/dev/null || sudo chown -R "$(id -u):$(id -g)" "$target_dir"
            fi
        fi
        (cd "$repo_dir" && cargo build --release --package unica-coder --bin unica)
        mkdir -p "$(dirname "$UNICA_BIN")"
        rm -f "$UNICA_BIN"
        cp "$repo_dir/target/release/unica" "$UNICA_BIN"
        chmod +x "$UNICA_BIN"
        local skills_src="$repo_dir/plugins/unica/skills"
        if [[ -d "$skills_src" ]]; then
            local skills_dst="$UNICA_DIR/skills"
            mkdir -p "$skills_dst"
            cp -r "$skills_src"/* "$skills_dst/"
            msg "Skills copied to ${skills_dst}"
        fi
    fi
    if [[ ! -f "$UNICA_BIN" ]]; then err "Unica binary not found at ${UNICA_BIN}"; fi
    msg "Unica ready: ${UNICA_BIN}"
}

install_nodejs() {
    if command -v node &>/dev/null; then msg "Node.js already installed: $(node --version)"; return 0; fi
    msg "Installing Node.js..."
    case "$OS_FAMILY" in
        debian)
            if [[ "$ASSUME_YES" -eq 0 ]]; then
                echo ""; echo "Node.js will be installed via NodeSource setup."
                read -r -p "Proceed? [Y/n] " reply
                case "$reply" in n|N|no|NO) err "Aborted by user" ;; esac
            fi
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
            sudo apt-get install -y nodejs
            ;;
        fedora) install_system_pkg "nodejs"; command -v npm &>/dev/null || install_system_pkg "npm" ;;
        rhel)   sudo dnf module enable -y nodejs:22 2>/dev/null || true; install_system_pkg "nodejs"; command -v npm &>/dev/null || install_system_pkg "npm" ;;
        arch)   install_system_pkg "nodejs"; install_system_pkg "npm" ;;
        suse)   install_system_pkg "nodejs22" 2>/dev/null || install_system_pkg "nodejs"; command -v npm &>/dev/null || install_system_pkg "npm22" 2>/dev/null || install_system_pkg "npm" ;;
        macos)  install_system_pkg "node" ;;
    esac
    msg "Node.js installed: $(node --version), npm: $(npm --version)"
}

install_supergateway() {
    if command -v supergateway &>/dev/null; then
        msg "supergateway already installed"
        return 0
    fi
    msg "Installing supergateway..."
    if [[ "$(id -u)" -eq 0 ]]; then npm install -g supergateway
    else sudo npm install -g supergateway; fi
    if ! command -v supergateway &>/dev/null; then err "supergateway installation failed"; fi
    msg "supergateway installed"
}

create_systemd_service() {
    local service_file="/etc/systemd/system/unica-mcp.service"
    if [[ -f "$service_file" ]] && grep -q "ExecStart.*unica" "$service_file" 2>/dev/null; then
        msg "systemd service already exists: ${service_file}"
        return 0
    fi
    msg "Creating systemd service: ${service_file}"
    local supergateway_path; supergateway_path="$(command -v supergateway)"
    sudo tee "$service_file" > /dev/null << SERVICEEOF
[Unit]
Description=Unica MCP Server (SSE)
Documentation=https://github.com/vitebc/unica
After=network.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=${supergateway_path} --port ${SERVER_PORT} --stdio ${UNICA_BIN} --ssePath /mcp --messagePath /mcp --healthEndpoint /health
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICEEOF
    msg "systemd service created"
}

start_service() {
    msg "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    sudo systemctl enable unica-mcp
    sudo systemctl restart unica-mcp
    sleep 2
    if sudo systemctl is-active --quiet unica-mcp; then
        msg "Service is active"
    else
        warn "Service is not active. Checking logs..."
        sudo journalctl -u unica-mcp --no-pager -n 20 || true
        err "Service failed to start"
    fi
}

verify_server() {
    msg "Verifying..."
    sleep 1
    if curl -sf "http://${HOST}:${SERVER_PORT}/health" > /dev/null 2>&1; then
        msg "Health check OK"
    else
        if ss -tlnp "sport = :${SERVER_PORT}" 2>/dev/null | grep -q LISTEN; then
            msg "Port ${SERVER_PORT} is listening"
        else
            warn "Port ${SERVER_PORT} is not listening"
        fi
    fi
    sudo systemctl status unica-mcp --no-pager -l 2>&1 | head -15 || true
}

print_summary() {
    local ip
    ip="$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')"
    [[ -z "$ip" ]] && ip="<server-ip>"
    echo ""
    echo "=============================================="
    echo " Unica MCP Server installed!"
    echo "=============================================="
    echo ""
    echo " Server URL:    http://${ip}:${SERVER_PORT}/mcp"
    echo " Binary:        ${UNICA_BIN}"
    echo " Service:       unica-mcp"
    echo " Logs:          sudo journalctl -u unica-mcp -f"
    echo ""
    echo " Add to opencode.json on your workstation:"
    echo '  { "mcp": { "unica": { "type": "remote",'
    echo '    "url": "http://'${ip}:${SERVER_PORT}'/mcp",'
    echo '    "enabled": true } } }'
    echo ""
    echo " Skills: ${UNICA_DIR}/skills/"
    echo "   rsync -avz ${RUN_USER}@${ip}:${UNICA_DIR}/skills/ .opencode/skills/"
    echo "=============================================="
}

main() {
    echo ""; echo "=== Unica MCP Server Installer (SSE) ==="; echo ""
    check_sudo; detect_pkg_manager
    install_unica; install_nodejs; install_supergateway
    create_systemd_service; start_service
    verify_server; print_summary
}

main "$@"
