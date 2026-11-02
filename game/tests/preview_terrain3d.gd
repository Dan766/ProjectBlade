extends SceneTree
## Renders the 3D map (Map3DView: terrain, sea, sky) from fixed cameras and saves PNGs + FPS:
##   <godot console exe> --path game --windowed --resolution 1600x900 -s res://tests/preview_terrain3d.gd -- --out=<dir>
## Writes <dir>/map3d_far.png, map3d_mid.png, map3d_near.png. Options: --views=far,mid
##   --mid=0.62,0.3 --near=0.8,0.55   (focus as a fraction of the map; snaps to the nearest settlement)
## A stand-in camera until the strategy camera (G3) exists.

const VIEWS := {                   # distance from focus, pitch in degrees
	"far": {"distance": 175.0, "pitch": 58.0},
	"mid": {"distance": 45.0, "pitch": 48.0},
	"near": {"distance": 13.0, "pitch": 36.0},
}


func _initialize() -> void:
	var args := {"out": "user://", "views": "far,mid,near", "mid": "0.62,0.3", "near": "0.8,0.55"}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	await process_frame                    # GameState loads in its _ready
	var gs = root.get_node("GameState")
	var t: TerrainMap = gs.terrain
	var colors := {}
	for f in gs.factions:
		colors[f] = gs.faction_color(f)
	var view := Map3DView.new()
	var start := Time.get_ticks_msec()
	var cells := []
	for id in gs.settlements:
		cells.append({"cell": gs.settlements[id]["cell"], "type": gs.settlements[id]["type"]})
	view.setup(t, colors, gs.map3d_config, cells)
	if view.scatter:
		print("AUTO scatter %d models in %d chunks" % [view.scatter.count(), view.scatter.chunk_count])
	print("AUTO map3d setup %d ms" % (Time.get_ticks_msec() - start))
	root.add_child(view)
	var cam := Camera3D.new()
	cam.far = 2000.0
	cam.fov = 50.0
	root.add_child(cam)

	for name in (args["views"] as String).split(","):
		var focus := Vector3(t.width * 0.5, 0.0, t.height * 0.5)
		if args.has(name):
			focus = _nearest_settlement(gs, view, Vector2(t.width, t.height) * _vec2(args[name]))
		var v: Dictionary = VIEWS[name]
		var pitch := deg_to_rad(float(v["pitch"]))
		var eye := focus + Vector3(0.0, sin(pitch), cos(pitch)) * float(v["distance"])
		cam.look_at_from_position(eye, focus)
		for i in 20:                       # let shadows and TAA settle
			await process_frame
		var frames := 0
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < 1_000_000:
			await process_frame
			frames += 1
		await RenderingServer.frame_post_draw
		var path := "%s/map3d_%s.png" % [args["out"], name]
		root.get_texture().get_image().save_png(path)
		print("AUTO %s: %d fps, saved %s" % [name, frames, path])
	quit()


func _vec2(s: String) -> Vector2:
	var p := s.split(",")
	return Vector2(float(p[0]), float(p[1]))


func _nearest_settlement(gs, view: Map3DView, target: Vector2) -> Vector3:
	var best := Vector2i.ZERO
	var best_d := INF
	for id in gs.settlements:
		var c: Vector2i = gs.settlements[id]["cell"]
		var d := Vector2(c).distance_squared_to(target)
		if d < best_d:
			best_d = d
			best = c
	return view.terrain_mesh.cell_to_3d(best)
