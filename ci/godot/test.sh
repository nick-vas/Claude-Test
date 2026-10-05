#!/usr/bin/env bash
# Runs one of the interchangeable test runners. Every runner takes the same flags, writes JUnit or TRX
# results to --results, and is summarised by report.py (job summary + failure annotations on GitHub).
#
#   test.sh --runner NAME [--project DIR] [--solution PATH] [--results DIR]
#           [--filter EXPR] [--scene res://path.tscn] [--frames N] [--coverage]
#
# Runners (pick per project; they can be swapped without changing anything else):
#   dotnet     `dotnet test` on the solution: xUnit, NUnit, MSTest, and any gdUnit4Net suites in it.
#   gdunit4    gdUnit4Net (C#) on the Godot project's csproj; [RequireGodotRuntime] tests run in headless Godot.
#   godottest  Chickensoft GoDotTest: the game runs its own C# suites (--scene picks the runner scene).
#   gut        GUT (GDScript) via addons/gut/gut_cmdln.gd; honours res://.gutconfig.json, else runs the
#              test_*.gd files in every folder that has a script extending GutTest.
#   smoke      Boots the main scene (or --scene) for N frames and fails on any engine/script error.
#
# --filter means: dotnet/gdunit4 `dotnet test --filter`; godottest suite name; gut -gunit_test_name.
# --coverage collects Cobertura coverage into --results/coverage: dotnet and gdunit4 need the
# coverlet.collector package in the test project; godottest uses the coverlet console tool.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/godot/common.sh
source "$here/common.sh"

runner=""; project="."; solution=""; results="test-results"; filter=""; scene=""; frames=120; coverage=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner) runner="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --solution) solution="$2"; shift 2 ;;
    --results) results="$2"; shift 2 ;;
    --filter) filter="$2"; shift 2 ;;
    --scene) scene="$2"; shift 2 ;;
    --frames) frames="$2"; shift 2 ;;
    --coverage) coverage=true; shift ;;
    *) die "test.sh: unknown argument '$1'" ;;
  esac
done

# gut and smoke have no coverage tooling; ignore --coverage for them rather than warn.
[[ "$runner" == gut || "$runner" == smoke ]] && coverage=false

mkdir -p "$results"
results="$(cd "$results" && pwd)"
# report.py reads every result file here, so drop leftovers from earlier runs (e.g. repeated local runs).
find "$results" \( -name '*.trx' -o -name '*.junit.xml' -o -name '*.log' -o -name '*.runsettings' \) -delete
rm -rf "$results/coverage"
project="$(cd "$project" && pwd)"
resolve_godot
tools_dir="${GODOT_TOOLS_DIR:-$HOME/.godot-ci}/tools"

# Installs a .NET global tool into the shared tools dir once.
dotnet_tool() {
  local package="$1" command="$2"
  if [[ ! -x "$tools_dir/$command" ]]; then
    dotnet tool install "$package" --tool-path "$tools_dir" >/dev/null
  fi
  echo "$tools_dir/$command"
}

