# Godot CI reference

The [README](../README.md) covers usage. This page covers the test frameworks, how to set each one up, and
how the pieces fit together.

## Test frameworks

Five frameworks were picked after surveying the Godot testing ecosystem (October 2026):

| # | Project | Stars | Language | Notes |
|---|---|---|---|---|
| 1 | [bitwes/Gut](https://github.com/bitwes/Gut) | ~2.7k | GDScript | Most popular. Doubles, spies, parameterized tests, JUnit export |
| 2 | [godot-gdunit-labs/gdUnit4](https://github.com/godot-gdunit-labs/gdUnit4) | ~1.2k | GDScript + C# | Editor test inspector, fluent asserts, mocking, scene runner |
| 3 | [godot-gdunit-labs/gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net) | ~190 | C# | gdUnit4's C# side as a VSTest adapter: `dotnet test`, IDE test explorers, scene runner |
| 4 | [chickensoft-games/GoDotTest](https://github.com/chickensoft-games/GoDotTest) | ~150 | C# | Tests run inside the real game; coverage of code that only runs in the engine |
| 5 | [chickensoft-games/GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver) | ~60 | C# | Not a runner: drivers, fixtures and input simulation; pairs with GoDotTest |

WAT (~310 stars) only supports Godot 3.

**Which to use**
- **C#**: keep engine-free logic in a plain class library with xUnit/NUnit tests (fastest). Use
  **gdUnit4Net** for scene and node tests. Add **GoDotTest** if you want tests inside the running game, or
  coverage of engine-only code.
- **GDScript**: use **GUT**.
- **Every project**: the **smoke** runner plays the main scene for 120 frames and fails on any error, with no
  tests to write.

### Runners

| Runner | Detected when | Runs | `--filter` means | Coverage |
|---|---|---|---|---|
| `dotnet` | a project in the solution references `Microsoft.NET.Test.Sdk` or `gdUnit4.test.adapter` | `dotnet test` on the solution, including gdUnit4Net suites | `dotnet test --filter` | ✅ needs `coverlet.collector` |
| `gdunit4` | never: select it explicitly | `dotnet test` on the Godot project's csproj only | `dotnet test --filter` | ✅ needs `coverlet.collector` |
| `godottest` | the Godot csproj references `Chickensoft.GoDotTest` | the scene whose script calls `GoTest.RunTests`, else the main scene | suite name | ✅ via coverlet |
| `gut` | a `.gd` file `extends GutTest` | `.gutconfig.json` if present, else `test_*.gd` in those folders | test name | – |
| `smoke` | `project.godot` has a main scene | the main scene for N frames | – | – |

The `dotnet` runner already covers gdUnit4Net suites, so `gdunit4` is only useful to run engine tests on
their own.

### Setting each one up

[`examples/breakout`](../examples/breakout) uses all of them at once, and
[`examples/gdscript`](../examples/gdscript) is the minimal GDScript setup. Versions that work with Godot
4.6.1 and .NET 8:

**gdUnit4Net**: add to the Godot project's csproj, write `[TestSuite]` classes and mark engine tests with
`[RequireGodotRuntime]`. The pipeline writes the `.runsettings` (`GODOT_BIN`, `--headless`) for you.
```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" />  <!-- 3.1.x needs a pre-release api -->
<PackageReference Include="coverlet.collector" Version="10.1.0" />    <!-- for coverage -->
```
gdUnit4Net writes a `gdunit4_testadapter_v5/` folder into the project; add it to `.gitignore`.

**GoDotTest**: reference `Chickensoft.GoDotTest`. 2.0.31 is the last version built against Godot 4.6.1;
newer ones need Godot 4.7. Add a small scene whose script calls `GoTest.RunTests(...)`, like
[`GoDotTestRunner.cs`](../examples/breakout/game/test/godottest/GoDotTestRunner.cs); the pipeline finds it.

**GUT**: just write `test_*.gd` scripts that extend `GutTest`. The pipeline installs GUT v9.4.0–v9.7.1 to
match Godot 4.4–4.7; for other versions, commit `addons/gut` yourself.

### Keep tests out of release builds

Put test code and test packages behind a condition, and exclude test folders in the export presets. The
breakout example does both:
```xml
<IncludeTests Condition="'$(Configuration)' != 'ExportRelease'">true</IncludeTests>
<!-- test PackageReferences go in an ItemGroup with Condition="'$(IncludeTests)' == 'true'" -->
<ItemGroup Condition="'$(IncludeTests)' != 'true'">
  <Compile Remove="test/**;gdunit4_testadapter*/**" />
</ItemGroup>
```
```ini
exclude_filter="test/*, addons/gut/*, gdunit4_testadapter*/*"
```

## Project notes

- If your `.sln` isn't next to `project.godot`, set `dotnet/project/solution_directory` in `project.godot`,
  or exports fail with *"no solution file was found"*. The pipeline catches this; Godot alone exits 0 and
  exports without your C# code.
- Builds, exports and smoke runs fail on any `ERROR:` or `SCRIPT ERROR:` Godot prints. A short list of
  engine-internal messages is ignored (`GODOT_CI_KNOWN_NOISE` in [`common.sh`](../ci/godot/common.sh)). To
  ignore more, set `GODOT_CI_IGNORE_ERRORS` to a regex.
- `install.sh` falls back to the distro's `dotnet-sdk-8.0` package when Microsoft's download servers are
  blocked, as they are in sandboxed cloud sessions.

## How it fits together

```
.github/workflows/godot.yml     reusable workflow: test job, then one export job per preset
.github/actions/godot           composite action: detect, cache, run godot-ci, upload artifacts
ci/godot/godot-ci               the CLI everything goes through: detection + setup → build → test/export
ci/godot/install.sh             .NET SDK + Godot .NET editor (+ export templates)
ci/godot/addons.sh              installs GUT / gdUnit4 / any addon from a Git tag
ci/godot/build.sh               dotnet build + headless import
ci/godot/test.sh                one runner: dotnet | gdunit4 | godottest | gut | smoke
ci/godot/report.py              JUnit/TRX → summary, failure annotations, zero-tests check
ci/godot/export.sh              one export preset
```

The workflow checks out its own repository at the exact commit you called it with
(`job.workflow_repository` / `job.workflow_sha`), so pinning `@v1` or a SHA pins the scripts too.
