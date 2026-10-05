namespace Breakout.Core;

public static class BallPhysics
{
    /// <summary>
    /// Bounce angle off the paddle: hitting the edge deflects up to <paramref name="maxAngleDegrees"/>
    /// from vertical. Returns a unit (x, y) direction with y pointing up (negative in Godot screen space).
    /// </summary>
    public static (float X, float Y) PaddleBounce(float hitX, float paddleCenterX, float paddleWidth, float maxAngleDegrees = 60f)
    {
        float offset = Math.Clamp((hitX - paddleCenterX) / (paddleWidth / 2f), -1f, 1f);
        float angle = offset * maxAngleDegrees * MathF.PI / 180f;
        return (MathF.Sin(angle), -MathF.Cos(angle));
    }
}
