# Godot CI

Build, test and export **Godot 4** projects (GDScript or C#) with one command locally, or with a
three-line GitHub workflow. It detects your project, Godot version and test frameworks for you.

```yaml
# .github/workflows/ci.yml
on: [push, pull_request]
jobs:
  godot:
    uses: nick-vas/Claude-Test/.github/workflows/godot.yml@main
```

```bash
ci/godot/godot-ci            # the same thing on your machine: install, build, run every test
```

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
| presets in `export_presets.cfg` | what `exports: all` and `godot-ci export` build |

All runners run in one job after one build. Every run gets a results table on the run page, and failures
are annotated on the failing line. A run that finds zero tests fails, and so does any Godot `ERROR:`,
even when Godot exits 0.

## Usage scenarios

### 1. Add CI to a C# game with no configuration

```yaml
on: [push, pull_request]
jobs:
  godot:
    uses: nick-vas/Claude-Test/.github/workflows/godot.yml@main
```
The Godot version comes from your csproj, the test frameworks from your packages and scripts. Nothing to
keep in sync when you upgrade Godot: bump `Godot.NET.Sdk` and CI follows.

### 2. A GDScript-only game with GUT

The same three lines. Write tests as `test/test_*.gd` files that `extends GutTest`. The pipeline installs the
GUT version for your Godot release; you don't commit `addons/gut`. See
[`examples/gdscript`](examples/gdscript).

### 3. Run everything locally, or in a Claude Code cloud session

```bash
ci/godot/godot-ci                   # install Godot if needed, build, run all detected tests
ci/godot/godot-ci detect            # show what it found, change nothing
ci/godot/godot-ci --runners gut     # just one framework
```
To use it from another repo without copying the scripts, add this repository as a git submodule, or copy
the `ci/godot` folder. In a Claude Code cloud environment, add this to the setup script so Godot is ready
when a session starts:
```bash
curl -fsSL https://raw.githubusercontent.com/nick-vas/Claude-Test/main/ci/godot/install.sh | bash
```
On Windows, use WSL, or run your framework directly (`dotnet test`, or the GUT panel in the editor).

### 4. Fast pull-request checks, full runs on `main`

```yaml
on:
  pull_request:
  push:
    branches: [main]
jobs:
  godot:
    uses: nick-vas/Claude-Test/.github/workflows/godot.yml@main
    with:
      # Unit tests only on PRs; every framework once merged.
      runners: ${{ github.event_name == 'pull_request' && 'dotnet' || '' }}
```

### 5. Release builds when you push a tag

```yaml
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: nick-vas/Claude-Test/.github/workflows/godot.yml@main
    with:
      exports: all            # or "Linux,Windows"
      retention-days: 30
```
Tests run first; each preset then exports in its own job and uploads as `<game name>-<preset>`.
Windows and macOS builds export fine from the Linux runner. Test code stays out of release builds if you
follow [the export notes](docs/godot-pipelines.md#keep-tests-out-of-release-builds).

### 6. Coverage report

```yaml
    with:
      coverage: true
```
or `ci/godot/godot-ci --coverage` locally. One merged HTML report lands in
`test-results/coverage/index.html`, and a summary on the run page. GoDotTest measures code that only runs
inside the engine. dotnet coverage needs `coverlet.collector` in your test project.

### 7. Run a subset of tests

```bash
ci/godot/godot-ci --runners dotnet --filter "FullyQualifiedName~Combo"   # dotnet test filter
ci/godot/godot-ci --runners gut --filter test_combo                       # GUT test name
ci/godot/godot-ci --runners godottest --filter PlayerTest                 # GoDotTest suite
```
The same `runners` and `filter` inputs work in the workflow, e.g. for a manual `workflow_dispatch` run.

### 8. Several games in one repository

```yaml
jobs:
  godot:
    strategy:
      matrix:
        project: [games/arena, games/puzzle]
    uses: nick-vas/Claude-Test/.github/workflows/godot.yml@main
    with:
      project: ${{ matrix.project }}
```
Artifacts are named after each game's `config/name`, so they don't collide.

### 9. Try a different Godot version, or test on macOS

```yaml
    with:
      godot-version: 4.7-rc1     # any tag from godotengine/godot-builds
      runs-on: macos-latest
```
For C# projects, prefer bumping `Godot.NET.Sdk` in the csproj so the editor, CI and NuGet agree.

### 10. Your own workflow, using the action

```yaml
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: nick-vas/Claude-Test/.github/actions/godot@main
        with:
          command: export        # test, build or export
          preset: Linux
      - run: echo "upload the Linux build to itch.io, Steam, ..."
```
The action handles setup and caching, then uploads results or builds as artifacts.

## Reference

**Workflow inputs** (`godot.yml`): all optional.

| Input | Default | |
|---|---|---|
| `project` | detected | Folder with `project.godot` |
| `godot-version` | from csproj, else `4.6.1` | e.g. `4.6.1`, `4.7-rc1` |
| `runners` | detected | `dotnet`, `gdunit4`, `godottest`, `gut`, `smoke`, comma-separated; `none` to only build |
| `filter` | | Passed to each runner's filter |
| `coverage` | `false` | Merged coverage report and summary |
| `exports` | none | `all`, or a comma list of preset names |
| `runs-on` | `ubuntu-latest` | Linux or macOS runner |
| `lfs`, `submodules` | `false` | Passed to `actions/checkout` |
| `retention-days` | `14` | For results and builds |

**CLI** (`ci/godot/godot-ci`): commands `test` (default), `build`, `export`, `setup` and `detect`.
Options mirror the inputs: `--project`, `--godot-version`, `--runners`, `--filter`, `--coverage`,
`--preset NAME`, `--results DIR`, `--output DIR`. Run `ci/godot/godot-ci --help` for the full list.

**Cost:** jobs run in the repository that calls the workflow. They're free on public repositories; on private
ones they use your Actions minutes, and macOS minutes count about 10×. One test job builds once for every
framework, and exports only run when you ask for them.

More detail on each framework, the five most popular Godot test projects, and how to set each one up:
[docs/godot-pipelines.md](docs/godot-pipelines.md).
