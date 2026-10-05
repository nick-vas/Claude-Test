#!/usr/bin/env bash
# Restores and compiles the C# solution, then imports the Godot project headlessly.
#
#   build.sh [--project DIR] [--solution PATH] [--configuration Debug|Release] [--allow-errors]
set -euo pipefail
# shellcheck source=ci/godot/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

project="."; solution=""; configuration="Debug"; strict=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --solution) solution="$2"; shift 2 ;;
    --configuration) configuration="$2"; shift 2 ;;
    --allow-errors) strict=false; shift ;;
    *) die "build.sh: unknown argument '$1'" ;;
  esac
done

[[ -f "$project/project.godot" ]] || die "No project.godot in '$project'"
resolve_godot
target="$(resolve_dotnet_target "$project" "$solution")"

if [[ -n "$target" ]]; then
  group "dotnet build $target ($configuration)"
  dotnet build "$target" -c "$configuration"
  endgroup
else
  log "No .sln/.csproj found; skipping dotnet build (GDScript-only project)"
fi

group "Godot import"
logfile="$(mktemp)"
set +e
"$GODOT_BIN" --headless --path "$project" --import 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e
endgroup
[[ $status -eq 0 ]] || die "Godot import exited with $status"
if $strict; then check_godot_log "$logfile" || die "Import produced errors (pass --allow-errors to ignore)"; fi
log "Build OK"
