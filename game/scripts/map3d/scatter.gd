class_name Scatter
extends Node3D
## Trees, rocks, reeds, dune mounds and ash stumps on the 3D map (Phase G4). Placement is seeded and
## data-driven ("scatter" in res://data/config/map3d.json): models per cell by terrain type, varied
## by noise (clearings, groves), kept off water, roads, steep slopes (trees) and settlements.
## Drawn as one MultiMeshInstance3D per kind per chunk of cells, so whole chunks are frustum-culled
## and small kinds are hidden beyond their camera distance ("range").

const SHADER := preload("res://scripts/map3d/scatter.gdshader")
const TREES := ["conifer", "broadleaf", "deadtree"]

var positions: Dictionary = {}       # kind -> PackedVector3Array, world positions (tests, later systems)
var chunk_count := 0


## settlements: Array of {cell: Vector2i, type: String}.
@warning_ignore("integer_division")
func setup(t: TerrainMap, ground: TerrainMesh, cfg: Dictionary, settlements: Array) -> void:
	var chunk := int(cfg.get("chunk", 16))
	var kinds: Dictionary = cfg.get("kinds", {})
	var per_terrain: Dictionary = cfg.get("terrain", {})
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.get("seed", 1701))
	var noise := FastNoiseLite.new()
	noise.seed = int(cfg.get("seed", 1701))
	noise.frequency = float(cfg.get("noise_scale", 0.09))
	var strength := float(cfg.get("noise_strength", 0.9))
	var max_slope := float(cfg.get("tree_max_slope", 0.9))
	var snow_above := float(cfg.get("snow_tint_above", 5.2))
	var clear: Dictionary = cfg.get("keep_clear", {})

	var blocked := {}                                  # road cells
	for r in t.roads:
		for c in r["cells"]:
			blocked[c] = true
	var near: Array = []                               # [centre, radius] around settlements
	for s in settlements:
		near.append([Vector2(s["cell"]) + Vector2(0.5, 0.5), float(clear.get(s["type"], 1.0))])

	# chunk key -> kind -> [Transform3D...], [Color...]
	var buckets := {}
	for kind in kinds:
		positions[kind] = PackedVector3Array()
	for y in t.height:
		for x in t.width:
			var cell := Vector2i(x, y)
			var spec: Array = per_terrain.get(String.chr(t.code_at(cell)), [])
			if spec.is_empty() or blocked.has(cell):
				continue
			var density := clampf(1.0 + noise.get_noise_2d(x, y) * strength, 0.0, 2.0)
			for entry in spec:
				var kind: String = entry[0]
				var k: Dictionary = kinds[kind]
				var expect: float = float(entry[1]) * density
				var n := int(expect) + (1 if rng.randf() < expect - int(expect) else 0)
				for _i in n:
					var p := Vector2(x + rng.randf(), y + rng.randf())
					var yaw := rng.randf() * TAU
					var scale_range: Array = k.get("scale", [1.0, 1.0])
					var sc := rng.randf_range(float(scale_range[0]), float(scale_range[1]))
					var tints: Array = k.get("tints", ["#ffffff"])
					var tint := Color(tints[rng.randi() % tints.size()])
					var phase := rng.randf()
					var h := ground.height_at(p)
					if h < 0.05 or _near_settlement(p, near):
						continue
					if kind in TREES and _slope(ground, p) > max_slope:
						continue
					if kind == "conifer" and h > snow_above:
						tint = tint.lerp(Color("#eef2f4"), 0.55)   # frosted pines up high
					if k.get("align", false):
						yaw = 0.35 + rng.randf_range(-0.2, 0.2)    # dunes line up with the wind
					var key := Vector2i(x / chunk, y / chunk)
					if not buckets.has(key):
						buckets[key] = {}
					if not buckets[key].has(kind):
						buckets[key][kind] = [[], []]
					var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc)
					buckets[key][kind][0].append(Transform3D(basis, Vector3(p.x, h, p.y)))
					buckets[key][kind][1].append(Color(tint.r, tint.g, tint.b, phase))
					positions[kind].append(Vector3(p.x, h, p.y))
	_build_nodes(buckets, kinds, chunk)


func count(kind: String = "") -> int:
	if kind != "":
		return positions.get(kind, PackedVector3Array()).size()
	var total := 0
	for k in positions:
		total += positions[k].size()
	return total


func _build_nodes(buckets: Dictionary, kinds: Dictionary, chunk: int) -> void:
	var meshes := {}
	var materials := {}
	for kind in kinds:
		meshes[kind] = ScatterMeshes.build(kind)
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		if kinds[kind].get("double_sided", false):
			var sh := Shader.new()
			sh.code = SHADER.code.replace("cull_back", "cull_disabled")
			mat.shader = sh
		materials[kind] = mat
	for key in buckets:
		var origin := Vector3((key.x + 0.5) * chunk, 0.0, (key.y + 0.5) * chunk)
		for kind in buckets[key]:
			var xforms: Array = buckets[key][kind][0]
			var custom: Array = buckets[key][kind][1]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = meshes[kind]
			mm.instance_count = xforms.size()
			for i in xforms.size():
				var xf: Transform3D = xforms[i]
				xf.origin -= origin                      # instances relative to the chunk centre
				mm.set_instance_transform(i, xf)
				mm.set_instance_custom_data(i, custom[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%d_%d" % [kind, key.x, key.y]
			mmi.multimesh = mm
			mmi.position = origin
			mmi.material_override = materials[kind]
			var k: Dictionary = kinds[kind]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if k.get("shadow", false) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var range_end := float(k.get("range", 0))
			if range_end > 0.0:
				mmi.visibility_range_end = range_end
				mmi.visibility_range_end_margin = range_end * 0.15
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(mmi)
			chunk_count += 1


static func _near_settlement(p: Vector2, near: Array) -> bool:
	for n in near:
		if p.distance_squared_to(n[0]) < n[1] * n[1]:
			return true
	return false


static func _slope(ground: TerrainMesh, p: Vector2) -> float:
	var dx := ground.height_at(p + Vector2(0.25, 0)) - ground.height_at(p - Vector2(0.25, 0))
	var dz := ground.height_at(p + Vector2(0, 0.25)) - ground.height_at(p - Vector2(0, 0.25))
	return Vector2(dx, dz).length() / 0.5