# Runs Godot with a log file, returning its exit code without tripping set -e.
run_godot() {
  local logfile="$1"; shift
  set +e
  "$GODOT_BIN" "$@" 2>&1 | tee "$logfile"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# Single-case JUnit file for runners without native reports.
write_junit() {
  local name="$1" status="$2" message="$3" file="$results/$1.junit.xml"
  python3 - "$name" "$status" "$message" "$file" <<'PY'
import sys
from xml.sax.saxutils import escape, quoteattr
name, status, message, path = sys.argv[1:]
failure = f'<failure message={quoteattr(message[:200])}>{escape(message)}</failure>' if status != "0" else ""
with open(path, "w") as f:
    f.write(f'<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name={quoteattr(name)} tests="1" '
            f'failures="{1 if failure else 0}"><testcase classname={quoteattr(name)} name={quoteattr(name)}>'
            f'{failure}</testcase></testsuite></testsuites>\n')
PY
}

# Shared by dotnet and gdunit4: gdUnit4Net reads GODOT_BIN and Godot arguments from here, and other
# frameworks ignore the GdUnit4 section, so any solution can mix plain and engine tests.
# No TreatNoTestsAsError: with --filter, projects without a match would fail the run. report.py
# fails the run instead when nothing at all was reported.
write_runsettings() {
  cat > "$results/godot.runsettings" <<XML
<?xml version="1.0" encoding="utf-8"?>
<RunSettings>
  <RunConfiguration>
    <MaxCpuCount>1</MaxCpuCount>
    <TestSessionTimeout>1800000</TestSessionTimeout>
    <EnvironmentVariables>
      <GODOT_BIN>$GODOT_BIN</GODOT_BIN>
    </EnvironmentVariables>
  </RunConfiguration>
  <GdUnit4>
    <Parameters>--headless</Parameters>
    <DisplayName>FullyQualifiedName</DisplayName>
    <CaptureStdOut>true</CaptureStdOut>
  </GdUnit4>
</RunSettings>
XML
  echo "$results/godot.runsettings"
}

dotnet_test() {
  local target="$1"
  local args=("$target" --settings "$(write_runsettings)" --results-directory "$results"
              --logger "trx;LogFilePrefix=$runner")
  [[ -n "$filter" ]] && args+=(--filter "$filter")
  $coverage && args+=(--collect "XPlat Code Coverage")
  group "dotnet test $target"
  local status=0
  dotnet test "${args[@]}" || status=$?
  endgroup
  return "$status"
}

run_dotnet() {
  local target
  target="$(resolve_dotnet_target "$project" "$solution")"
  [[ -n "$target" ]] || die "dotnet runner: no .sln/.csproj found in '$project' (use --solution)"
  dotnet_test "$target"
}

run_gdunit4() {
  # gdUnit4Net suites live in the Godot project's csproj, so target that unless a .csproj is given.
  local target="$solution"
  [[ "$target" == *.csproj ]] || target="$(find "$project" -maxdepth 1 -name '*.csproj' | sort | head -n1)"
  [[ -n "$target" ]] || die "gdunit4 runner: no .csproj in '$project' (use --solution)"
  grep -q 'gdUnit4.test.adapter' "$target" ||
    die "gdunit4 runner: $target does not reference gdUnit4.test.adapter (see docs/godot-pipelines.md)"
  dotnet_test "$target"
}

run_godottest() {
  local logfile="$results/godottest.log" args=(--headless --path "$project")
  [[ -n "$scene" ]] && args+=("$scene")
  args+=("--run-tests${filter:+=$filter}" --quit-on-finish)
  group "GoDotTest${scene:+ ($scene)}"
  local status=0
  if $coverage; then
    local coverlet bin_dir
    coverlet="$(dotnet_tool coverlet.console coverlet)"
    # The editor runs the Debug build; an ExportRelease folder left by an export must not be picked.
    bin_dir="$project/.godot/mono/temp/bin/Debug"
    [[ -d "$bin_dir" ]] || die "godottest runner: no Debug build in $bin_dir; build the project first"
    mkdir -p "$results/coverage"
    set +e
    "$coverlet" "$bin_dir" --target "$GODOT_BIN" --targetargs "${args[*]} --coverage" \
      --format cobertura --output "$results/coverage/godottest.cobertura.xml" \
      --exclude-by-file "**/test/**/*.cs" --exclude-assemblies-without-sources MissingAll 2>&1 | tee "$logfile"
    status=${PIPESTATUS[0]}
    set -e
  else
    run_godot "$logfile" "${args[@]}" || status=$?
  fi
  endgroup
  python3 "$here/report.py" godottest-junit "$logfile" "$results/godottest.junit.xml"
  return "$status"
}

run_gut() {
  [[ -f "$project/addons/gut/gut_cmdln.gd" ]] || die "gut runner: addons/gut missing. Set the workflow input 'addons: gut@v9.6.1' or run ci/godot/addons.sh --project '$project' gut@v9.6.1"
  local logfile="$results/gut.log"
  local args=(--headless --path "$project" -s addons/gut/gut_cmdln.gd -gexit -gdisable_colors
              "-gjunit_xml_file=$results/gut.junit.xml")
  # Without a .gutconfig.json, search every folder that holds a script extending GutTest.
  if [[ ! -f "$project/.gutconfig.json" ]]; then
    local dir
    while IFS= read -r dir; do
      args+=("-gdir=res://${dir#"$project"}")
    done < <(grep -rlE --include='*.gd' '^extends +GutTest' "$project" | grep -v "^$project/addons/" |
             xargs -I{} dirname {} | sort -u)
  fi
  [[ -n "$filter" ]] && args+=("-gunit_test_name=$filter")
  group "GUT"
  local status=0
  run_godot "$logfile" "${args[@]}" || status=$?
  endgroup
  return "$status"
}

run_smoke() {
  local logfile="$results/smoke.log" args=(--headless --path "$project" --quit-after "$frames")
  [[ -n "$scene" ]] && args+=("$scene")
  group "Godot smoke run ($frames frames${scene:+, $scene})"
  local status=0 message=""
  run_godot "$logfile" "${args[@]}" || status=$?
  endgroup
  if [[ $status -ne 0 ]]; then
    message="Godot exited with $status"
  elif ! check_godot_log "$logfile" 2> "$results/smoke.errors"; then
    status=1; message="$(cat "$results/smoke.errors")"
  fi
  write_junit smoke "$status" "${message:-${scene:-main scene} ran $frames frames without errors}"
  return "$status"
}

status=0
case "$runner" in
  dotnet) run_dotnet || status=$? ;;
  gdunit4) run_gdunit4 || status=$? ;;
  godottest) run_godottest || status=$? ;;
  gut) run_gut || status=$? ;;
  smoke) run_smoke || status=$? ;;
  *) die "test.sh: --runner must be dotnet, gdunit4, godottest, gut or smoke (got '$runner')" ;;
esac

# dotnet's collector drops coverage in per-run GUID folders; gather it in one place.
if $coverage; then
  mkdir -p "$results/coverage"
  # Skip the copies dotnet also attaches under <trx>/In/<machine>/.
  find "$results" -name 'coverage.cobertura.xml' -not -path "$results/coverage/*" -not -path '*/In/*' | while read -r file; do
    mv "$file" "$results/coverage/$runner-$(basename "$(dirname "$file")").cobertura.xml"
  done
  if compgen -G "$results/coverage/*.cobertura.xml" >/dev/null; then
    reportgenerator="$(dotnet_tool dotnet-reportgenerator-globaltool reportgenerator)"
    "$reportgenerator" "-reports:$results/coverage/*.cobertura.xml" "-targetdir:$results/coverage/report" \
      "-reporttypes:Html;MarkdownSummaryGithub;Cobertura" "-title:$runner coverage" >/dev/null
  else
    log "No coverage data was produced by the $runner runner"
  fi
fi

# report.py also fails the run when no tests were reported, so a misconfigured runner can't pass silently.
python3 "$here/report.py" summary "$results" --runner "$runner" --exit-code "$status" || status=1
[[ $status -eq 0 ]] || die "$runner tests failed"
log "$runner tests passed"
