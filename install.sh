#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# install.sh — Build vitebc/unica + runtime tools and configure
# opencode to use them as an MCP server.
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --unica-dir PATH       Installation directory (default: ~/.local/share/opencode/unica)
#   --repo-root PATH       Path to unica repo checkout (default: script's parent)
#   --build-all            Build v8-runner and bsl-analyzer from source too
#   --skip-verify          Skip SHA-256 verification
#   --opencode-config PATH Path to opencode.json for auto-config (default: auto-detect)
#   --install-skills       Copy skills into .opencode/skills/ of current project
#   -y, --yes              Auto-install missing dependencies without prompt
#   --help                 Show this help
# ============================================================

REPO_ROOT=""
UNICA_DIR=""
BUILD_ALL=0
SKIP_VERIFY=0
OPENCODE_CONFIG=""
INSTALL_SKILLS=0
ASSUME_YES=0
FORK_REPO="vitebc/unica"

usage() {
    cat <<EOF
Usage: ./install.sh [options]

Options:
  --unica-dir PATH       Installation directory (default: ~/.local/share/opencode/unica)
  --repo-root PATH       Path to unica repo checkout (default: script's parent)
  --build-all            Build v8-runner and bsl-analyzer from source too
  --skip-verify          Skip SHA-256 verification
  --opencode-config PATH Path to opencode.json for auto-config (default: auto-detect)
  --install-skills       Copy skills into .opencode/skills/ of current project
  -y, --yes              Auto-install missing dependencies without prompt
  --help                 Show this help
EOF
    exit 0
}

msg()  { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unica-dir)     UNICA_DIR="$2"; shift 2 ;;
        --repo-root)     REPO_ROOT="$2"; shift 2 ;;
        --build-all)     BUILD_ALL=1;    shift ;;
        --skip-verify)   SKIP_VERIFY=1;  shift ;;
        --opencode-config) OPENCODE_CONFIG="$2"; shift 2 ;;
        --install-skills) INSTALL_SKILLS=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        --help|-h)       usage ;;
        *)               err "Unknown argument: $1" ;;
    esac
done

# ---- Default paths ----
THIS_SRC="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$( (cd "$(dirname "$THIS_SRC")" && pwd) 2>/dev/null || echo "$PWD" )"
if [[ -z "$REPO_ROOT" ]]; then
    if [[ -f "$SCRIPT_DIR/Cargo.toml" ]] && grep -q 'unica-coder' "$SCRIPT_DIR/Cargo.toml" 2>/dev/null; then
        REPO_ROOT="$SCRIPT_DIR"
    else
        REPO_ROOT="$SCRIPT_DIR/unica-source"
    fi
fi

if [[ -z "$UNICA_DIR" ]]; then
    UNICA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/unica"
fi

TARGET=""
EXE=""

detect_target() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}-${arch}" in
        Linux-x86_64|Linux-amd64)   TARGET="linux-x64"; EXE="" ;;
        Darwin-arm64|Darwin-aarch64) TARGET="darwin-arm64"; EXE="" ;;
        Darwin-x86_64|Darwin-amd64)  TARGET="darwin-arm64"; EXE="" ;;
        *) err "Unsupported platform: ${os}-${arch}" ;;
    esac
    msg "Target: ${TARGET}"
}

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_INSTALL="sudo apt-get install -y"
        PKG_QUERY="dpkg -l"
        OS_FAMILY="debian"
    elif command -v dnf &>/dev/null; then
        PKG_INSTALL="sudo dnf install -y"
        PKG_QUERY="rpm -q"
        OS_FAMILY="fedora"
    elif command -v yum &>/dev/null; then
        PKG_INSTALL="sudo yum install -y"
        PKG_QUERY="rpm -q"
        OS_FAMILY="rhel"
    elif command -v pacman &>/dev/null; then
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PKG_QUERY="pacman -Q"
        OS_FAMILY="arch"
    elif command -v zypper &>/dev/null; then
        PKG_INSTALL="sudo zypper install -y"
        PKG_QUERY="rpm -q"
        OS_FAMILY="suse"
    elif command -v brew &>/dev/null; then
        PKG_INSTALL="brew install"
        PKG_QUERY="brew list"
        OS_FAMILY="macos"
    else
        err "No supported package manager found (apt, dnf, yum, pacman, zypper, brew)"
    fi
}

