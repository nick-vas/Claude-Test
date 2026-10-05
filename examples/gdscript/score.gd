class_name Score
extends RefCounted
## Combo scoring, kept engine-light so it is easy to unit test with GUT.

var points := 0
var combo := 0

func hit(value: int) -> int:
	combo += 1
	var gained := value * (1 + combo / 5)
	points += gained
	return gained

func miss() -> void:
	combo = 0
