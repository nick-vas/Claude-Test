# Loads every script, scene and resource in the project, and instantiates every scene, so that broken
# references and parse errors fail CI even in files no test touches. Run by the "validate" runner:
#   godot --headless --path <project> -s <this file>
# Each file is wrapped in marker lines; the runner attributes any ERROR printed in between to that file.
extends SceneTree

const EXTENSIONS := ["gd", "tscn", "scn", "tres", "res"]
const SKIP_DIRS := ["res://addons", "res://.godot"]


func _initialize() -> void:
	var files: Array[String] = []
	_collect("res://", files)
	files.sort()
	for path in files:
		print("@@validate begin %s" % path)
		var problem := _check(path)
		print("@@validate end %s %s" % [path, problem if problem else "ok"])
	print("@@validate done %d" % files.size())
	quit(0)


func _collect(dir: String, files: Array[String]) -> void:
	if dir in SKIP_DIRS or FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			_collect(dir.path_join(sub), files)
	for file in DirAccess.get_files_at(dir):
		if file.get_extension() in EXTENSIONS:
			files.append(dir.path_join(file))


func _check(path: String) -> String:
	var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null:
		return "failed to load"
	if resource is Script:
		var script := resource as Script
		var abstract: bool = script.has_method("is_abstract") and script.call("is_abstract")
		if not script.can_instantiate() and not abstract:
			return "script does not compile"
	elif resource is PackedScene:
		# Instantiate without adding to the tree: constructors run, _ready does not.
		var node := (resource as PackedScene).instantiate()
		if node == null:
			return "scene does not instantiate"
		node.free()
	return ""