install_system_pkg() {
    local pkg_name="$1"
    if [[ "$ASSUME_YES" -eq 0 ]]; then
        echo ""
        echo "The following package needs to be installed: ${pkg_name}"
        read -r -p "Proceed with installation? [Y/n] " reply
        case "$reply" in
            n|N|no|NO) err "Aborted by user" ;;
        esac
    fi
    msg "Installing ${pkg_name}..."
    local cmd="$PKG_INSTALL"
    if [[ "$(id -u)" -eq 0 ]]; then
        cmd="$(echo "$cmd" | sed 's/^sudo //')"
    fi
    if echo "$cmd" | grep -q '^sudo'; then
        if ! command -v sudo &>/dev/null; then
            err "sudo is required but not available. Run as root or install sudo."
        fi
    fi
    $cmd "$pkg_name"
}

install_rust() {
    if command -v cargo &>/dev/null; then
        return 0
    fi
    if [[ "$ASSUME_YES" -eq 0 ]]; then
        echo ""
        echo "Rust (rustup + cargo) needs to be installed."
        read -r -p "Proceed with rustup installation? [Y/n] " reply
        case "$reply" in
            n|N|no|NO) err "Aborted by user" ;;
        esac
    fi
    msg "Installing Rust via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi
    msg "Rust installed"
}

check_python_venv() {
    if ! python3 -m venv --help &>/dev/null; then
        case "$OS_FAMILY" in
            debian) install_system_pkg "python3-venv" ;;
            fedora|rhel) install_system_pkg "python3-virtualenv" ;;
            arch) install_system_pkg "python-virtualenv" ;;
            suse) install_system_pkg "python311-venv" ;;
            macos)
                warn "python3-venv not available, trying pip install"
                python3 -m pip install --user virtualenv 2>/dev/null || true
                ;;
        esac
    fi
    if ! python3 -m pip --version &>/dev/null 2>&1; then
        case "$OS_FAMILY" in
            debian) install_system_pkg "python3-pip" ;;
            fedora|rhel) install_system_pkg "python3-pip" ;;
            arch) install_system_pkg "python-pip" ;;
            suse) install_system_pkg "python311-pip" ;;
            macos) ;;
        esac
    fi
}

check_deps() {
    detect_pkg_manager
    msg "Package manager: ${OS_FAMILY}"
    case "$OS_FAMILY" in
        debian)
            for pkg in curl git python3; do command -v "$pkg" &>/dev/null || install_system_pkg "$pkg"; done ;;
        fedora|rhel)
            for pkg in curl git python3; do command -v "$pkg" &>/dev/null || install_system_pkg "$pkg"; done ;;
        arch)
            for pkg in curl git python; do command -v "$pkg" &>/dev/null || install_system_pkg "$pkg"; done ;;
        suse)
            for pkg in curl git python3; do command -v "$pkg" &>/dev/null || install_system_pkg "$pkg"; done ;;
        macos)
            for pkg in curl git python3; do command -v "$pkg" &>/dev/null || install_system_pkg "$pkg"; done ;;
    esac
    check_python_venv
    install_rust
    local missing=()
    for cmd in curl git python3 cargo; do
        if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd"); fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Still missing dependencies after auto-install: ${missing[*]}. Install manually."
    fi
    msg "All core dependencies found"
}

github_api_get() {
    local url="$1" response
    response="$(curl -sfL "$url")" || err "GitHub API request failed: ${url}. Check network or API rate limit."
    echo "$response"
}

github_latest_tag() {
    local repo="$1"
    github_api_get "https://api.github.com/repos/${repo}/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])"
}

github_release_asset_url() {
    local repo="$1" tag="$2" pattern="$3"
    github_api_get "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print([a['browser_download_url'] for a in d.get('assets',[]) if '$pattern' in a['name']][0])"
}

download_verify() {
    local url="$1" dest="$2" expected_hash="$3"
    msg "Downloading ${url##*/}"
    mkdir -p "$(dirname "$dest")"
    if ! curl -fL --connect-timeout 30 --max-time 600 "$url" -o "$dest"; then
        err "Download failed: ${url}"
    fi
    if [[ -n "$expected_hash" && "$SKIP_VERIFY" -eq 0 ]]; then
        local actual
        actual="$(sha256sum "$dest" | cut -d' ' -f1)"
        if [[ "$actual" != "$expected_hash" ]]; then
            err "SHA-256 mismatch for ${dest}: expected ${expected_hash}, got ${actual}"
        fi
        msg "Checksum OK"
    fi
}

