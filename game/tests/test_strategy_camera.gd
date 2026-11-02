extends TestCase
## Phase G3: picking on the 3D terrain (TerrainMesh.raycast) and the StrategyCamera rig.
## Screen rays use StrategyCamera.screen_ray for a 1600x900 screen (the game uses the same call;
## it matches Camera3D.project_ray_normal, checked in a running window, see docs/PROGRESS.md).

const SCREEN := Vector2(1600, 900)

var _nodes: Array[Node] = []
var _terrain: TerrainMap
var _mesh: TerrainMesh


func _real() -> TerrainMesh:
	if _mesh == null:
		_terrain = TerrainMap.from_file("res://data/world/terrain.json")
		var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
		_mesh = TerrainMesh.build(_terrain, cfg)
	return _mesh


func _cam_cfg() -> Dictionary:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
	return cfg["camera"]


func _rig() -> StrategyCamera:
	var rig := StrategyCamera.new()
	_nodes.append(rig)
	var m := _real()
	rig.setup(Vector2(m.map_size), m, _cam_cfg())
	return rig


func _pick(rig: StrategyCamera, px: Vector2) -> Variant:
	var ray := rig.screen_ray(px, SCREEN)
	return _mesh.raycast(ray[0], ray[1])


func _tiny() -> TerrainMesh:
	var t := TerrainMap.new()
	t.load_dict({
		"width": 4, "height": 1, "cell_size": 16,
		"legend": {"~": {"name": "water", "cost": 0}, ".": {"name": "plains", "cost": 1.0}, "m": {"name": "mountains", "cost": 4.0}},
		"rows": ["~..m"], "region_legend": {"1": "faction_01"}, "regions": ["0111"],
		"sea_level": 64, "heights": ["20505064"],     # sea, flat land at +16, +16, a peak at +100 (0x64)
	})
	return TerrainMesh.build(t, {"height_scale": 0.1, "smooth_passes": 0, "shore_margin": 0.1})


func test_ray_straight_down_hits_the_cell_surface() -> void:
	var m := _tiny()
	var hit = m.raycast(Vector3(1.5, 50.0, 0.5), Vector3.DOWN)
	check(hit is Vector3, "hit")
	if hit is Vector3:
		check_near(hit.y, m.cell_height(Vector2i(1, 0)), 0.001)
		check_eq(Vector2i(floori(hit.x), floori(hit.z)), Vector2i(1, 0))
	var sea = m.raycast(Vector3(0.3, 50.0, 0.5), Vector3.DOWN)
	check(sea is Vector3 and absf(sea.y) < 0.001, "rays over the sea stop at the water surface")
	check(m.raycast(Vector3(1.5, 50.0, 0.5), Vector3(0.2, 1.0, 0.0)) == null, "a ray into the sky hits nothing")


func test_slanted_ray_stops_at_the_first_slope_it_meets() -> void:
	var m := _tiny()
	var origin := Vector3(-2.0, 5.0, 0.5)
	var dir := Vector3(1.0, -0.25, 0.0).normalized()
	var hit = m.raycast(origin, dir)
	check(hit is Vector3, "hit")
	if not hit is Vector3:
		return
	check_near(hit.y, maxf(m.height_at(Vector2(hit.x, hit.z)), 0.0), 0.002, "on the surface")
	var t := origin.distance_to(hit)
	for i in 50:                                       # nothing along the ray before it was underground
		var p := origin + dir * (t * i / 50.0)
		check(p.y >= maxf(m.height_at(Vector2(p.x, p.z)), 0.0) - 0.002, "ray passed under ground at %s" % str(p))


