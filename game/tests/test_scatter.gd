extends TestCase
## Phase G4: scatter placement on the real continent (Scatter + ScatterMeshes). Looks and FPS are
## checked with screenshots (tests/preview_terrain3d.gd, tools/godot.sh shot x.png --zoom=0.2).

var _nodes: Array[Node] = []
var _t: TerrainMap
var _mesh: TerrainMesh
var _cfg: Dictionary
var _settlements: Array = []
var _scatter: Scatter
var _ms := 0


func _build() -> Scatter:
	var s := Scatter.new()
	_nodes.append(s)
	s.setup(_t, _mesh, _cfg["scatter"], _settlements)
	return s


func _ready_world() -> Scatter:
	if _scatter == null:
		_t = TerrainMap.from_file("res://data/world/terrain.json")
		_cfg = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
		_mesh = TerrainMesh.build(_t, _cfg)
		var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/layout.json"))
		for s in layout["settlements"]:
			_settlements.append({"cell": Vector2i(int(s["x"]), int(s["y"])), "type": (s["id"] as String).get_slice("_", 0)})
		var start := Time.get_ticks_msec()
		_scatter = _build()
		_ms = Time.get_ticks_msec() - start
	return _scatter


func test_every_kind_is_placed_and_fast_to_build() -> void:
	var s := _ready_world()
	print("     Scatter: %d models in %d chunks, built in %d ms" % [s.count(), s.chunk_count, _ms])
	check(_ms < 2000, "built in %d ms" % _ms)
	for kind in ScatterMeshes_kinds():
		check(s.count(kind) > 100, "%s: %d placed" % [kind, s.count(kind)])
	check(s.count("conifer") + s.count("broadleaf") > 10000, "forests are full")


func test_models_sit_on_dry_land_off_roads_and_settlements() -> void:
	var s := _ready_world()
	var roads := {}
	for r in _t.roads:
		for c in r["cells"]:
			roads[c] = true
	var clear: Dictionary = _cfg["scatter"]["keep_clear"]
	var bad := {"water": 0, "road": 0, "settlement": 0, "height": 0}
	for kind in s.positions:
		for p in s.positions[kind]:
			var cell := Vector2i(floori(p.x), floori(p.z))
			if not _t.is_passable(cell):
				bad["water"] += 1
			if roads.has(cell):
				bad["road"] += 1
			if absf(p.y - _mesh.height_at(Vector2(p.x, p.z))) > 0.0001:
				bad["height"] += 1
			for st in _settlements:
				var r: float = clear[st["type"]]
				if Vector2(p.x, p.z).distance_squared_to(Vector2(st["cell"]) + Vector2(0.5, 0.5)) < r * r:
					bad["settlement"] += 1
	check_eq(bad, {"water": 0, "road": 0, "settlement": 0, "height": 0})


func test_kinds_follow_terrain() -> void:
	var s := _ready_world()
	var per_terrain: Dictionary = _cfg["scatter"]["terrain"]
	for kind in s.positions:
		var allowed := []
		for code in per_terrain:
			for entry in per_terrain[code]:
				if entry[0] == kind:
					allowed.append(code)
		var wrong := 0
		for p in s.positions[kind]:
			if not String.chr(_t.code_at(Vector2i(floori(p.x), floori(p.z)))) in allowed:
				wrong += 1
		check_eq(wrong, 0, "%s outside %s" % [kind, str(allowed)])
	# most forest cells (not on roads or by settlements) hold at least one tree
	var with_tree := {}
	for kind in ["conifer", "broadleaf"]:
		for p in s.positions[kind]:
			with_tree[Vector2i(floori(p.x), floori(p.z))] = true
	var forest := 0
	var wooded := 0
	for y in _t.height:
		for x in _t.width:
			if String.chr(_t.code_at(Vector2i(x, y))) == "f":
				forest += 1
				wooded += 1 if with_tree.has(Vector2i(x, y)) else 0
	check(wooded > forest * 0.75, "%d of %d forest cells have trees" % [wooded, forest])


func test_placement_is_deterministic() -> void:
	var a := _ready_world()
	var b := _build()
	for kind in a.positions:
		check_eq(b.positions[kind], a.positions[kind], kind)


func test_meshes_face_outward() -> void:
	# Every face's normal points away from the model's centre (bad winding renders inside-out).
	for kind in ["rock", "bush", "dune"]:
		var arrays := ScatterMeshes.build(kind).surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var centre := Vector3.ZERO
		for v in verts:
			centre += v
		centre /= verts.size()
		var inward := 0
		for i in range(0, verts.size(), 3):
			var mid := (verts[i] + verts[i + 1] + verts[i + 2]) / 3.0
			if normals[i].dot(mid - centre) < 0.0:
				inward += 1
		check_eq(inward, 0, kind)


func ScatterMeshes_kinds() -> Array:
	return (_cfg["scatter"]["kinds"] as Dictionary).keys()


func cleanup() -> void:
	for n in _nodes:
		n.free()
