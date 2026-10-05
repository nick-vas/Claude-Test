namespace Breakout.Tests;

using System.Threading.Tasks;
using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
[RequireGodotRuntime]
public class MainSceneTest
{
    [TestCase]
    public async Task Ball_breaks_bricks_and_scores()
    {
        using ISceneRunner runner = ISceneRunner.Load("res://Main.tscn");
        var main = (Main)runner.Scene();
        int bricksAtStart = main.BricksRemaining;

        await runner.SimulateFrames(240);

        AssertThat(main.BricksRemaining).IsLess(bricksAtStart);
        AssertThat(main.Score).IsGreater(0);
    }

    [TestCase]
    public void First_floor_has_three_rows_of_ten()
    {
        using ISceneRunner runner = ISceneRunner.Load("res://Main.tscn");
        AssertThat(((Main)runner.Scene()).BricksRemaining).IsEqual(30);
    }
}
