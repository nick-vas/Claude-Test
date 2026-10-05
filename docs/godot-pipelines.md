# Godot .NET build & test pipelines

A set of build, test and export pipelines for **Godot 4 C# projects** that share one contract, so you
can use them interchangeably:

- in **GitHub Actions**, as reusable workflows or as individual composite actions;
- in a **Claude Code cloud environment**, on your machine, or on any other CI, as plain shell scripts.

Every layer calls the same scripts in [`ci/godot/`](../ci/godot), so a green run in one place means the same
commands pass everywhere.

```
ci/godot/install.sh   .NET SDK + Godot .NET editor (+ export templates)    <- setup-godot action
ci/godot/addons.sh    GUT / gdUnit4 / any addon from a Git tag             <- godot-build action (addons input)
ci/godot/build.sh     dotnet build + headless Godot import                 <- godot-build action
ci/godot/test.sh      --runner dotnet | gdunit4 | godottest | gut | smoke  <- godot-test action
ci/godot/report.py    JUnit/TRX -> job summary + failure annotations       <- called by test.sh
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
| `addons` | | all | Space-separated, e.g. `gut@v9.6.1`; installed before the build |
| `pipelines-repo` / `pipelines-ref` | `nick-vas/Claude-Test` / `main` | all | Where the scripts come from. Keep `pipelines-ref` equal to the `@ref` in `uses:` |
| `test-runners` | `["dotnet", "smoke"]` | ci, test | JSON array of `dotnet`, `gdunit4`, `godottest`, `gut`, `smoke`; `[]` skips tests |
| `test-filter` | | ci, test | Passed to each runner's own filter (see below) |
| `coverage` | `false` | ci, test | Cobertura + HTML report in the results artifact, summary on the run page |
| `smoke-scene` / `smoke-frames` | main scene / `120` | ci, test | |
| `godottest-scene` | main scene | ci, test | Scene that starts GoDotTest |
| `export-presets` | `[]` | ci, export | JSON array of preset names |
| `export-mode` | `release` | ci, export | `release`, `debug` or `pack` |
| `artifact-prefix` | repo name | ci, export | Artifacts are `<prefix>-<preset>` |
| `retention-days` | `14` | ci, export | |

### Test runners

Every runner takes the same flags, writes JUnit or TRX into the results folder, and is summarised the
same way: a table on the run page, failure details, `::error` annotations on the failing line, and the
`test-results-<runner>` artifact. A run that reports **zero tests fails**, so a misconfigured runner can't
pass by accident.

| Runner | Framework | Language | Runs inside Godot | `test-filter` means | Coverage |
|---|---|---|---|---|---|
| `dotnet` | xUnit / NUnit / MSTest (+ any gdUnit4Net suites in the solution) | C# | only gdUnit4Net suites | `dotnet test --filter` | ✅ needs `coverlet.collector` |
| `gdunit4` | [gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net) | C# | ✅ `[RequireGodotRuntime]` tests | `dotnet test --filter` | ✅ needs `coverlet.collector` |
| `godottest` | [Chickensoft GoDotTest](https://github.com/chickensoft-games/GoDotTest) | C# | ✅ the game runs its own suites | suite name | ✅ coverlet console, real in-engine coverage |
| `gut` | [GUT](https://github.com/bitwes/Gut) | GDScript | ✅ | `-gunit_test_name` | – |
| `smoke` | none | – | ✅ boots a scene for N frames | – | – |

## Choosing a framework

These five frameworks were picked after surveying the Godot testing ecosystem (October 2026):

| # | Project | Stars | Language | Notes |
|---|---|---|---|---|
| 1 | [bitwes/Gut](https://github.com/bitwes/Gut) | ~2.7k | GDScript | Most popular. 9.6.x for Godot 4.6, 9.7.x for 4.7. Doubles, spies, parameterized tests, JUnit export |
| 2 | [godot-gdunit-labs/gdUnit4](https://github.com/godot-gdunit-labs/gdUnit4) | ~1.2k | GDScript + C# | Editor test inspector, fluent asserts, mocking, scene runner, HTML/JUnit reports |
| 3 | [godot-gdunit-labs/gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net) | ~190 | C# | gdUnit4's C# side as a VSTest adapter: `dotnet test`, Rider/VS/VS Code, scene runner, input simulation |
| 4 | [chickensoft-games/GoDotTest](https://github.com/chickensoft-games/GoDotTest) | ~150 | C# | Tests run inside the real game; command-line runs and coverlet coverage of engine code |
| 5 | [chickensoft-games/GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver) | ~60 | C# | Not a runner: drivers, fixtures and input simulation for integration tests; pairs with GoDotTest |

WAT (~310 stars) is popular but only supports Godot 3.

For a **C# project**:
- Keep engine-free logic in a plain class library and test it with the `dotnet` runner (fastest).
- Use **gdUnit4Net** (`gdunit4`) for scene and node tests. It is the best-integrated C# option: plain
  `dotnet test`, IDE test explorers, and the scene runner.
- Use **GoDotTest** (`godottest`) when you want tests to run inside the shipped game, or want coverage of
  code that only runs in the engine.

For **GDScript**, use **GUT** (`gut`). The `smoke` runner suits every project as a final check.

### Setting each one up

[`examples/breakout`](../examples/breakout) uses all of them at once. Versions that work with Godot 4.6.1
and .NET 8:

**gdUnit4Net**: add to the Godot project's csproj, write `[TestSuite]` classes and mark engine tests with
`[RequireGodotRuntime]`. The runner writes the `.runsettings` (`GODOT_BIN`, `--headless`) for you.
```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" />  <!-- 3.1.x needs a pre-release api -->
<PackageReference Include="coverlet.collector" Version="10.1.0" />    <!-- for coverage -->
```
gdUnit4Net writes a `gdunit4_testadapter_v5/` folder into the project, so add it to `.gitignore`.

**GoDotTest**: reference `Chickensoft.GoDotTest` (2.0.31 is the last version built against Godot 4.6.1;
newer ones need Godot 4.7). Add a small runner scene that calls `GoTest.RunTests(...)`, as in
[`GoDotTestRunner.cs`](../examples/breakout/game/test/godottest/GoDotTestRunner.cs), and set
`godottest-scene` to it.

**GUT**: set `addons: gut@v9.6.1` (use 9.7.x for Godot 4.7). Tests are `test_*.gd` scripts extending
`GutTest`. With no `.gutconfig.json`, the runner searches `res://test` recursively.

