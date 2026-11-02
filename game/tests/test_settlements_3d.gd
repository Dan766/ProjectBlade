extends TestCase
## Phase G5: settlement models on the real continent (Settlements3D + SettlementMeshes): all 164
## placed on the terrain, owner colours follow captures at once, siege camps come and go.
## Looks are checked with screenshots (docs/screenshots/g5/).

var _nodes: Array[Node] = []
var _mesh: TerrainMesh
var _cfg: Dictionary
var _list: Array = []                 # [{id, cell, type, culture}]
var _colors := {}


func _models() -> Settlements3D:
	if _mesh == null:
		var t := TerrainMap.from_file("res://data/world/terrain.json")
		_cfg = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
		_mesh = TerrainMesh.build(t, _cfg)
		var bundle := {}
		for s in JSON.parse_string(FileAccess.get_file_as_string("res://data/generated/world/settlements.json")):
			bundle[s["id"]] = s
		var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/layout.json"))
		for s in layout["settlements"]:
			var b: Dictionary = bundle[s["id"]]
			_list.append({"id": s["id"], "cell": Vector2i(int(s["x"]), int(s["y"])), "type": b["type"], "culture": b["faction"]})
		for f in JSON.parse_string(FileAccess.get_file_as_string("res://data/generated/world/factions.json")):
			_colors[f["id"]] = Color(f["colors"]["primary"])
	var m := Settlements3D.new()
	_nodes.append(m)
	m.setup(_mesh, _list, _colors, _cfg["settlements"])
	return m


func _home_owners() -> Dictionary:
	var out := {}
	for s in _list:
		out[s["id"]] = s["culture"]
	return out


func test_all_164_sit_on_the_terrain() -> void:
	var m := _models()
	check_eq(m.info.size(), 164)
	var sink := SettlementMeshes.SINK
	for s in _list:
		var i: Dictionary = m.info[s["id"]]
		var pos: Vector3 = i["pos"]
		var ground := _mesh.height_at(Vector2(pos.x, pos.z))
		var sc: float = float(_cfg["settlements"]["scale"][s["type"]])
		check(pos.y > 0.0, "%s above the sea" % s["id"])
		check(pos.y >= ground - 0.0001 and pos.y <= ground + sink * sc, "%s seated on the ground (%.2f vs %.2f)" % [s["id"], pos.y, ground])
		check_eq(Vector2i(floori(pos.x), floori(pos.z)), s["cell"], s["id"])
	var instances := 0
	for key in m.groups:
		instances += (m.groups[key] as MultiMeshInstance3D).multimesh.instance_count
	check_eq(instances, 164, "one model instance each")


func test_owner_colour_changes_on_the_next_refresh() -> void:
	var m := _models()
	var owners := _home_owners()
	check_eq(m.refresh(owners, {}), 164, "first refresh paints everyone")
	check_eq(m.drawn_color("town_01_01"), _colors["faction_01"])
	check_eq(m.refresh(owners, {}), 0, "nothing changed, nothing repainted")
	owners["town_01_01"] = "faction_03"                      # captured
	check_eq(m.refresh(owners, {}), 1)
	check_eq(m.drawn_color("town_01_01"), _colors["faction_03"], "recoloured at once")
	check(float(_cfg["settlements"]["refresh_seconds"]) <= 1.0, "the view refreshes at least once a second")


func test_siege_camps_come_and_go() -> void:
	var m := _models()
	var owners := _home_owners()
	m.refresh(owners, {"castle_05_02": "faction_04", "town_03_01": "faction_05"})
	var per := int(_cfg["settlements"]["siege"]["tents"])
	check_eq(m.tent_count(), per * 2)
	check_eq(m.smoke_count(), 2)
	m.refresh(owners, {"town_03_01": "faction_05"})
	check_eq(m.tent_count(), per)
	check_eq(m.smoke_count(), 1)
	m.refresh(owners, {})
	check_eq(m.tent_count(), 0)
	check_eq(m.smoke_count(), 0)


func test_every_culture_builds_every_type_with_owner_parts() -> void:
	_models()
	var cultures: Dictionary = _cfg["settlements"]["cultures"]
	for f in cultures:
		for kind in ["village", "castle", "town"]:
			for v in int(_cfg["settlements"]["variants"]):
				var mesh := SettlementMeshes.build(kind, v, cultures[f], _cfg["settlements"]["field_colors"], _cfg["settlements"]["dirt"])
				var arrays := mesh.surface_get_arrays(0)
				var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				var tinted := 0
				for c in colors:
					tinted += 1 if c.a < 0.5 else 0
				var name := "%s %s %d" % [cultures[f]["style"], kind, v]
				check(tinted > 0, "%s has owner-coloured parts" % name)
				var box := mesh.get_aabb()
				var r: float = Settlements3D.RADIUS[kind]
				check(maxf(absf(box.position.x), absf(box.end.x)) <= r and maxf(absf(box.position.z), absf(box.end.z)) <= r,
					"%s fits its %.2f footprint: %s" % [name, r, str(box)])
				check(box.end.y <= Settlements3D.TOP[kind] + 0.01, "%s below its label height: %.2f" % [name, box.end.y])


func cleanup() -> void:
	for n in _nodes:
		n.free()
