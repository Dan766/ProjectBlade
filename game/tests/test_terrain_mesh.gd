extends TestCase
## TerrainMesh (Phase G1): heights from terrain.json become a 3D surface. A tiny hand-made map
## checks exact numbers; the real continent checks build time and that every settlement is on land.
##   row 0  ~ . h      heights 0x20 0x50 0x80, sea level 0x40 (64)
##   row 1  ~ . m      heights 0x20 0x60 0xc0

const CFG := {"height_scale": 0.1, "smooth_passes": 0, "shore_margin": 0.1}


func _map() -> TerrainMap:
	var t := TerrainMap.new()
	t.load_dict({
		"width": 3, "height": 2, "cell_size": 16,
		"legend": {"~": {"name": "water", "cost": 0}, ".": {"name": "plains", "cost": 1.0},
			"h": {"name": "hills", "cost": 1.8}, "m": {"name": "mountains", "cost": 4.0}},
		"rows": ["~.h", "~.m"],
		"region_legend": {"1": "faction_01"},
		"regions": ["011", "011"],
		"sea_level": 64,
		"heights": ["205080", "2060c0"],
		"roads": [{"a": "v", "b": "t", "kind": "track", "path": [1, 0, 2, 1]}],
	})
	return t


func test_terrain_map_loads_heights_and_roads() -> void:
	var t := _map()
	check(t.has_heights(), "heights loaded")
	check_eq(t.height_at(Vector2i(2, 1)), 0xc0)
	check_eq(t.height_at(Vector2i(9, 9)), 0xc0, "clamped to the map")
	check_eq(t.roads.size(), 1)
	check_eq(t.roads[0]["cells"], [Vector2i(1, 0), Vector2i(2, 1)] as Array[Vector2i])


func test_vertices_centres_and_corners() -> void:
	var m := TerrainMesh.build(_map(), CFG)
	check_eq(m.grid_size, Vector2i(7, 5))
	var arrays := m.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	check_eq(verts.size(), 35)
	check_eq((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 6 * 4 * 6)
	check_near(m.cell_height(Vector2i(1, 0)), (0x50 - 64) * 0.1, 0.0001, "centre = its cell")
	check_near(m.cell_height(Vector2i(2, 1)), (0xc0 - 64) * 0.1, 0.0001)
	check_near(m.cell_height(Vector2i(0, 0)), (0x20 - 64) * 0.1, 0.0001, "water stays below the sea")
	# vertex (4, 2) is the corner shared by cells (1,0) (2,0) (1,1) (2,1)
	var corner := (0x50 + 0x80 + 0x60 + 0xc0 - 4 * 64) * 0.1 / 4.0
	check_near(verts[2 * 7 + 4].y, corner, 0.0001, "corner = average of 4 cells")
	check_near(m.height_at(Vector2(2.0, 1.0)), corner, 0.0001)
	check_eq(m.cell_to_3d(Vector2i(2, 1)), Vector3(2.5, m.cell_height(Vector2i(2, 1)), 1.5))


func test_shore_margin_keeps_land_above_sea() -> void:
	var t := _map()
	t.heights[1] = 64                    # a plains cell exactly at sea level
	var m := TerrainMesh.build(t, CFG)
	check_near(m.cell_height(Vector2i(1, 0)), 0.1, 0.0001)


func test_splat_weights_sum_to_one() -> void:
	var m := TerrainMesh.build(_map(), CFG)
	var arrays := m.mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var custom: PackedByteArray = arrays[Mesh.ARRAY_CUSTOM0]
	for idx in colors.size():
		var c := colors[idx]
		var s := c.r + c.g + c.b + c.a + (custom[idx * 4] + custom[idx * 4 + 1] + custom[idx * 4 + 2] + custom[idx * 4 + 3]) / 255.0
		check_near(s, 1.0, 0.01, "vertex %d" % idx)
	var mountain_centre := 3 * 7 + 5
	check_eq(custom[mountain_centre * 4], 255, "mountain centre is all mountain")
	check_near(colors[1 * 7 + 1].r, 1.0, 0.001, "water centre is all water")


func test_height_at_is_the_rendered_surface() -> void:
	var m := TerrainMesh.build(_map(), CFG)
	var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for v in verts:
		check_near(m.height_at(Vector2(v.x, v.z)), v.y, 0.0001, "at %s" % str(v))
	# midpoint of the quad diagonal b-c lies on both triangles
	var mid := m.height_at(Vector2(1.25, 0.25))
	check_near(mid, (verts[0 * 7 + 3].y + verts[1 * 7 + 2].y) / 2.0, 0.0001)


func test_real_continent_builds_fast_and_settlements_are_on_land() -> void:
	var t := TerrainMap.from_file("res://data/world/terrain.json")
	check(t != null and t.has_heights(), "terrain.json has heights (rerun tools/gen_map.py)")
	if t == null or not t.has_heights():
		return
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
	var start := Time.get_ticks_msec()
	var m := TerrainMesh.build(t, cfg)
	var ms := Time.get_ticks_msec() - start
	print("     TerrainMesh: %dx%d vertices, %d triangles, built in %d ms" % [m.grid_size.x, m.grid_size.y,
		(m.grid_size.x - 1) * (m.grid_size.y - 1) * 2, ms])
	check(ms < 2000, "built in %d ms (limit 2000)" % ms)

	# Unsmoothed, every cell centre is exactly the exported height.
	var raw := TerrainMesh.build(t, {"height_scale": cfg["height_scale"], "smooth_passes": 0, "shore_margin": 0.0})
	var scale := float(cfg["height_scale"])
	var bad := 0
	for y in t.height:
		for x in t.width:
			var c := Vector2i(x, y)
			if absf(raw.cell_height(c) - (t.height_at(c) - t.sea_level) * scale) > 0.0001:
				bad += 1
			if (m.cell_height(c) > 0.0) != t.is_passable(c):
				bad += 1
	check_eq(bad, 0, "cells off the data or on the wrong side of the sea")

	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/layout.json"))
	var verts: PackedVector3Array = m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check_eq(layout["settlements"].size(), 164)
	for s in layout["settlements"]:
		var cell := Vector2i(int(s["x"]), int(s["y"]))
		var v := verts[(cell.y * 2 + 1) * m.grid_size.x + cell.x * 2 + 1]
		check(v.y > 0.0, "%s at %s is above the sea (%.2f)" % [s["id"], str(cell), v.y])
		check_near(m.height_at(Vector2(cell) + Vector2(0.5, 0.5)), v.y, 0.0001, s["id"])
	check_eq(t.roads.size() > 100, true, "roads loaded")
