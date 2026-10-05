#!/usr/bin/env bash
# Installs the .NET SDK (if missing) and the Godot .NET editor, optionally with export templates.
# Self-contained so it can also be piped from curl in a Claude cloud environment setup script.
#
# Env / flags:
#   GODOT_VERSION   (default 4.6.1)     --version
#   GODOT_RELEASE   (default stable)    --release
#   DOTNET_CHANNEL  (default 8.0)       --dotnet
#   GODOT_TOOLS_DIR (default ~/.godot-ci) --tools-dir
#   --templates     also install export templates
#
# Writes $GODOT_TOOLS_DIR/env.sh (source it) and, on GitHub Actions, GITHUB_ENV/GITHUB_PATH.
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.6.1}"
GODOT_RELEASE="${GODOT_RELEASE:-stable}"
DOTNET_CHANNEL="${DOTNET_CHANNEL:-8.0}"
GODOT_TOOLS_DIR="${GODOT_TOOLS_DIR:-$HOME/.godot-ci}"
WITH_TEMPLATES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) GODOT_VERSION="$2"; shift 2 ;;
    --release) GODOT_RELEASE="$2"; shift 2 ;;
    --dotnet) DOTNET_CHANNEL="$2"; shift 2 ;;
    --tools-dir) GODOT_TOOLS_DIR="$2"; shift 2 ;;
    --templates) WITH_TEMPLATES=true; shift ;;
    *) echo "install.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

log() { echo "[godot-ci] $*"; }

tag="${GODOT_VERSION}-${GODOT_RELEASE}"
base_url="https://github.com/godotengine/godot-builds/releases/download/${tag}"
mkdir -p "$GODOT_TOOLS_DIR"

download() {
  local url="$1" dest="$2"
  log "Downloading $url"
  curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

# --- .NET SDK -------------------------------------------------------------
dotnet_bin=""
if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q "^${DOTNET_CHANNEL%%.*}\."; then
  dotnet_bin="$(command -v dotnet)"
  log ".NET SDK ${DOTNET_CHANNEL} already available at $dotnet_bin"
else
  dotnet_root="$GODOT_TOOLS_DIR/dotnet"
  if [[ -x "$dotnet_root/dotnet" ]] && "$dotnet_root/dotnet" --list-sdks | grep -q "^${DOTNET_CHANNEL%%.*}\."; then
    :
  elif download "https://dot.net/v1/dotnet-install.sh" "$GODOT_TOOLS_DIR/dotnet-install.sh" 2>/dev/null; then
    bash "$GODOT_TOOLS_DIR/dotnet-install.sh" --channel "$DOTNET_CHANNEL" --install-dir "$dotnet_root" --no-path
  elif command -v apt-get >/dev/null 2>&1; then
    # Restricted networks (e.g. sandboxed cloud sessions) may block Microsoft's CDN but allow the distro mirror.
    log "dot.net unreachable; installing dotnet-sdk-${DOTNET_CHANNEL} with apt"
    sudo_cmd=""; [[ $(id -u) -ne 0 ]] && sudo_cmd="sudo"
    $sudo_cmd apt-get update -qq
    $sudo_cmd apt-get install -y -qq "dotnet-sdk-${DOTNET_CHANNEL}"
    dotnet_root="$(dirname "$(readlink -f "$(command -v dotnet)")")"
  else
    echo "Could not install the .NET SDK ${DOTNET_CHANNEL}" >&2; exit 1
  fi
  dotnet_bin="$dotnet_root/dotnet"
  export DOTNET_ROOT="$dotnet_root"
  export PATH="$dotnet_root:$PATH"
fi

# --- Godot editor ---------------------------------------------------------
case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64) arch=x86_64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac
    pkg="Godot_v${tag}_mono_linux_${arch}"
    godot_bin="$GODOT_TOOLS_DIR/$tag/$pkg/Godot_v${tag}_mono_linux.${arch}"
    templates_root="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
    ;;
  Darwin)
    pkg="Godot_v${tag}_mono_macos.universal"
    godot_bin="$GODOT_TOOLS_DIR/$tag/Godot_mono.app/Contents/MacOS/Godot"
    templates_root="$HOME/Library/Application Support/Godot/export_templates"
    ;;
  *) echo "Unsupported OS $(uname -s); use a Linux or macOS runner" >&2; exit 1 ;;
esac

if [[ -x "$godot_bin" ]]; then
  log "Godot $tag already installed"
else
  mkdir -p "$GODOT_TOOLS_DIR/$tag"
  download "$base_url/$pkg.zip" "$GODOT_TOOLS_DIR/$pkg.zip"
  unzip -q -o "$GODOT_TOOLS_DIR/$pkg.zip" -d "$GODOT_TOOLS_DIR/$tag"
  rm -f "$GODOT_TOOLS_DIR/$pkg.zip"
  chmod +x "$godot_bin"
fi

# --- Export templates -----------------------------------------------------
templates_dir="$templates_root/${GODOT_VERSION}.${GODOT_RELEASE}.mono"
if $WITH_TEMPLATES; then
  if [[ -f "$templates_dir/version.txt" ]]; then
    log "Export templates already installed in $templates_dir"
  else
    tpz="$GODOT_TOOLS_DIR/Godot_v${tag}_mono_export_templates.tpz"
    download "$base_url/Godot_v${tag}_mono_export_templates.tpz" "$tpz"
    tmp="$(mktemp -d)"
    unzip -q -o "$tpz" -d "$tmp"
    mkdir -p "$templates_dir"
    cp -R "$tmp/templates/." "$templates_dir/"
    rm -rf "$tmp" "$tpz"
  fi
fi

# --- Publish environment --------------------------------------------------
cat > "$GODOT_TOOLS_DIR/env.sh" <<ENV
export GODOT_BIN="$godot_bin"
export GODOT_VERSION="$GODOT_VERSION"
export GODOT_RELEASE="$GODOT_RELEASE"
export GODOT_TEMPLATES_DIR="$templates_dir"
${DOTNET_ROOT:+export DOTNET_ROOT="$DOTNET_ROOT"}
export PATH="$(dirname "$dotnet_bin"):\$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
ENV

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "GODOT_BIN=$godot_bin"
    echo "GODOT_VERSION=$GODOT_VERSION"
    echo "GODOT_RELEASE=$GODOT_RELEASE"
    echo "GODOT_TEMPLATES_DIR=$templates_dir"
    [[ -n "${DOTNET_ROOT:-}" ]] && echo "DOTNET_ROOT=$DOTNET_ROOT"
    echo "DOTNET_CLI_TELEMETRY_OPTOUT=1"
    echo "DOTNET_NOLOGO=1"
  } >> "$GITHUB_ENV"
  dirname "$dotnet_bin" >> "$GITHUB_PATH"
fi

"$godot_bin" --version
"$dotnet_bin" --version
log "Ready. Run: source \"$GODOT_TOOLS_DIR/env.sh\""