sha256_file() { sha256sum "$1" | cut -d' ' -f1; }

build_unica() {
    msg "Building unica from source (cargo build --release)"
    local target_dir="$REPO_ROOT/target"
    if [[ -d "$target_dir" ]]; then
        local owner
        owner="$(stat -c '%u' "$target_dir" 2>/dev/null || stat -f '%u' "$target_dir" 2>/dev/null)"
        if [[ "$owner" != "$(id -u)" ]]; then
            warn "target/ owned by uid ${owner}, chowning to current user..."
            chown -R "$(id -u):$(id -g)" "$target_dir" 2>/dev/null || \
                sudo chown -R "$(id -u):$(id -g)" "$target_dir"
        fi
    fi
    (cd "$REPO_ROOT" && cargo build --release --package unica-coder --bin unica)
    mkdir -p "$TOOLS_DIR"
    cp "$REPO_ROOT/target/release/unica${EXE}" "$TOOLS_DIR/unica${EXE}"
    chmod +x "$TOOLS_DIR/unica${EXE}"
    msg "unica built: $TOOLS_DIR/unica${EXE}"
}

download_v8_runner() {
    local repo="alkoleft/v8-runner-rust"
    local tag; tag="$(github_latest_tag "$repo")"
    msg "v8-runner latest tag: ${tag}"
    local asset_suffix asset_archive binary_in_archive
    case "$TARGET" in
        linux-x64)     asset_suffix="linux-x86_64-musl";   asset_archive="v8-runner-linux-x86_64-musl.tar.gz"; binary_in_archive="v8-runner" ;;
        darwin-arm64)  asset_suffix="macos-aarch64";       asset_archive="v8-runner-macos-aarch64.tar.gz";     binary_in_archive="v8-runner" ;;
    esac
    local work="$BUILD_ROOT/v8-runner"
    mkdir -p "$work"
    local archive_url sha_url
    archive_url="$(github_release_asset_url "$repo" "$tag" "$asset_archive")"
    sha_url="${archive_url}.sha256"
    local archive_path="$work/$asset_archive"
    download_verify "$archive_url" "$archive_path" ""
    local sha_path="$work/${asset_archive}.sha256"
    curl -fL --connect-timeout 15 --max-time 60 "$sha_url" -o "$sha_path"
    if [[ "$SKIP_VERIFY" -eq 0 ]]; then
        (cd "$work" && sha256sum -c "$(basename "$sha_path")" 2>/dev/null) || {
            warn "sha256sum -c failed, trying manual check"
            local expected actual
            expected="$(awk '{print $1}' "$sha_path")"
            actual="$(sha256_file "$archive_path")"
            if [[ "$expected" != "$actual" ]]; then
                err "v8-runner SHA-256 mismatch: expected ${expected}, got ${actual}"
            fi
        }
        msg "v8-runner checksum OK"
    fi
    local extract_dir="$work/extract"
    rm -rf "$extract_dir"; mkdir -p "$extract_dir"
    tar -xzf "$archive_path" -C "$extract_dir"
    local binary_path
    binary_path="$(find "$extract_dir" -name "$binary_in_archive" -type f 2>/dev/null | head -1)"
    [[ -n "$binary_path" ]] || err "v8-runner binary not found in archive"
    mkdir -p "$TOOLS_DIR"
    cp "$binary_path" "$TOOLS_DIR/v8-runner${EXE}"
    chmod +x "$TOOLS_DIR/v8-runner${EXE}"
    msg "v8-runner installed: $TOOLS_DIR/v8-runner${EXE}"
}

