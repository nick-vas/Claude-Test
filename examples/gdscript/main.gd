extends Node2D

var score := Score.new()

func _ready() -> void:
	for i in 12:
		score.hit(10)
	print("Score after 12 hits: ", score.points)
