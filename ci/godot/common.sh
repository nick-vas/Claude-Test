#!/usr/bin/env bash
# Shared helpers for build.sh / test.sh / export.sh. Sourced, not executed.
set -euo pipefail

log() { echo "[godot-ci] $*"; }
die() { echo "[godot-ci] ERROR: $*" >&2; exit 1; }

# Group output on GitHub Actions, plain headers elsewhere.
group() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$*"; else echo "== $* =="; fi; }
endgroup() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::"; fi; }

# Resolve GODOT_BIN from the environment, from install.sh's env file, or from PATH.
resolve_godot() {
  if [[ -z "${GODOT_BIN:-}" ]]; then
    local env_file="${GODOT_TOOLS_DIR:-$HOME/.godot-ci}/env.sh"
    # shellcheck disable=SC1090
    [[ -f "$env_file" ]] && source "$env_file"
  fi
  if [[ -z "${GODOT_BIN:-}" ]] && command -v godot >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot)"
  fi
  [[ -n "${GODOT_BIN:-}" && -x "$GODOT_BIN" ]] || die "Godot not found. Run ci/godot/install.sh or set GODOT_BIN."
  export GODOT_BIN
}

# Pick the solution/project dotnet should build: explicit path, else the first .sln, else the first .csproj.
resolve_dotnet_target() {
  local project="$1" explicit="${2:-}"
  if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi
  local found
  found="$(find "$project" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' \) | sort | head -n1)"
  [[ -z "$found" ]] && found="$(find "$project" -maxdepth 1 -name '*.csproj' | sort | head -n1)"
  echo "$found"
}

# Godot occasionally exits 0 after printing errors, so scan its log too.
check_godot_log() {
  local logfile="$1" pattern='^ *(SCRIPT ERROR|ERROR|USER ERROR):|Unhandled [Ee]xception|Failed to load script'
  # Strip ANSI colour codes before matching (no sed -i: BSD and GNU disagree on it).
  local plain
  plain="$(mktemp)"
  sed $'s/\x1b\\[[0-9;]*m//g' "$logfile" > "$plain" && mv "$plain" "$logfile"
  if grep -Eq "$pattern" "$logfile"; then
    echo "[godot-ci] Godot reported errors:" >&2
    grep -E -A3 "$pattern" "$logfile" | head -n 60 >&2
    return 1
  fi
}
