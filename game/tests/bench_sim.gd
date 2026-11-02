extends SceneTree
## Simulation benchmark (not a test):
##   <godot> --headless --path game -s res://tests/bench_sim.gd -- --days=3
## Prints wall time per simulated day and where the time goes.


func _initialize() -> void:
	var days := 3
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--days="):
			days = int(arg.trim_prefix("--days="))
	var gs = load("res://scripts/autoload/game_state.gd").new()
	gs.load_all("res://data/generated", "res://data/world")
	var w: World = gs.new_world(42)
	var decisions := [0]
	var t_total := Time.get_ticks_msec()
	for d in days:
		var t0 := Time.get_ticks_msec()
		w.step(24.0)
		print("day %d: %d ms, parties %d, events %s" % [d + 1, Time.get_ticks_msec() - t0, w.parties.size(), str(w.event_counts)])
	print("total %d ms for %d days" % [Time.get_ticks_msec() - t_total, days])
	gs.free()
	quit(0)
