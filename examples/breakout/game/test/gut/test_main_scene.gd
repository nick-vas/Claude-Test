extends GutTest
## GUT tests drive the C# scene from GDScript (test runner "gut").

var main: Node

func before_each():
	main = add_child_autofree(load("res://Main.tscn").instantiate())

func test_first_floor_has_thirty_bricks():
	assert_eq(main.BricksRemaining, 30)

func test_ball_scores_after_some_frames():
	await wait_physics_frames(240)
	assert_gt(main.Score, 0, "the self-playing paddle should have broken a brick")