func test_screen_centre_picks_the_focused_settlement_cell() -> void:
	var rig := _rig()
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/layout.json"))
	for s in layout["settlements"].slice(0, 164, 9):     # every 9th settlement: towns, castles, villages
		var cell := Vector2i(int(s["x"]), int(s["y"]))
		for z in [0.0, 0.5, 1.0]:
			rig.zoom = z
			rig.look_at_world(Vector2(cell) + Vector2(0.5, 0.5))
			rig.snap()
			# Aim a hair under the surface: a ray aimed exactly at a crest can graze it and fly on.
			var px := rig.world_to_screen(rig.focus_point() - Vector3(0, 0.03, 0), SCREEN)
			check(px.distance_to(SCREEN * 0.5) < 12.0, "focus is mid-screen (%s)" % str(px))
			var hit = _pick(rig, px)
			check(hit is Vector3, "%s zoom %.1f: hit" % [s["id"], z])
			if hit is Vector3:
				check_eq(Vector2i(floori(hit.x), floori(hit.z)), cell, "%s zoom %.1f" % [s["id"], z])


func test_off_centre_pick_round_trips_to_the_same_pixel() -> void:
	var rig := _rig()
	rig.look_at_world(Vector2(120, 75))
	rig.zoom = 0.45
	rig.yaw = 0.7
	rig.snap()
	for px in [Vector2(200, 300), Vector2(1400, 700), Vector2(900, 120)]:
		var hit = _pick(rig, px)
		check(hit is Vector3, "hit at %s" % str(px))
		if hit is Vector3:
			var back := rig.world_to_screen(hit, SCREEN)
			check(back.distance_to(px) < 1.0, "%s -> %s -> %s" % [str(px), str(hit), str(back)])


func test_rig_clamps_pans_and_rotates() -> void:
	var rig := _rig()
	rig.pan(Vector2(-1, -1), 10000.0)
	check_eq(rig.pivot, Vector2(0, 0), "clamped to the map's corner")
	rig.yaw = 0.0
	rig.look_at_world(Vector2(100, 70))
	rig.pan(Vector2(0, -1), 5.0)                       # W at yaw 0 = north (-z)
	check(rig.pivot.distance_to(Vector2(100, 65)) < 0.001, "W pans north: %s" % str(rig.pivot))
	rig.rotate_by(PI * 0.5)
	rig.pan(Vector2(0, -1), 5.0)                       # turned 90 degrees left: forward is now west
	check(rig.pivot.distance_to(Vector2(95, 65)) < 0.001, "W pans west after Q: %s" % str(rig.pivot))
	rig.zoom_toward(5.0)
	check_eq(rig.zoom, 1.0)
	rig.zoom_toward(-5.0)
	check_eq(rig.zoom, 0.0)


func test_zoom_curve_and_camera_never_underground() -> void:
	var rig := _rig()
	var last_d := 0.0
	var last_p := 0.0
	for i in 11:
		rig.zoom = i / 10.0
		check(rig.distance() > last_d and rig.pitch_degrees() > last_p, "farther and steeper as zoom grows")
		last_d = rig.distance()
		last_p = rig.pitch_degrees()
	var peak := Vector2i.ZERO                           # highest cell: look at it from the nearest zoom
	for y in _mesh.map_size.y:
		for x in _mesh.map_size.x:
			if _mesh.cell_height(Vector2i(x, y)) > _mesh.cell_height(peak):
				peak = Vector2i(x, y)
	rig.zoom = 0.0
	for k in 8:
		rig.yaw = k * TAU / 8.0
		rig.look_at_world(Vector2(peak) + Vector2(0.5, 0.5) + Vector2(sin(rig.yaw), cos(rig.yaw)) * -4.0)
		var eye := rig.target_transform().origin
		check(eye.y >= _mesh.height_at(Vector2(eye.x, eye.z)) + 0.99, "eye above ground at yaw %d" % k)


func test_zoom_level_mapping() -> void:
	check_near(MapView3D.rig_zoom_for_level(3.0), 0.0, 0.0001, "nearest")
	check_near(MapView3D.rig_zoom_for_level(0.2), 1.0, 0.0001, "farthest")
	for z in [0.25, 0.6, 1.0, 2.2]:
		check_near(MapView3D.level_for_rig_zoom(MapView3D.rig_zoom_for_level(z)), z, 0.0001)


func cleanup() -> void:
	for n in _nodes:
		n.free()
