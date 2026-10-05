#!/usr/bin/env bash
# Runs one of the interchangeable test runners. All runners take the same flags and write to --results.
#
#   test.sh --runner dotnet|smoke [--project DIR] [--solution PATH] [--results DIR]
#           [--filter EXPR] [--scene res://path.tscn] [--frames N]
#
# Runners:
#   dotnet  `dotnet test` with TRX + JUnit output. Works for xUnit/NUnit/MSTest and for GdUnit4Net,
#           which launches Godot itself through the exported GODOT_BIN.
#   smoke   Boots the project (or --scene) headless for N frames and fails on any engine/script error.
set -euo pipefail
# shellcheck source=ci/godot/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

runner=""; project="."; solution=""; results="test-results"; filter=""; scene=""; frames=120
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner) runner="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --solution) solution="$2"; shift 2 ;;
    --results) results="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    --scene) scene="$2"; shift 2 ;;
    --frames) frames="$2"; shift 2 ;;
    *) die "test.sh: unknown argument '$1'" ;;
  esac
done

mkdir -p "$results"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && ! grep -q '^| Runner |' "$GITHUB_STEP_SUMMARY" 2>/dev/null; then
  printf '### Godot tests\n\n| Runner | Target | Result |\n|---|---|---|\n' >> "$GITHUB_STEP_SUMMARY"
fi
results="$(cd "$results" && pwd)"
resolve_godot

run_dotnet() {
  local target
  target="$(resolve_dotnet_target "$project" "$solution")"
  [[ -n "$target" ]] || die "dotnet runner: no .sln/.csproj found in '$project' (use --solution)"
  local args=("$target" --results-directory "$results" --logger "trx;LogFilePrefix=results"
              --logger "junit;LogFilePath=$results/{assembly}.junit.xml")
  [[ -n "$filter" ]] && args+=(--filter "$filter")
  group "dotnet test $target"
  # The JUnit logger is optional; fall back to TRX only if the package is not referenced.
  if ! dotnet test "${args[@]}" 2> >(tee "$results/dotnet-test.stderr" >&2); then
    if grep -q "Could not find a test logger with AssemblyQualifiedName, URI or FriendlyName 'junit'" "$results/dotnet-test.stderr"; then
      log "JUnit logger not referenced by the test project; re-running with TRX only"
      args=("$target" --results-directory "$results" --logger "trx;LogFilePrefix=results")
      [[ -n "$filter" ]] && args+=(--filter "$filter")
      dotnet test "${args[@]}" || { endgroup; summarize_trx; return 1; }
    else
      endgroup; summarize_trx; return 1
    fi
  fi
  endgroup
  summarize_trx
}

# Adds pass/fail counts from TRX files to the GitHub job summary.
summarize_trx() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  local trx counters
  for trx in "$results"/*.trx; do
    [[ -f "$trx" ]] || continue
    counters="$(grep -o '<Counters [^>]*' "$trx" | head -n1)"
    attr() { sed -n "s/.* $1=\"\([0-9]*\)\".*/\1/p" <<<"$counters"; }
    echo "| dotnet | $(basename "$trx") | $(attr passed)/$(attr total) passed, $(attr failed) failed |" >> "$GITHUB_STEP_SUMMARY"
  done
}

run_smoke() {
  [[ -f "$project/project.godot" ]] || die "smoke runner: no project.godot in '$project'"
  local logfile="$results/smoke.log" args=(--headless --path "$project" --quit-after "$frames")
  [[ -n "$scene" ]] && args+=("$scene")
  group "Godot smoke run ($frames frames${scene:+, $scene})"
  set +e
  "$GODOT_BIN" "${args[@]}" 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e
  endgroup
  [[ $status -eq 0 ]] || die "Godot exited with $status"
  check_godot_log "$logfile" || die "Smoke run produced errors"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| smoke | ${scene:-main scene} | $frames frames, no errors |" >> "$GITHUB_STEP_SUMMARY"
  log "Smoke run OK"
}

case "$runner" in
  dotnet) run_dotnet ;;
  smoke) run_smoke ;;
  *) die "test.sh: --runner must be 'dotnet' or 'smoke' (got '$runner')" ;;
esac
