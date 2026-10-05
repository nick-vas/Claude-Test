extends GutTest

func test_every_fifth_hit_raises_the_multiplier():
	var score := Score.new()
	for i in 4:
		score.hit(10)
	assert_eq(score.hit(10), 20)

func test_miss_resets_combo():
	var score := Score.new()
	score.hit(10)
	score.miss()
	assert_eq(score.combo, 0)

func test_main_scene_scores_on_ready():
	var main = add_child_autofree(load("res://main.tscn").instantiate())
	assert_gt(main.score.points, 0)
