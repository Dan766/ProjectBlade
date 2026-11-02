extends TestCase
## Every script in the project loads. Scenes such as the map aren't exercised by other tests,
## so a parse error there would otherwise only show up when the game is launched.


func test_every_script_loads() -> void:
	var broken := []
	for path in _scripts("res://scripts"):
		var s = load(path)
		if s == null or not (s as GDScript).can_instantiate():
			broken.append(path)
	check_eq(broken, [], "scripts that fail to load")


func test_main_scene_loads() -> void:
	var main_path: String = ProjectSettings.get_setting("application/run/main_scene")
	check(load(main_path) is PackedScene, "main scene " + main_path)


func _scripts(dir: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir + "/" + d))
	return out
