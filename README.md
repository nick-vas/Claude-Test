# Godot Test Suite

Build, test and export **Godot 4** projects (GDScript or C#). It's one PowerShell script that you run
locally on Windows, and the same script packed into a GitHub workflow for a Linux runner. It detects your
project, Godot version and test frameworks for you.

```powershell
pwsh ci/godot/godot-ci.ps1            # locally: install Godot if needed, build, run every test
```

```yaml
# .github/workflows/ci.yml: the same tests on a GitHub Linux runner
on: [push, pull_request]
jobs:
  godot:
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
```

**Requirements:**
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
  (`winget install Microsoft.PowerShell`)
- the [.NET 8 SDK](https://dotnet.microsoft.com/download) for C# projects
- Git

The script downloads Godot itself. GitHub's Linux runners already have all of this.

## What it detects

| From your project | It does |
|---|---|
| `project.godot` (shallowest in the repo) | uses that folder as the project |
| `Godot.NET.Sdk/4.6.1` in the `.csproj` | installs that exact Godot .NET version (else 4.6.1) |
| a `.sln` next to or above the project | builds it and runs `dotnet test` on it |
| test projects (`Microsoft.NET.Test.Sdk`, `gdUnit4.test.adapter`) | **dotnet** runner: xUnit, NUnit, MSTest and [gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net) scene tests |
| `Chickensoft.GoDotTest` in the `.csproj` | **godottest** runner, using the scene whose script calls `GoTest.RunTests` |
| `.gd` files that `extends GutTest` | **gut** runner; installs the [GUT](https://github.com/bitwes/Gut) release that matches your Godot |
| `run/main_scene` in `project.godot` | **smoke** runner: plays the main scene headless and fails on any error |
| presets in `export_presets.cfg` | what `export` builds |

All runners run one after another after a single build. A run that finds zero tests fails, and so does any
Godot `ERROR:`, even when Godot exits 0. On GitHub, every run gets a results table on its run page, and
failures are annotated on the failing line.

## Usage scenarios

### 1. Run the tests locally in PowerShell

Put the suite in your game's repository, either as a submodule (easy to update) or by copying the
`ci/godot` folder:
```powershell
git submodule add https://github.com/nick-vas/Godot_TestSuite tools/godot-test-suite
```
Then, from your repository root:
```powershell
pwsh tools/godot-test-suite/ci/godot/godot-ci.ps1           # build + every detected test
pwsh tools/godot-test-suite/ci/godot/godot-ci.ps1 detect    # show what it found, change nothing
Get-Help tools/godot-test-suite/ci/godot/godot-ci.ps1 -Detailed
```
Godot is downloaded once to `~/.godot-ci`. Results land in `test-results/`.

### 2. The same tests on a GitHub Linux runner

```yaml
on: [push, pull_request]
jobs:
  godot:
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
```
This runs the same script, with the same detection, on `ubuntu-latest`, the cheapest runner. You don't need
the submodule for CI; the workflow brings its own copy of the script, pinned to the `@ref` you use.

### 3. A GDScript-only game with GUT

Nothing extra to configure. Write `test_*.gd` files that `extends GutTest`, and the suite installs the GUT
version for your Godot release; you don't commit `addons/gut`. See [`examples/gdscript`](examples/gdscript).

### 4. A C# game with unit tests, scene tests and in-engine tests

Keep engine-free logic in a class library tested with xUnit, add gdUnit4Net scene tests, and optionally
GoDotTest suites. All of them are detected and run. See [`examples/breakout`](examples/breakout) and the
[framework setup notes](docs/godot-pipelines.md#setting-each-one-up).

### 5. Fast pull-request checks, full runs on `main`

```yaml
on:
  pull_request:
  push:
    branches: [main]
jobs:
  godot:
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      # Unit tests only on PRs; every framework once merged.
      runners: ${{ github.event_name == 'pull_request' && 'dotnet' || '' }}
```

### 6. Windows builds on every tag

```yaml
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      exports: Windows        # a preset name from export_presets.cfg, or "all"
      retention-days: 30
```
Tests run first, then the Linux runner exports the Windows `.exe` and uploads it as `<game name>-Windows`.
Locally: `pwsh ci/godot/godot-ci.ps1 export -Preset Windows` (output in `build/`). Test code stays out of
release builds if you follow [the export notes](docs/godot-pipelines.md#keep-tests-out-of-release-builds).

### 7. Coverage report

```powershell
pwsh ci/godot/godot-ci.ps1 -Coverage      # report: test-results/coverage/index.html
```
In the workflow, set `coverage: true` to get the summary on the run page as well. GoDotTest measures code
that only runs inside the engine. dotnet coverage needs `coverlet.collector` in your test project.

### 8. Run a subset of tests

```powershell
pwsh ci/godot/godot-ci.ps1 -Runners dotnet -Filter 'FullyQualifiedName~Combo'   # dotnet test filter
pwsh ci/godot/godot-ci.ps1 -Runners gut -Filter test_combo                       # GUT test name
pwsh ci/godot/godot-ci.ps1 -Runners godottest -Filter PlayerTest                 # GoDotTest suite
pwsh ci/godot/godot-ci.ps1 -Runners none                                         # build only
```
The workflow takes the same values as `runners` and `filter` inputs, e.g. for a manual `workflow_dispatch`.

### 9. Several games in one repository

```powershell
pwsh ci/godot/godot-ci.ps1 -Project games/arena
```
```yaml
jobs:
  godot:
    strategy:
      matrix:
        project: [games/arena, games/puzzle]
    uses: nick-vas/Godot_TestSuite/.github/workflows/godot.yml@main
    with:
      project: ${{ matrix.project }}
```
Artifacts are named after each game's `config/name`, so they don't collide.

### 10. Your own workflow, using the action

```yaml
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: nick-vas/Godot_TestSuite/.github/actions/godot@main
        with:
          command: export        # test, build or export
          preset: Windows
      - run: echo "upload the Windows build to itch.io, Steam, ..."
```
The action handles setup and caching, then uploads results or builds as artifacts.

## Reference

**Script** (`ci/godot/godot-ci.ps1`): commands `test` (default), `build`, `export`, `setup` and `detect`.

| Parameter | Default | |
|---|---|---|
| `-Project` | detected | Folder with `project.godot` |
| `-Solution` | nearest `.sln` | What `dotnet build` / `dotnet test` run on |
| `-GodotVersion` | from csproj, else `4.6.1` | e.g. `4.6.1`, `4.7-rc1` |
| `-Runners` | detected | `dotnet`, `gdunit4`, `godottest`, `gut`, `smoke`; `none` to only build |
| `-Filter` | | Passed to each runner's filter |
| `-Coverage` | off | One merged coverage report |
| `-Preset` | every preset | `export`: which presets |
| `-Results`, `-Output` | `test-results`, `build` | Where results and exports go |
| `-Frames` | `120` | How long the smoke run plays |

**Workflow inputs** (`godot.yml`), all optional: `project`, `godot-version`, `runners`, `filter`,
`coverage`, `exports` (`all` or preset names), `runs-on` (default `ubuntu-latest`; `windows-latest` also
works), `lfs`, `submodules`, `retention-days`.

**Cost:** jobs run in the repository that calls the workflow. They're free on public repositories; on private
ones they use your Actions minutes, and Linux runners are the cheapest (Windows minutes count about 2×).
One test job builds once for every framework, and exports only run when you ask for them.

**Claude Code cloud sessions** run Linux. Install PowerShell in the environment's setup script, then use
the script as usual:
```bash
mkdir -p /opt/pwsh && curl -fsSL https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz | tar xz -C /opt/pwsh && ln -sf /opt/pwsh/pwsh /usr/local/bin/pwsh
```

More on each framework, the five most popular Godot test projects, and how to set each one up:
[docs/godot-pipelines.md](docs/godot-pipelines.md).
