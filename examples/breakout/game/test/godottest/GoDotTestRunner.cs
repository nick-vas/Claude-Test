namespace Breakout.Tests;

using System.Reflection;
using Chickensoft.GoDotTest;
using Godot;

/// <summary>Entry scene for GoDotTest: `godot res://test/godottest/GoDotTestRunner.tscn --run-tests --quit-on-finish`.</summary>
public partial class GoDotTestRunner : Node2D
{
    public override void _Ready()
    {
        var environment = TestEnvironment.From(OS.GetCmdlineArgs());
        _ = GoTest.RunTests(Assembly.GetExecutingAssembly(), this, environment);
    }
}
