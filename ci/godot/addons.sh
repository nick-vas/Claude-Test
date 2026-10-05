#!/usr/bin/env bash
# Installs Godot addons from Git tags into <project>/addons. Idempotent.
#
#   addons.sh [--project DIR] SPEC...
#
# SPEC is a known name with a tag, or a full repo:
#   gut@v9.6.1                         -> github.com/bitwes/Gut, addons/gut
#   gdunit4@v6.2.1                     -> github.com/godot-gdunit-labs/gdUnit4, addons/gdUnit4
#   owner/repo@ref:addons/<name>       -> any repo that ships its addon under addons/<name>
set -euo pipefail
# shellcheck source=ci/godot/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

project="."; specs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    -*) die "addons.sh: unknown argument '$1'" ;;
    *) specs+=("$1"); shift ;;
  esac
done
[[ -f "$project/project.godot" ]] || die "No project.godot in '$project'"

for spec in "${specs[@]}"; do
  name="${spec%%@*}"; ref="${spec#*@}"
  [[ "$name" != "$spec" && -n "$ref" ]] || die "Addon '$spec' needs a version, e.g. gut@v9.6.1"
  case "$name" in
    gut) repo="bitwes/Gut"; addon="addons/gut" ;;
    gdunit4) repo="godot-gdunit-labs/gdUnit4"; addon="addons/gdUnit4" ;;
    */*)
      [[ "$ref" == *:* ]] || die "Custom addon '$spec' must look like owner/repo@ref:addons/<name>"
      repo="$name"; addon="${ref#*:}"; ref="${ref%%:*}" ;;
    *) die "Unknown addon '$name' (use owner/repo@ref:addons/<name>)" ;;
  esac

  dest="$project/$addon"
  stamp="$dest/.godot-ci-version"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$repo@$ref" ]]; then
    log "$addon already at $repo@$ref"
    continue
  fi

  log "Installing $repo@$ref -> $dest"
  tmp="$(mktemp -d)"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" --filter=blob:none --sparse \
    "https://github.com/$repo.git" "$tmp"
  git -C "$tmp" sparse-checkout set "$addon"
  [[ -d "$tmp/$addon" ]] || die "$repo@$ref has no $addon directory"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$tmp/$addon" "$dest"
  echo "$repo@$ref" > "$stamp"
  rm -rf "$tmp"
done
