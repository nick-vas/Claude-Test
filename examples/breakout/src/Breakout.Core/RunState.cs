namespace Breakout.Core;

/// <summary>Engine-free roguelike run state, so it can be unit tested without Godot.</summary>
public sealed class RunState
{
    private readonly List<Upgrade> _upgrades = new();

    public int Lives { get; private set; }
    public int Score { get; private set; }
    public int Combo { get; private set; }
    public int Floor { get; private set; } = 1;
    public IReadOnlyList<Upgrade> Upgrades => _upgrades;
    public bool IsOver => Lives <= 0;

    public RunState(int lives = 3) => Lives = lives;

    public float BallSpeedMultiplier => 1f + _upgrades.Count(u => u == Upgrade.FastBall) * 0.15f;
    public int PaddleWidthBonus => _upgrades.Count(u => u == Upgrade.WidePaddle) * 16;

    public int BreakBrick(int baseValue)
    {
        Combo++;
        int multiplier = 1 + Combo / 5 + _upgrades.Count(u => u == Upgrade.ScoreMultiplier);
        int gained = baseValue * multiplier;
        Score += gained;
        return gained;
    }

    public void PaddleHit() => Combo = 0;

    public void LoseBall()
    {
        if (IsOver) return;
        Combo = 0;
        Lives--;
    }

    public void ClearFloor(Upgrade reward)
    {
        Floor++;
        _upgrades.Add(reward);
        if (reward == Upgrade.ExtraLife) Lives++;
    }
}

public enum Upgrade
{
    WidePaddle,
    FastBall,
    ScoreMultiplier,
    ExtraLife,
}
