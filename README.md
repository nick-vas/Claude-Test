# Claude-Test

Interchangeable **build, test and export pipelines for Godot 4 .NET (C#) projects**: reusable GitHub
workflows, composite actions and portable shell scripts that all share the same inputs.

Five swappable test runners cover the main Godot test frameworks: plain `dotnet test`,
[gdUnit4Net](https://github.com/godot-gdunit-labs/gdUnit4Net), [GoDotTest](https://github.com/chickensoft-games/GoDotTest),
[GUT](https://github.com/bitwes/Gut) and a headless smoke run. Each one adds a results summary, failure
annotations and optional coverage.

- Docs: [docs/godot-pipelines.md](docs/godot-pipelines.md)
- Drop-in workflow: [templates/godot-ci.yml](templates/godot-ci.yml)
- Example project: [examples/breakout](examples/breakout) (self-playing breakout with roguelike floors and upgrades)

```yaml
jobs:
  godot:
    uses: nick-vas/Claude-Test/.github/workflows/godot-ci.yml@main
    with:
      export-presets: '["Linux", "Windows"]'
```
