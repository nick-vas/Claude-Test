# Claude-Test

Interchangeable **build, test and export pipelines for Godot 4 .NET (C#) projects**: reusable GitHub
workflows, composite actions and portable shell scripts that all share the same inputs.

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
