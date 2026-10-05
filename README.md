# Godot Test Suite

Build, test, export and release **Godot 4** projects (GDScript or C#). It's one PowerShell script that you
run locally on Windows, and the same script packed into a GitHub workflow for a Linux runner. It detects
your project, Godot version and test frameworks for you.

```powershell
pwsh ci/godot/godot-ci.ps1 init       # once: wire the suite into your game
pwsh ci/godot/godot-ci.ps1            # every time: install Godot if needed, build, run every test
```

```yaml
# .github/workflows/godot-ci.yml (init writes this for you): the same tests on a GitHub Linux runner
on: [push, pull_request]
jobs:
  godot:
    permissions: { contents: read, pull-requests: write }
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
```

**Requirements:**
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
  (`winget install Microsoft.PowerShell`)
- the [.NET 8 SDK](https://dotnet.microsoft.com/download) for C# projects
- Git

The script downloads Godot itself. GitHub's Linux runners already have all of this. Run
`pwsh ci/godot/godot-ci.ps1 doctor` to check a machine and a project.

## What it detects

| From your project | It does |
|---|---|
| `project.godot` (shallowest in the repo) | uses that folder as the project |
| every script, scene and resource | **validate** runner: loads each one and instantiates each scene, so broken references and parse errors fail even in files no test touches |
| `Godot.NET.Sdk/4.6.1` in the `.csproj` | installs that exact Godot .NET version (else 4.6.1) |
| a `.sln` next to or above the project | builds it and runs `dotnet test` on it |
| test projects (`Microsoft.NET.Test.Sdk`, `gdUnit4.test.adapter`) | **dotnet** runner: xUnit, NUnit, MSTest and [gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net) scene tests |
| `Chickensoft.GoDotTest` in the `.csproj` | **godottest** runner, using the scene whose script calls `GoTest.RunTests` |
| `.gd` files that `extends GutTest` | **gut** runner; installs the [GUT](https://github.com/bitwes/Gut) release that matches your Godot |
| `run/main_scene` in `project.godot` | **smoke** runner: plays the main scene headless and fails on any error |
| presets in `export_presets.cfg` | what `export` builds |

All runners run one after another after a single build. A run that finds zero tests fails, and so does any
Godot `ERROR:`, even when Godot exits 0. Every run writes `test-results/summary.md`. On GitHub, it also gets a
results table on the run page, failures annotated on the failing line, and, on pull requests, one comment
with the results.

## Usage scenarios

### 1. Add the suite to an existing game

Put the suite in your game's repository, either as a submodule (easy to update) or by copying the
`ci/godot` folder, then let `init` wire it in:
```powershell
git submodule add https://github.com/nick-vas/Godot_TestSuite tools/godot-test-suite
pwsh tools/godot-test-suite/ci/godot/godot-ci.ps1 init
```
`init` only adds things and never overwrites a file, so it's safe to run again. It adds:
- a starter test: gdUnit4Net for C# projects (packages kept out of release builds), GUT for GDScript;
- `.gitignore` entries and test-folder exclusions in your export presets;
- `solution_directory` in `project.godot` when your `.sln` lives outside the project folder;
- `.github/workflows/godot-ci.yml`.

### 2. Run the tests locally, and check your setup

```powershell
pwsh ci/godot/godot-ci.ps1            # build + every detected test
pwsh ci/godot/godot-ci.ps1 doctor     # tools and project checks, each with a fix
pwsh ci/godot/godot-ci.ps1 detect     # show what it found, change nothing
Get-Help ci/godot/godot-ci.ps1 -Detailed
```
`doctor` catches the mistakes that break CI or ship broken builds. Examples: no `solution_directory`
(exports would silently drop your C# code), test packages or test folders going into release builds, GUT
files that won't run, and a missing .NET SDK. Godot is downloaded once to `~/.godot-ci`.

### 3. The same tests on a GitHub Linux runner, with a PR comment

```yaml
on: [push, pull_request]
jobs:
  godot:
    permissions:
      contents: read
      pull-requests: write     # lets it comment; without this it just warns
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
```
The workflow runs the same script, with the same detection, on `ubuntu-latest`, the cheapest runner. On
pull requests it keeps a single comment up to date with the results table, failures, and coverage compared
with the base branch. You don't need the submodule for CI; the workflow brings its own copy of the script,
pinned to the `@ref` you use.

### 4. A GDScript-only game with GUT

Write `test_*.gd` files that `extends GutTest`, and the suite installs the GUT version for your Godot
release; you don't commit `addons/gut`. See [`examples/gdscript`](examples/gdscript).

### 5. A C# game with unit tests, scene tests and in-engine tests

Keep engine-free logic in a class library tested with xUnit, add gdUnit4Net scene tests, and optionally
GoDotTest suites. All of them are detected and run. See [`examples/breakout`](examples/breakout) and the
[framework setup notes](docs/godot-pipelines.md#setting-each-one-up).

### 6. Fast pull-request checks, full runs on `main`

```yaml
on:
  pull_request:
  push:
    branches: [main]
jobs:
  godot:
    permissions: { contents: read, pull-requests: write }
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      # Unit tests only on PRs; every framework once merged.
      runners: ${{ github.event_name == 'pull_request' && 'dotnet' || '' }}
```

### 7. Windows builds, checked and released on every tag

```yaml
on:
  push:
    tags: ['v*']
jobs:
  release:
    permissions:
      contents: write          # to create the release
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      exports: Windows         # a preset name from export_presets.cfg, or "all"
      run-exports: true        # launch the .exe on a Windows runner and fail on errors
      release: true            # zip it and publish a GitHub Release with generated notes
```
Tests run first. Then each preset is exported, launched headless on a runner of its own OS, and zipped
as `<game>-<tag>-<preset>.zip` into a GitHub Release. Launching the export catches what the editor hides:
missing assets, code trimmed from the build, and release-only bugs. On a non-tag run, `release: true` builds
the zips but doesn't publish them (a dry run).

Locally: `pwsh ci/godot/godot-ci.ps1 export -Preset Windows -Run` exports to `build/` and launches the
`.exe`.

### 8. Coverage report and a minimum

```powershell
pwsh ci/godot/godot-ci.ps1 -Coverage            # report: test-results/coverage/index.html
pwsh ci/godot/godot-ci.ps1 -MinCoverage 60      # fail below 60% line coverage
```
In the workflow: `coverage: true` or `min-coverage: 60`. GoDotTest measures code that only runs inside the
engine. dotnet coverage needs `coverlet.collector` in the test project, and covers code tested outside
the engine: gdUnit4Net's `[RequireGodotRuntime]` tests run inside Godot, where the collector can't see them.

### 9. Run a subset of tests

```powershell
pwsh ci/godot/godot-ci.ps1 -Runners dotnet -Filter 'FullyQualifiedName~Combo'   # dotnet test filter
pwsh ci/godot/godot-ci.ps1 -Runners gut -Filter test_combo                       # GUT test name
pwsh ci/godot/godot-ci.ps1 -Runners godottest -Filter PlayerTest                 # GoDotTest suite
pwsh ci/godot/godot-ci.ps1 -Runners validate                                     # just the load check
pwsh ci/godot/godot-ci.ps1 -Runners none                                         # build only
```
The workflow takes the same values as `runners` and `filter` inputs, e.g. for a manual `workflow_dispatch`.

### 10. Several games in one repository

```powershell
pwsh ci/godot/godot-ci.ps1 -Project games/arena
```
```yaml
jobs:
  godot:
    strategy:
      matrix:
        project: [games/arena, games/puzzle]
    permissions: { contents: read, pull-requests: write }
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      project: ${{ matrix.project }}
```
Artifacts and PR comments are per game (named after `config/name`), so they don't collide.

## Reference

**Script** (`ci/godot/godot-ci.ps1`): commands `test` (default), `build`, `export`, `setup`, `detect`,
`doctor` and `init`.

| Parameter | Default | |
|---|---|---|
| `-Project` | detected | Folder with `project.godot` |
| `-Solution` | nearest `.sln` | What `dotnet build` / `dotnet test` run on |
| `-GodotVersion` | from csproj, else `4.6.1` | e.g. `4.6.1`, `4.7-rc1` |
| `-Runners` | detected | `validate`, `dotnet`, `gdunit4`, `godottest`, `gut`, `smoke`; `none` to only build |
| `-Filter` | | Passed to each runner's filter |
| `-Coverage` | off | One merged coverage report |
| `-MinCoverage` | `0` (off) | Fail below this line coverage percentage |
| `-Preset` | every preset | `export`: which presets |
| `-Run` | off | `export`: launch builds this machine can run |
| `-Results`, `-Output` | `test-results`, `build` | Where results and exports go |
| `-Frames` | `120` | How long smoke runs and launched exports play |

**Workflow inputs** (`godot.yml`), all optional:

| Input | Default | |
|---|---|---|
| `project`, `godot-version`, `runners`, `filter` | detected | As the script parameters |
| `coverage`, `min-coverage` | off | Coverage report; fail below a percentage |
| `pr-comment` | `true` | Results comment on pull requests (needs `pull-requests: write`) |
| `exports` | none | `all`, or a comma list of preset names |
| `run-exports` | `false` | Launch each export on a runner of its own OS |
| `release` | `false` | Publish exports as a GitHub Release on tags (needs `contents: write`) |
| `runs-on` | `ubuntu-latest` | `windows-latest` also works |
| `lfs`, `submodules`, `retention-days` | | Checkout options and artifact retention |

**Your own workflow:** the composite action runs one command with setup and caching, then uploads the
results or the build.
```yaml
      - uses: nick-vas/Godot_TestSuite/.github/actions/godot@main
        with:
          command: export        # test, build or export
          preset: Windows
      - run: echo "upload the Windows build to itch.io, Steam, ..."
```

**Cost:** jobs run in the repository that calls the workflow. They're free on public repositories; on private
ones they use your Actions minutes, and Linux runners are the cheapest (Windows minutes count about 2×).
One test job builds once for every framework. Exports and Windows runners only run when you ask for them.

**Claude Code cloud sessions** run Linux. Install PowerShell in the environment's setup script, then use
the script as usual:
```bash
mkdir -p /opt/pwsh && curl -fsSL https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz | tar xz -C /opt/pwsh && ln -sf /opt/pwsh/pwsh /usr/local/bin/pwsh
```

More on each framework, the five most popular Godot test projects, and how to set each one up:
[docs/godot-pipelines.md](docs/godot-pipelines.md).
