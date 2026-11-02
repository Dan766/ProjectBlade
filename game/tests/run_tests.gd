extends SceneTree
## Minimal headless test runner (no addon to download):
##   <godot console exe> --headless --path game -s res://tests/run_tests.gd
## Runs every test_*() method of every res://tests/test_*.gd (each extends TestCase).
## Exit code 0 = all passed. Script errors print "SCRIPT ERROR"; the wrapper treats those as failures.


func _initialize() -> void:
	# Load every script first. A script that fails to parse makes Class.new() return null, and a
	# test looping `while not battle.over` on that null spins forever (Phases 2 and 3). Stop early.
	var broken := _broken_scripts("res://scripts")
	if not broken.is_empty():
		for path in broken:
			print("FAIL %s does not compile (see SCRIPT ERROR above)" % path)
		print("\n%d scripts failed to compile; no tests run" % broken.size())
		quit(1)
		return
	var total := 0
	var failed := 0
	var files := Array(DirAccess.get_files_at("res://tests"))
	files.sort()
	for f in files:
		if not (f.begins_with("test_") and f.ends_with(".gd")) or f == "test_case.gd":
			continue
		var script = load("res://tests/" + f)
		if script == null or not (script as GDScript).can_instantiate():
			# A suite that fails to parse is a failure, not a crash: without this the runner died
			# before quit() and Godot hung forever (seen in Phase 2).
			total += 1
			failed += 1
			print("FAIL %s: script failed to load (see SCRIPT ERROR above)" % f)
			continue
		var suite: TestCase = script.new()
		for m in suite.get_method_list():
			var method: String = m["name"]
			if not method.begins_with("test_"):
				continue
			total += 1
			suite.current = "%s::%s" % [f.get_basename(), method]
			var before := suite.failures.size()
			suite.call(method)
			if suite.failures.size() > before:
				failed += 1
				for i in range(before, suite.failures.size()):
					print("FAIL ", suite.failures[i])
			else:
				print("ok   ", suite.current)
		suite.cleanup()
	print("\n%d tests, %d failed" % [total, failed])
	quit(1 if failed > 0 else 0)


func _broken_scripts(dir: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			var script = load(dir + "/" + f)
			if script == null or not (script as GDScript).can_instantiate():
				out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_broken_scripts(dir + "/" + d))
	return out
