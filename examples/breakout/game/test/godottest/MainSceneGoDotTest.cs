namespace Breakout.Tests;

using System.Threading.Tasks;
using Chickensoft.GoDotTest;
using Godot;
using Shouldly;

public class MainSceneGoDotTest : TestClass
{
    private Main _main = default!;

    public MainSceneGoDotTest(Node testScene) : base(testScene) { }

    [Setup]
    public void Setup()
    {
        _main = GD.Load<PackedScene>("res://Main.tscn").Instantiate<Main>();
        TestScene.AddChild(_main);
    }

    [Cleanup]
    public void Cleanup() => _main.QueueFree();

    [Test]
    public void Starts_on_floor_one_with_three_lives()
    {
        _main.Floor.ShouldBe(1);
        _main.Run.Lives.ShouldBe(3);
    }

    [Test]
    public async Task Ball_scores_within_a_few_seconds()
    {
        for (int i = 0; i < 240; i++)
            await TestScene.ToSignal(TestScene.GetTree(), SceneTree.SignalName.PhysicsFrame);

        _main.Score.ShouldBeGreaterThan(0);
    }
}
