using Breakout.Core;
using Godot;
using System.Collections.Generic;

/// <summary>
/// Minimal self-playing breakout. The paddle tracks the ball so a headless smoke run
/// exercises collisions, scoring and floor progression without input.
/// </summary>
public partial class Main : Node2D
{
    private const float BaseBallSpeed = 320f;
    private const float PaddleBaseWidth = 96f;
    private static readonly Vector2 Arena = new(640, 480);
    private static readonly Vector2 BrickSize = new(56, 18);

    private readonly RunState _run = new();
    private readonly List<Rect2> _bricks = new();
    private Vector2 _ball;
    private Vector2 _ballDir;
    private float _paddleX;

    // Read by the scene tests in test/.
    public RunState Run => _run;
    public int BricksRemaining => _bricks.Count;
    public int Score => _run.Score;
    public int Floor => _run.Floor;

    private float PaddleWidth => PaddleBaseWidth + _run.PaddleWidthBonus;
    private Rect2 PaddleRect => new(_paddleX - PaddleWidth / 2, Arena.Y - 32, PaddleWidth, 12);

    public override void _Ready()
    {
        BuildFloor();
        ResetBall();
    }

    public override void _PhysicsProcess(double delta)
    {
        if (_run.IsOver) return;

        _paddleX = Mathf.MoveToward(_paddleX, _ball.X, 600f * (float)delta);
        _ball += _ballDir * BaseBallSpeed * _run.BallSpeedMultiplier * (float)delta;

        if (_ball.X < 0 || _ball.X > Arena.X) _ballDir.X = -_ballDir.X;
        if (_ball.Y < 0) _ballDir.Y = Mathf.Abs(_ballDir.Y);

        if (_ballDir.Y > 0 && PaddleRect.HasPoint(_ball))
        {
            var (x, y) = BallPhysics.PaddleBounce(_ball.X, _paddleX, PaddleWidth);
            _ballDir = new Vector2(x, y);
            _run.PaddleHit();
        }

        for (int i = _bricks.Count - 1; i >= 0; i--)
        {
            if (!_bricks[i].HasPoint(_ball)) continue;
            _bricks.RemoveAt(i);
            _ballDir.Y = -_ballDir.Y;
            _run.BreakBrick(10 * _run.Floor);
            break;
        }

        if (_bricks.Count == 0)
        {
            _run.ClearFloor((Upgrade)(_run.Floor % 4));
            GD.Print($"Floor {_run.Floor} reached, score {_run.Score}");
            BuildFloor();
        }

        if (_ball.Y > Arena.Y)
        {
            _run.LoseBall();
            ResetBall();
        }

        QueueRedraw();
    }

    public override void _Draw()
    {
        foreach (var brick in _bricks) DrawRect(brick, Colors.Coral);
        DrawRect(PaddleRect, Colors.White);
        DrawCircle(_ball, 6, Colors.Gold);
    }

    private void BuildFloor()
    {
        _bricks.Clear();
        int rows = 2 + _run.Floor;
        for (int row = 0; row < rows; row++)
        for (int col = 0; col < 10; col++)
            _bricks.Add(new Rect2(new Vector2(12 + col * (BrickSize.X + 6), 40 + row * (BrickSize.Y + 6)), BrickSize));
    }

    private void ResetBall()
    {
        _paddleX = Arena.X / 2;
        _ball = new Vector2(Arena.X / 2, Arena.Y - 60);
        _ballDir = new Vector2(0.4f, -1f).Normalized();
    }
}
