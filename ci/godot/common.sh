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

# Engine-internal messages that say nothing about the project. Each entry is a regex; extend the list
# per project with GODOT_CI_IGNORE_ERRORS (a regex, e.g. 'some message|another message').
GODOT_CI_KNOWN_NOISE=(
  # macOS: the Android export plugin reads editor settings during headless shutdown (timing-dependent).
  'EditorSettings not instantiated yet when getting setting'
)

# Godot occasionally exits 0 after printing errors, so scan its log too.
check_godot_log() {
  local logfile="$1" pattern='^ *(SCRIPT ERROR|ERROR|USER ERROR):|Unhandled [Ee]xception|Failed to load script'
  local ignore
  ignore="$(IFS='|'; echo "${GODOT_CI_KNOWN_NOISE[*]}")${GODOT_CI_IGNORE_ERRORS:+|$GODOT_CI_IGNORE_ERRORS}"
  # Strip ANSI colour codes before matching (no sed -i: BSD and GNU disagree on it).
  local plain
  plain="$(mktemp)"
  sed $'s/\x1b\\[[0-9;]*m//g' "$logfile" > "$plain" && mv "$plain" "$logfile"
  # grep exits 2 on a bad regex, which would otherwise read as "no errors".
  local rc=0
  grep -E "$ignore" /dev/null || rc=$?
  [[ $rc -le 1 ]] || die "GODOT_CI_IGNORE_ERRORS is not a valid extended regex: $GODOT_CI_IGNORE_ERRORS"
  # Read every line rather than stopping at the first match: an early exit (-q) SIGPIPEs the upstream
  # grep, and under pipefail that turns a log full of errors into a pass.
  local errors noise
  errors="$(grep -E "$pattern" "$logfile" | grep -Ev "$ignore" || true)"
  if [[ -n "$errors" ]]; then
    echo "[godot-ci] Godot reported errors:" >&2
    grep -E -A3 "$pattern" "$logfile" | grep -Ev "$ignore" | head -n 60 >&2 || true
    return 1
  fi
  noise="$(grep -E "$pattern" "$logfile" | grep -E "$ignore" || true)"
  [[ -z "$noise" ]] || log "Ignored known engine noise: ${noise%%$'\n'*}"
}