download_bsl_analyzer() {
    local repo="itrous/bsl-analyzer"
    local tag; tag="$(github_latest_tag "$repo")"
    msg "bsl-analyzer latest tag: ${tag}"
    local asset_name
    case "$TARGET" in
        linux-x64)     asset_name="bsl-analyzer-app-linux-amd64" ;;
        darwin-arm64)  asset_name="bsl-analyzer-app-darwin-arm64" ;;
    esac
    local asset_url; asset_url="$(github_release_asset_url "$repo" "$tag" "$asset_name")"
    [[ -n "$asset_url" ]] || err "bsl-analyzer asset not found for ${TARGET}"
    local work="$BUILD_ROOT/bsl-analyzer"
    mkdir -p "$work"
    local dest="$work/$asset_name"
    download_verify "$asset_url" "$dest" ""
    if [[ "$SKIP_VERIFY" -eq 0 ]]; then
        local checksums_url; checksums_url="$(github_release_asset_url "$repo" "$tag" "checksums.txt")"
        if [[ -n "$checksums_url" ]]; then
            local checksums_file="$work/checksums.txt"
            curl -fL --connect-timeout 15 --max-time 60 "$checksums_url" -o "$checksums_file" || warn "checksums.txt download failed"
            if grep -q "$asset_name" "$checksums_file" 2>/dev/null; then
                local expected actual
                expected="$(grep "$asset_name" "$checksums_file" | awk '{print $1}')"
                actual="$(sha256_file "$dest")"
                if [[ "$expected" != "$actual" ]]; then
                    err "bsl-analyzer SHA-256 mismatch: expected ${expected}, got ${actual}"
                fi
                msg "bsl-analyzer checksum OK"
            fi
        fi
    fi
    mkdir -p "$TOOLS_DIR"
    cp "$dest" "$TOOLS_DIR/bsl-analyzer${EXE}"
    chmod +x "$TOOLS_DIR/bsl-analyzer${EXE}"
    msg "bsl-analyzer installed: $TOOLS_DIR/bsl-analyzer${EXE}"
}

build_rlm_tool() {
    local tool_name="$1"
    local repo="Dach-Coin/rlm-tools-bsl"
    local tag; tag="$(github_latest_tag "$repo")"
    msg "${tool_name} latest tag: ${tag}"
    local work="$BUILD_ROOT/${tool_name}"
    local source_dir="$work/source"
    rm -rf "$source_dir"; mkdir -p "$source_dir"
    git clone --depth 1 --branch "$tag" "https://github.com/${repo}.git" "$source_dir"
    local venv_dir="$work/venv"
    local venv_python="$venv_dir/bin/python3"
    [[ -f "$venv_python" ]] || python3 -m venv "$venv_dir"
    msg "Installing ${tool_name} in venv"
    "$venv_dir/bin/pip" install --quiet --upgrade pip
    "$venv_dir/bin/pip" install --quiet pyinstaller
    "$venv_dir/bin/pip" install --quiet "$source_dir"
    local entrypoint_name="$tool_name"
    msg "Resolving entrypoint: ${entrypoint_name}"
    local ep_info
    ep_info="$("$venv_python" -c "
import json, sys
from importlib.metadata import entry_points
eps = entry_points()
if hasattr(eps, 'select'):
    candidates = eps.select(group='console_scripts', name='${entrypoint_name}')
else:
    candidates = [ep for ep in eps.get('console_scripts', []) if ep.name == '${entrypoint_name}']
if not candidates:
    sys.exit(1)
ep = next(iter(candidates))
print(json.dumps({'module': ep.module, 'attr': ep.attr}))
")"
    [[ -n "$ep_info" ]] || err "Entrypoint not found for ${entrypoint_name}"
    local ep_module ep_attr
    ep_module="$(echo "$ep_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['module'])")"
    ep_attr="$(echo "$ep_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['attr'])")"
    msg "Entrypoint: ${ep_module}.${ep_attr}"
    local stub_dir="$work/stub"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/entrypoint.py" << PYEOF
import importlib, sys
MODULE = "${ep_module}"
CALLABLE = "${ep_attr}"
def _load_entrypoint():
    obj = importlib.import_module(MODULE)
    for part in CALLABLE.split('.'):
        obj = getattr(obj, part)
    return obj
if __name__ == '__main__':
    sys.exit(_load_entrypoint()())
