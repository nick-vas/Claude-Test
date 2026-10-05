# Godot .NET build & test pipelines

A set of build, test and export pipelines for **Godot 4 C# projects** that share one contract, so you
can use them interchangeably:

- in **GitHub Actions**, as reusable workflows or as individual composite actions;
- in a **Claude Code cloud environment**, on your machine, or on any other CI, as plain shell scripts.

Every layer calls the same scripts in [`ci/godot/`](../ci/godot), so a green run in one place means the same
commands pass everywhere.

```
ci/godot/install.sh   .NET SDK + Godot .NET editor (+ export templates)    <- setup-godot action
ci/godot/build.sh     dotnet build + headless Godot import                 <- godot-build action
ci/godot/test.sh      --runner dotnet | smoke                              <- godot-test action
ci/godot/export.sh    one export preset                                    <- godot-export action
```

## Reusable workflows

| Workflow | Jobs |
|---|---|
| `godot-ci.yml` | build → test (one job per runner) → export (one job per preset) |
| `godot-build.yml` | build only |
| `godot-test.yml` | build + test, one job per runner |
| `godot-export.yml` | build + export, one job per preset |

All four accept the same full set of inputs and ignore the ones they don't use, so switching from one to
another is a one-word change in `uses:`.

```yaml
jobs:
  godot:
    uses: nick-vas/Claude-Test/.github/workflows/godot-ci.yml@main
    with:
      project-path: game
      solution: MyGame.sln
      export-presets: '["Linux", "Windows"]'
```

A full example is in [`templates/godot-ci.yml`](../templates/godot-ci.yml).

### Inputs

| Input | Default | Used by | Notes |
|---|---|---|---|
| `project-path` | `.` | all | Folder containing `project.godot` |
| `solution` | first `.sln`/`.csproj` in `project-path` | all | What `dotnet build`/`dotnet test` run on |
| `godot-version` | `4.6.1` | all | |
| `godot-release` | `stable` | all | `rc1`, `beta2`, … for pre-releases |
| `dotnet-version` | `8.0` | all | Godot 4.6 C# targets .NET 8 |
| `runs-on` | `ubuntu-latest` | all | Linux or macOS runners (Windows builds are exported from Linux) |
| `lfs` / `submodules` | `false` | all | Passed to `actions/checkout` |
| `pipelines-repo` / `pipelines-ref` | `nick-vas/Claude-Test` / `main` | all | Where the scripts come from. Keep `pipelines-ref` equal to the `@ref` in `uses:` |
| `test-runners` | `["dotnet", "smoke"]` | ci, test | JSON array; `[]` skips tests |
| `test-filter` | | ci, test | `dotnet test --filter` |
| `smoke-scene` / `smoke-frames` | main scene / `120` | ci, test | |
| `export-presets` | `[]` | ci, export | JSON array of preset names |
| `export-mode` | `release` | ci, export | `release`, `debug` or `pack` |
| `artifact-prefix` | repo name | ci, export | Artifacts are `<prefix>-<preset>` |
| `retention-days` | `14` | ci, export | |

### Test runners

Both runners take the same flags and are drop-in replacements for each other:

- **`dotnet`**: `dotnet test` on the solution, with TRX output (plus JUnit XML if the test project references
  `JunitXml.TestLogger`). This covers xUnit, NUnit and MSTest tests of engine-free code. `GODOT_BIN` is
  exported, so [GdUnit4Net](https://github.com/MikeSchulze/gdUnit4Net) tests that need the engine also run through it.
- **`smoke`**: boots the game (or `smoke-scene`) headless for N frames and fails on any `ERROR:`,
  `SCRIPT ERROR:` or unhandled C# exception, even when Godot itself exits 0.

Results are uploaded as `test-results-<runner>` artifacts and summarised on the run page.

## Composite actions

Use these to build your own workflow while keeping the same behaviour:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: nick-vas/Claude-Test/.github/actions/setup-godot@main
    with: { godot-version: "4.6.1", templates: "true" }
  - uses: nick-vas/Claude-Test/.github/actions/godot-build@main
  - uses: nick-vas/Claude-Test/.github/actions/godot-test@main
    with: { runner: dotnet }
  - uses: nick-vas/Claude-Test/.github/actions/godot-export@main
    with: { preset: Linux, artifact-name: game-linux }
```

`setup-godot` caches the editor, export templates and NuGet packages.

## Scripts (local, Claude Code cloud environments, other CI)

```bash
ci/godot/install.sh --templates            # once; writes ~/.godot-ci/env.sh
ci/godot/build.sh  --project game --solution MyGame.sln
ci/godot/test.sh   --runner dotnet --project game --solution MyGame.sln
ci/godot/test.sh   --runner smoke  --project game --frames 300
ci/godot/export.sh --project game --preset Linux --output-dir build/linux
```

`install.sh` falls back to the distro's `dotnet-sdk-8.0` package when Microsoft's download servers are blocked,
as they are in sandboxed cloud sessions.

### Claude Code cloud environment

Add this to the environment's **setup script** so every session starts with Godot and .NET ready:

```bash
curl -fsSL https://raw.githubusercontent.com/nick-vas/Claude-Test/main/ci/godot/install.sh | bash
```

Add `-s -- --templates` after `bash` if sessions should also export builds (about 1 GB extra).

## Project requirements

- If your `.sln` isn't next to `project.godot`, set `dotnet/project/solution_directory` in
  `project.godot`, or exports fail with *"no solution file was found"*. `export.sh` catches this; Godot alone
  exits 0 without exporting the C# code.
- Keep engine-free game logic in a plain `net8.0` class library so it can be unit tested without Godot.
  [`examples/breakout`](../examples/breakout) shows the layout:

```
examples/breakout/
  Breakout.sln
  game/                      Godot project (project.godot, Breakout.csproj, scenes)
  src/Breakout.Core/         engine-free roguelike run logic
  tests/Breakout.Core.Tests/ xUnit tests
```
