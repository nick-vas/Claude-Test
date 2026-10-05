using Breakout.Core;
using Xunit;

namespace Breakout.Core.Tests;

public class RunStateTests
{
    [Fact]
    public void Combo_raises_multiplier_every_five_bricks()
    {
        var run = new RunState();
        for (int i = 0; i < 4; i++) run.BreakBrick(10);
        Assert.Equal(20, run.BreakBrick(10));
    }

    [Fact]
    public void Paddle_hit_resets_combo()
    {
        var run = new RunState();
        run.BreakBrick(10);
        run.PaddleHit();
        Assert.Equal(0, run.Combo);
    }

    [Fact]
    public void Run_ends_when_lives_run_out()
    {
        var run = new RunState(lives: 2);
        run.LoseBall();
        run.LoseBall();
        run.LoseBall();
        Assert.True(run.IsOver);
        Assert.Equal(0, run.Lives);
    }

    [Theory]
    [InlineData(Upgrade.ExtraLife, 4)]
    [InlineData(Upgrade.WidePaddle, 3)]
    public void Clearing_a_floor_applies_its_reward(Upgrade reward, int expectedLives)
    {
        var run = new RunState();
        run.ClearFloor(reward);
        Assert.Equal(2, run.Floor);
        Assert.Equal(expectedLives, run.Lives);
        Assert.Contains(reward, run.Upgrades);
    }

    [Fact]
    public void Paddle_edge_hit_deflects_sideways_and_up()
    {
        var (x, y) = BallPhysics.PaddleBounce(hitX: 150, paddleCenterX: 100, paddleWidth: 100);
        Assert.True(x > 0.8f);
        Assert.True(y < 0);
        Assert.Equal(1f, x * x + y * y, precision: 4);
    }
}