PYEOF
    msg "Building ${tool_name} with PyInstaller"
    local pyi_build="$work/pyinstaller-build"
    rm -rf "$pyi_build"
    local collect_pkg="${ep_module%%.*}"
    "$venv_python" -m PyInstaller \
        --onefile --clean --noconfirm \
        --name "${entrypoint_name}" \
        --collect-all "${collect_pkg}" \
        --hidden-import "${ep_module}" \
        --distpath "$pyi_build/dist" \
        --workpath "$pyi_build/work" \
        --specpath "$pyi_build" \
        "$stub_dir/entrypoint.py"
    local produced="$pyi_build/dist/${entrypoint_name}"
    [[ -f "$produced" ]] || produced="$pyi_build/dist/${entrypoint_name}.exe"
    [[ -f "$produced" ]] || err "${tool_name}: PyInstaller output not found"
    mkdir -p "$TOOLS_DIR"
    cp "$produced" "$TOOLS_DIR/${entrypoint_name}${EXE}"
    chmod +x "$TOOLS_DIR/${entrypoint_name}${EXE}"
    msg "${tool_name} installed: $TOOLS_DIR/${entrypoint_name}${EXE}"
    rm -rf "$venv_dir"
}

build_rlm_tools_bsl() { build_rlm_tool "rlm-tools-bsl"; }
build_rlm_bsl_index() { build_rlm_tool "rlm-bsl-index"; }

generate_manifest() {
    mkdir -p "$THIRD_PARTY_DIR"
    local manifest_file="$THIRD_PARTY_DIR/manifest.json"
    msg "Generating manifest: ${manifest_file}"
    python3 -c "
import json, hashlib, os
from pathlib import Path
from datetime import datetime, timezone
tools_dir = Path('${TOOLS_DIR}')
manifest = {'schemaVersion': 2, 'builtAt': None, 'target': '${TARGET}', 'tools': []}
for bin_path in sorted(tools_dir.iterdir()):
    if not bin_path.is_file(): continue
    h = hashlib.sha256()
    with open(bin_path, 'rb') as f:
        for chunk in iter(lambda: f.read(1048576), b''): h.update(chunk)
    manifest['tools'].append({'name': bin_path.name, 'binaryPath': str(bin_path.relative_to(tools_dir)), 'sha256': h.hexdigest()})
manifest['builtAt'] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
os.makedirs('${THIRD_PARTY_DIR}', exist_ok=True)
with open('${THIRD_PARTY_DIR}/manifest.json', 'w', encoding='utf-8') as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2); f.write('\n')
print('Manifest written')
"
    msg "Manifest generated"
}

