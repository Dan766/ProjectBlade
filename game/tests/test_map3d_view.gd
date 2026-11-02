extends TestCase
## Map3DView and MapTextures (Phase G2): data textures for the shaders and the assembled scene.
## Shaders are not compiled headless; screenshots (tests/preview_terrain3d.gd) cover the looks.
##   row 0  . . h      regions 1 1 2
##   row 1  ~ . h      regions 0 1 2   road from (0,0) to (2,1)

var _nodes: Array[Node] = []


func _map() -> TerrainMap:
	var t := TerrainMap.new()
	t.load_dict({
		"width": 3, "height": 2, "cell_size": 16,
		"legend": {"~": {"name": "water", "cost": 0}, ".": {"name": "plains", "cost": 1.0},
			"h": {"name": "hills", "cost": 1.8}},
		"rows": ["..h", "~.h"],
		"region_legend": {"1": "faction_01", "2": "faction_05"},
		"regions": ["112", "012"],
		"sea_level": 64, "heights": ["505080", "205080"],
		"roads": [{"a": "x", "b": "y", "kind": "road", "path": [0, 0, 1, 0, 2, 1]}],
	})
	return t


func test_region_masks_one_channel_per_region() -> void:
	var masks := MapTextures.region_masks(_map())
	check_eq(masks.size(), 2)
	check_eq(masks[0].get_pixel(0, 0), Color(1, 0, 0, 0), "region 1 -> red of the first mask")
	check_eq(masks[0].get_pixel(2, 0), Color(0, 1, 0, 0), "region 2 -> green")
	check_eq(masks[0].get_pixel(0, 1), Color(0, 0, 0, 0), "sea in no mask")
	check_eq(masks[1].get_pixel(1, 1), Color(0, 0, 0, 0), "second mask empty with 2 regions")


func test_road_image_marks_road_cells() -> void:
	var img := MapTextures.road_image(_map())
	var r := MapTextures.ROAD_RES
	check_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(3 * r, 2 * r))
	for cell in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 1)]:
		var c: Vector2i = cell * r + Vector2i(r / 2, r / 2)
		check(img.get_pixelv(c).r > 0.9, "road at centre of %s" % str(cell))
	check(img.get_pixelv(Vector2i(0, 1) * r + Vector2i(r / 2, r / 2)).r == 0.0, "no road in the sea cell")


func test_height_image_matches_mesh() -> void:
	var m := TerrainMesh.build(_map(), {"height_scale": 0.1, "smooth_passes": 0, "shore_margin": 0.1})
	var img := MapTextures.height_image(m)
	check_near(img.get_pixel(2, 0).r, (0x80 - 64) * 0.1, 0.0001)
	check_near(img.get_pixel(0, 1).r, (0x20 - 64) * 0.1, 0.0001)


func test_view_assembles_terrain_sea_sky() -> void:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/config/map3d.json"))
	var view := Map3DView.new()
	_nodes.append(view)
	view.setup(_map(), {"faction_01": Color("#1f6b6b"), "faction_05": Color.WHITE}, cfg)
	check(view.get_node_or_null("Terrain") is MeshInstance3D, "terrain node")
	check(view.get_node_or_null("Sea") is MeshInstance3D, "sea node")
	check(view.sun != null and view.sun.shadow_enabled, "sun with shadows")
	check(view.environment.fog_enabled, "fog on")
	var fc: PackedVector3Array = view.terrain_material.get_shader_parameter("faction_colors")
	var white := Color.WHITE.srgb_to_linear()
	check_eq(fc[2], Vector3(white.r, white.g, white.b), "region 2 colour, linear")
	check_eq(view.terrain_material.get_shader_parameter("snow_line"), cfg["terrain"]["snow_line"], "config applied")
	check(view.water_material.get_shader_parameter("shallow_color") is Color, "hex strings become colours")


func cleanup() -> void:
	for n in _nodes:
		n.free()
