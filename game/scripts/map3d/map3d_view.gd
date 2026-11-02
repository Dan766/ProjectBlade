class_name Map3DView
extends Node3D
## The static part of the 3D campaign map (Phase G2): terrain with its splat shader, the sea,
## sky, fog and sun. Camera (G3), scatter (G4), settlements (G5) and parties (G6) are added on top.
## Everything visual is tuned in res://data/config/map3d.json.

const TERRAIN_SHADER := preload("res://scripts/map3d/terrain.gdshader")
const WATER_SHADER := preload("res://scripts/map3d/water.gdshader")

var terrain_mesh: TerrainMesh
var terrain_material: ShaderMaterial
var water_material: ShaderMaterial
var environment: Environment
var sun: DirectionalLight3D
var scatter: Scatter


## faction_colors: faction id -> Color (banner primary). settlements: [{cell, type}], kept clear of
## scatter; pass none (or set "scatter" to {} in cfg) for a bare map.
func setup(t: TerrainMap, faction_colors: Dictionary, cfg: Dictionary, settlements: Array = []) -> void:
	terrain_mesh = TerrainMesh.build(t, cfg)
	var map_size := Vector2(t.width, t.height)

	terrain_material = ShaderMaterial.new()
	terrain_material.shader = TERRAIN_SHADER
	var palette := PackedVector3Array()
	var colors: Dictionary = cfg.get("terrain_colors", {})
	for k in TerrainMesh.SPLAT_ORDER.length():
		var c := Color(colors.get(TerrainMesh.SPLAT_ORDER[k], "#808080")).srgb_to_linear()
		palette.append(Vector3(c.r, c.g, c.b))
	terrain_material.set_shader_parameter("terrain_colors", palette)
	terrain_material.set_shader_parameter("faction_colors", MapTextures.region_colors(t, faction_colors))
	var masks := MapTextures.region_masks(t)
	terrain_material.set_shader_parameter("region_a", ImageTexture.create_from_image(masks[0]))
	terrain_material.set_shader_parameter("region_b", ImageTexture.create_from_image(masks[1]))
	terrain_material.set_shader_parameter("road_tex", ImageTexture.create_from_image(MapTextures.road_image(t)))
	terrain_material.set_shader_parameter("map_size", map_size)
	_apply(terrain_material, cfg.get("terrain", {}))
	var ground := MeshInstance3D.new()
	ground.name = "Terrain"
	ground.mesh = terrain_mesh.mesh
	ground.material_override = terrain_material
	add_child(ground)

	var wcfg: Dictionary = cfg.get("water", {})
	water_material = ShaderMaterial.new()
	water_material.shader = WATER_SHADER
	water_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(MapTextures.height_image(terrain_mesh)))
	water_material.set_shader_parameter("map_size", map_size)
	_apply(water_material, wcfg)
	var margin := float(wcfg.get("margin", 200))
	var plane := PlaneMesh.new()
	plane.size = map_size + Vector2(margin, margin) * 2.0
	plane.subdivide_width = int(plane.size.x / 2.0)
	plane.subdivide_depth = int(plane.size.y / 2.0)
	var sea := MeshInstance3D.new()
	sea.name = "Sea"
	sea.mesh = plane
	sea.position = Vector3(map_size.x * 0.5, 0.0, map_size.y * 0.5)
	sea.material_override = water_material
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sea)

	var scfg: Dictionary = cfg.get("scatter", {})
	if not scfg.is_empty():
		scatter = Scatter.new()
		scatter.name = "Scatter"
		scatter.setup(t, terrain_mesh, scfg, settlements)
		add_child(scatter)

	_build_sky(cfg.get("sky", {}))


func _build_sky(s: Dictionary) -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(s.get("top_color", "#5b8fcf"))
	sky_mat.sky_horizon_color = Color(s.get("horizon_color", "#d3dee6"))
	sky_mat.ground_horizon_color = Color(s.get("horizon_color", "#d3dee6"))
	sky_mat.ground_bottom_color = Color(s.get("ground_color", "#2b4a63"))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = float(s.get("ambient_energy", 0.55))
	var tonemappers := {"linear": Environment.TONE_MAPPER_LINEAR, "filmic": Environment.TONE_MAPPER_FILMIC,
		"aces": Environment.TONE_MAPPER_ACES, "agx": Environment.TONE_MAPPER_AGX}
	environment.tonemap_mode = tonemappers.get(s.get("tonemap", "aces"), Environment.TONE_MAPPER_ACES)
	environment.tonemap_exposure = float(s.get("exposure", 1.0))
	environment.fog_enabled = true
	environment.fog_light_color = Color(s.get("fog_color", "#c4d2dc"))
	environment.fog_density = float(s.get("fog_density", 0.0035))
	environment.fog_sky_affect = float(s.get("fog_sky_affect", 0.25))
	environment.fog_aerial_perspective = float(s.get("fog_aerial_perspective", 0.3))
	var we := WorldEnvironment.new()
	we.environment = environment
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(float(s.get("sun_pitch", -48)), float(s.get("sun_yaw", -35)), 0.0)
	sun.light_color = Color(s.get("sun_color", "#fff1dc"))
	sun.light_energy = float(s.get("sun_energy", 1.15))
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = float(s.get("shadow_distance", 260))
	add_child(sun)


## Copies config keys onto same-named shader uniforms; "#rrggbb" strings become colours.
static func _apply(mat: ShaderMaterial, values: Dictionary) -> void:
	for key in values:
		var v = values[key]
		if v is String and (v as String).begins_with("#"):
			v = Color(v)
		mat.set_shader_parameter(key, v)
