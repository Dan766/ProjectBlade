extends TestCase
## Phase G6: parties on the 3D map (Parties3D, PartyMeshes, MapView3D.nearest_on_screen).
## FPS with 300 parties at 4x and the hover card are checked in a window (docs/PROGRESS.md).

class FakeWorld:
	var parties: Array = []
	var time := 10.0

var _nodes: Array[Node] = []
var _mesh: TerrainMesh
var _cfg: Dictionary


func _view(w) -> Parties3D:
	if _mesh == null:
		var t := TerrainMap.from_file("res://data/world/terrain.json")
		_cfg = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
		_mesh = TerrainMesh.build(t, _cfg)
	var v := Parties3D.new()
	_nodes.append(v)
	v.setup(w, _mesh, 16.0, {"faction_01": Color("#1f6b6b")}, _cfg["parties"])
	return v


func _party(id: String, kind: String, cell: Vector2) -> Party:
	var p := Party.new(id, cell * 16.0)
	p.kind = kind
	p.faction = "faction_01" if kind != "bandit" else ""
	return p


func test_one_instance_per_active_party_per_kind() -> void:
	var w := FakeWorld.new()
	w.parties = [_party("l1", "lord", Vector2(120, 75)), _party("l2", "lord", Vector2(122, 75)),
		_party("b1", "bandit", Vector2(100, 70)), _party("c1", "caravan", Vector2(130, 80)),
		_party("me", "player", Vector2(121, 76))]
	var gone := _party("l3", "lord", Vector2(90, 60))
	gone.routed_until = 99.0                             # off the map until then
	w.parties.append(gone)
	var v := _view(w)
	v.sync(1.0, 0.016)
	check_eq([v.count("lord"), v.count("bandit"), v.count("caravan"), v.count("player")], [2, 1, 1, 1])
	check_eq(v.shown.size(), 4, "the player is not hoverable as a party")
	for entry in v.shown:
		var p: Party = entry[0]
		var xz: Vector2 = p.position / 16.0
		check_near(entry[1].y - 0.3, maxf(_mesh.height_at(xz), 0.0), 0.0001, "%s anchored above its ground" % p.id)


func test_parties_turn_toward_where_they_go() -> void:
	var w := FakeWorld.new()
	var p := _party("l1", "lord", Vector2(120, 75))
	w.parties = [p]
	var v := _view(w)
	v.sync(1.0, 0.016)
	for i in 120:                                        # ride east (+x) for two seconds of frames
		p.position += Vector2(0.05, 0) * 16.0
		v.sync(1.0, 0.016)
	check(absf(angle_difference(v._yaw["l1"], atan2(-1.0, 0.0))) < 0.05, "facing east: yaw %.2f" % v._yaw["l1"])


func test_scale_grows_with_distance_within_limits() -> void:
	var v := _view(FakeWorld.new())
	var lo := float(_cfg["parties"]["scale_min"])
	var hi := float(_cfg["parties"]["scale_max"])
	check_eq(v.scale_for(0.1), lo)
	check_eq(v.scale_for(10000.0), hi)
	check(v.scale_for(40.0) > v.scale_for(20.0) or v.scale_for(20.0) == lo, "monotonic")


func test_hover_picks_the_banner_nearest_the_pointer_on_screen() -> void:
	var a := _party("a", "lord", Vector2.ZERO)
	var b := _party("b", "caravan", Vector2.ZERO)
	var shown := [[a, Vector3(10, 1, 10)], [b, Vector3(12, 1, 10)]]
	var project := func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) * 10.0
	var never := func(_p: Vector3) -> bool: return false
	check_eq(MapView3D.nearest_on_screen(shown, Vector2(103, 100), project, never), a)
	check_eq(MapView3D.nearest_on_screen(shown, Vector2(118, 101), project, never), b)
	check_eq(MapView3D.nearest_on_screen(shown, Vector2(150, 100), project, never), null, "nothing within 16 px")
	var behind := func(p: Vector3) -> bool: return p.x < 11.0
	check_eq(MapView3D.nearest_on_screen(shown, Vector2(103, 100), project, behind), null, "behind the camera is skipped")


func test_party_meshes_have_realm_coloured_parts() -> void:
	for kind in ["lord", "player", "caravan"]:
		var colors: PackedColorArray = PartyMeshes.build(kind).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		check(Array(colors).any(func(c): return c.a < 0.5), "%s has a realm-coloured flag" % kind)
	var bandit: PackedColorArray = PartyMeshes.build("bandit").surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(not Array(bandit).any(func(c): return c.a < 0.5), "bandits fly their own rag")


func cleanup() -> void:
	for n in _nodes:
		n.free()