copy_skills() {
    local src="$REPO_ROOT/plugins/unica/skills"
    if [[ ! -d "$src" ]]; then warn "Skills directory not found: ${src}, skipping"; return; fi
    mkdir -p "$SKILLS_DIR"
    cp -r "$src"/* "$SKILLS_DIR/"
    msg "Skills copied to ${SKILLS_DIR}"
    msg "  mkdir -p .opencode/skills && cp -r ${SKILLS_DIR}/* .opencode/skills/"
}

install_skills_to_project() {
    local project_skills="" dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.opencode" ]]; then project_skills="$dir/.opencode/skills"; break; fi
        dir="$(dirname "$dir")"
    done
    [[ -n "$project_skills" ]] || project_skills="$PWD/.opencode/skills"
    if [[ -d "$SKILLS_DIR" ]]; then
        mkdir -p "$project_skills"
        cp -r "$SKILLS_DIR"/* "$project_skills/"
        msg "Skills installed to ${project_skills}"
    fi
}

detect_opencode_config() {
    [[ -n "$OPENCODE_CONFIG" ]] && { echo "$OPENCODE_CONFIG"; return; }
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        for candidate in "opencode.json" "opencode.jsonc" ".opencode/opencode.json" ".opencode/opencode.jsonc"; do
            [[ -f "$dir/$candidate" ]] && { echo "$dir/$candidate"; return; }
        done
        dir="$(dirname "$dir")"
    done
    echo ""
}

update_opencode_config() {
    local config_path="$1" has_mcp=0
    if [[ -f "$config_path" ]]; then
        python3 -c "import json; data=json.load(open('$config_path')); print('found' if 'mcp' in data and 'unica' in data['mcp'] else '')" 2>/dev/null | grep -q found && has_mcp=1
    fi
    [[ "$has_mcp" -eq 1 ]] && { msg "openCode config already has unica MCP server: ${config_path}"; return; }
    msg "Updating openCode config: ${config_path}"
    local mcp_command="$TOOLS_DIR/unica${EXE}"
    python3 -c "
import json, os
data = json.load(open('$config_path')) if os.path.exists('$config_path') else {}
data.setdefault('mcp', {})['unica'] = {'type': 'local', 'command': ['$mcp_command'], 'enabled': True}
with open('$config_path', 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write('\n')
print('Config updated')
"
    msg "openCode config updated: ${config_path}"
}

verify_installation() {
    local errors=0
    echo ""
    echo "--- Проверка установленных файлов ---"
    echo "  Бинарники ($TOOLS_DIR):"
    for tool in unica v8-runner bsl-analyzer rlm-tools-bsl rlm-bsl-index; do
        local path="$TOOLS_DIR/${tool}${EXE}"
        if [[ -f "$path" ]]; then
            local size
            size="$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null)"
            if [[ "$tool" == "unica" ]]; then
                if "$path" --help 2>&1 | head -1 | grep -qi "unica"; then
                    echo "    [OK]  ${tool} (${size} bytes, запускается)"
                else
                    echo "    [ERR] ${tool} (файл есть, но не запускается)"
                    errors=$((errors + 1))
                fi
            else
                echo "    [OK]  ${tool} (${size} bytes)"
            fi
        else
            echo "    [--]  ${tool} (не установлен)"
            errors=$((errors + 1))
        fi
    done
    echo "  Манифест:"
    local manifest="$THIRD_PARTY_DIR/manifest.json"
    if [[ -f "$manifest" ]]; then
        local count; count="$(python3 -c "import json; print(len(json.load(open('$manifest'))['tools']))" 2>/dev/null || echo "?")"
        echo "    [OK]  manifest.json (${count} инструментов)"
    else
        echo "    [--]  manifest.json (не найден)"; errors=$((errors + 1))
    fi
    echo "  Навыки:"
    if [[ -d "$SKILLS_DIR" ]]; then
        local skill_count; skill_count="$(find "$SKILLS_DIR" -name 'SKILL.md' | wc -l 2>/dev/null || echo "0")"
        echo "    [OK]  skills/ (${skill_count} навыков)"
    else
        echo "    [--]  skills/ (не установлены)"; errors=$((errors + 1))
    fi
    echo ""
    [[ "$errors" -eq 0 ]] && msg "Все компоненты установлены" || warn "${errors} компонентов отсутствуют или повреждены"
}

main() {
    echo ""
    echo "=============================================="
    echo " vitebc/unica — openCode installer"
    echo "=============================================="
    echo ""
    detect_target
    check_deps
    TOOLS_DIR="$UNICA_DIR"
    SKILLS_DIR="$UNICA_DIR/skills"
    THIRD_PARTY_DIR="$UNICA_DIR/third-party"
    BUILD_ROOT="$UNICA_DIR/build"
    msg "Install dir: ${UNICA_DIR}"
    if [[ ! -f "$REPO_ROOT/Cargo.toml" ]]; then
        msg "Cloning ${FORK_REPO} to ${REPO_ROOT}"
        mkdir -p "$(dirname "$REPO_ROOT")"
        git clone --depth 1 "https://github.com/${FORK_REPO}.git" "$REPO_ROOT"
    else
        msg "Using repo at ${REPO_ROOT}"
    fi
    mkdir -p "$BUILD_ROOT" "$TOOLS_DIR"
    build_unica
    download_v8_runner
    download_bsl_analyzer
    build_rlm_tools_bsl
    build_rlm_bsl_index
    [[ "$SKIP_VERIFY" -eq 0 ]] && generate_manifest
    copy_skills
    [[ "$INSTALL_SKILLS" -eq 1 ]] && install_skills_to_project
    local config_file; config_file="$(detect_opencode_config)"
    if [[ -n "$config_file" ]]; then
        update_opencode_config "$config_file"
    else
        warn "No opencode.json found. Create one and add:"
        warn '  "mcp": { "unica": { "type": "local", "command": ["'"$TOOLS_DIR/unica${EXE}"'"], "enabled": true } }'
    fi
    verify_installation
    echo ""
    echo "=============================================="
    echo " Installation complete!"
    echo "   Tools:  ${TOOLS_DIR}/"
    echo "   Skills: ${SKILLS_DIR}/"
    echo " Restart opencode to pick up the MCP server."
    echo "=============================================="
}

main "$@"
