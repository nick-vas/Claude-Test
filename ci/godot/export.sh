#!/usr/bin/env bash
# Exports one preset from export_presets.cfg. Needs export templates (install.sh --templates).
#
#   export.sh --preset NAME (--output FILE | --output-dir DIR) [--project DIR] [--mode release|debug|pack]
#
# --output-dir names the file after the preset's export_path in export_presets.cfg.
set -euo pipefail
# shellcheck source=ci/godot/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

project="."; preset=""; output=""; output_dir=""; mode="release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --preset) preset="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --output-dir) output_dir="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    *) die "export.sh: unknown argument '$1'" ;;
  esac
done

[[ -n "$preset" ]] || die "export.sh: --preset is required"
[[ -n "$output" || -n "$output_dir" ]] || die "export.sh: --output or --output-dir is required"
presets="$project/export_presets.cfg"
[[ -f "$presets" ]] || die "No export_presets.cfg in '$project'"
# tr: Windows checkouts often have CRLF line endings.
tr -d '\r' < "$presets" | grep -q "^name=\"$preset\"$" || die "Preset '$preset' not found in export_presets.cfg"

if [[ -z "$output" ]]; then
  # export_path of the matching [preset.N] section, e.g. "../build/windows/Game.exe" -> Game.exe
  export_path="$(awk -v name="name=\"$preset\"" '
    { sub(/\r$/, "") }
    /^\[preset\.[0-9]+\]$/ { in_preset = 0 }
    $0 == name { in_preset = 1 }
    in_preset && /^export_path=/ { sub(/^export_path="/, ""); sub(/"$/, ""); print; exit }
  ' "$presets")"
  [[ -n "$export_path" ]] || die "Preset '$preset' has no export_path; pass --output instead"
  output="$output_dir/$(basename "$export_path")"
fi
case "$mode" in release|debug|pack) ;; *) die "--mode must be release, debug or pack" ;; esac
resolve_godot

# Godot resolves relative output paths against the project directory, so make it absolute.
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

group "Export '$preset' ($mode) -> $output"
logfile="$(mktemp)"
set +e
"$GODOT_BIN" --headless --path "$project" "--export-$mode" "$preset" "$output" 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e
endgroup
[[ $status -eq 0 ]] || die "Export exited with $status"
[[ -e "$output" ]] || die "Export finished but '$output' was not created"
check_godot_log "$logfile" || die "Export produced errors"
log "Exported $(du -sh "$output" | cut -f1) to $output"