**Keep tests out of release exports**: put test code and test packages behind a condition, and exclude
test folders in the export presets. The example does both:
```xml
<IncludeTests Condition="'$(Configuration)' != 'ExportRelease'">true</IncludeTests>
<!-- test PackageReferences in an ItemGroup with Condition="'$(IncludeTests)' == 'true'" -->
<ItemGroup Condition="'$(IncludeTests)' != 'true'">
  <Compile Remove="test/**;gdunit4_testadapter*/**" />
</ItemGroup>
```
```ini
exclude_filter="test/*, addons/gut/*, gdunit4_testadapter*/*"
```

## Composite actions

Use these to build your own workflow while keeping the same behaviour:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: nick-vas/Claude-Test/.github/actions/setup-godot@main
    with: { godot-version: "4.6.1", templates: "true" }
  - uses: nick-vas/Claude-Test/.github/actions/godot-build@main
    with: { addons: gut@v9.6.1 }
  - uses: nick-vas/Claude-Test/.github/actions/godot-test@main
    with: { runner: gdunit4, coverage: "true" }
  - uses: nick-vas/Claude-Test/.github/actions/godot-export@main
    with: { preset: Linux, artifact-name: game-linux }
```

`setup-godot` caches the editor, export templates, NuGet packages and the coverage tools.

## Scripts (local, Claude Code cloud environments, other CI)

```bash
ci/godot/install.sh --templates            # once; writes ~/.godot-ci/env.sh
ci/godot/addons.sh --project game gut@v9.6.1
ci/godot/build.sh  --project game --solution MyGame.sln
ci/godot/test.sh   --runner dotnet    --project game --solution MyGame.sln --coverage
ci/godot/test.sh   --runner gdunit4   --project game
ci/godot/test.sh   --runner godottest --project game --scene res://test/GoDotTestRunner.tscn
ci/godot/test.sh   --runner gut       --project game
ci/godot/test.sh   --runner smoke     --project game --frames 300
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
    test/gdunit4/            gdUnit4Net scene tests
    test/godottest/          GoDotTest runner scene + suites
    test/gut/                GUT GDScript tests (.gutconfig.json in game/)
  src/Breakout.Core/         engine-free roguelike run logic
  tests/Breakout.Core.Tests/ xUnit tests
```
