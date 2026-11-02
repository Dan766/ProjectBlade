class_name Settlements3D
extends Node3D
## Every settlement as a 3D model on the map (Phase G5): architecture from its founding realm's
## culture (SettlementMeshes), flags and keep roofs in the current owner's colour, and a siege camp
## (tents in the besieger's colour + smoke) around besieged forts. One MultiMeshInstance3D per
## (culture, type, variant). refresh() is cheap; the view calls it every "refresh_seconds".

const SHADER := preload("res://scripts/map3d/settlement.gdshader")
const TOP := {"town": 0.95, "castle": 0.75, "village": 0.45}       # model height to the flag tips
const RADIUS := {"town": 1.05, "castle": 0.55, "village": 0.75}     # model footprint radius

var colors: Dictionary = {}           # faction id -> Color
var info: Dictionary = {}             # id -> {group, index, pos: Vector3, type, top, radius} (scaled)
var groups: Dictionary = {}           # group key -> MultiMeshInstance3D
var owners: Dictionary = {}           # id -> faction, as last drawn
var sieges: Dictionary = {}           # id -> besieging faction, as last drawn
var cfg: Dictionary = {}
var _material: ShaderMaterial
var _ground: TerrainMesh
var _tents: MultiMeshInstance3D
var _smoke: Dictionary = {}           # id -> CPUParticles3D
var _drawn: Dictionary = {}           # id -> owner colour last written to its instance


## settlements: [{id, cell: Vector2i, type, culture}]; faction_colors: faction -> Color.
func setup(ground: TerrainMesh, settlements: Array, faction_colors: Dictionary, c: Dictionary) -> void:
	_ground = ground
	colors = faction_colors
	cfg = c
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	var cultures: Dictionary = cfg.get("cultures", {})
	var scales: Dictionary = cfg.get("scale", {})
	var variants := int(cfg.get("variants", 2))
	var members := {}                                   # group -> [ids]
	var sorted := settlements.duplicate()
	sorted.sort_custom(func(a, b): return a["id"] < b["id"])
	for s in sorted:
		var id: String = s["id"]
		var key := "%s/%s/%d" % [s["culture"], s["type"], absi(hash(id)) % variants]
		if not members.has(key):
			members[key] = []
		members[key].append(s)
	for key in members:
		var parts: PackedStringArray = (key as String).split("/")
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = SettlementMeshes.build(parts[1], int(parts[2]), cultures.get(parts[0], {}),
			cfg.get("field_colors", ["#b0a050"]), cfg.get("dirt", "#9c8460"))
		mm.instance_count = members[key].size()
		for i in members[key].size():
			var s: Dictionary = members[key][i]
			var cell: Vector2i = s["cell"]
			var yaw := float(absi(hash(s["id"] + "yaw")) % 360) * PI / 180.0
			var sc := float(scales.get(s["type"], 1.0))
			var pos := Vector3(cell.x + 0.5, seat_height(ground, Vector2(cell) + Vector2(0.5, 0.5),
				float(RADIUS[s["type"]]) * sc, SettlementMeshes.SINK * sc), cell.y + 0.5)
			mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc), pos))
			mm.set_instance_custom_data(i, Color.WHITE)
			info[s["id"]] = {"group": key, "index": i, "pos": pos, "type": s["type"],
				"top": float(TOP[s["type"]]) * sc, "radius": float(RADIUS[s["type"]]) * sc}
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key.replace("/", "_")
		mmi.multimesh = mm
		mmi.material_override = _material
		add_child(mmi)
		groups[key] = mmi

	_tents = MultiMeshInstance3D.new()
	_tents.name = "SiegeTents"
	var tm := MultiMesh.new()
	tm.transform_format = MultiMesh.TRANSFORM_3D
	tm.use_custom_data = true
	tm.mesh = _tent_mesh()
	_tents.multimesh = tm
	_tents.material_override = _material
	add_child(_tents)


## owners_now: id -> faction; sieges_now: id -> besieging faction (only besieged forts).
## Returns how many settlements changed colour. Siege camps are rebuilt when the set changes.
func refresh(owners_now: Dictionary, sieges_now: Dictionary) -> int:
	var changed := 0
	for id in owners_now:
		if owners.get(id, "") == owners_now[id] or not info.has(id):
			continue
		owners[id] = owners_now[id]
		var c: Color = colors.get(owners_now[id], Color.GRAY)
		var i: Dictionary = info[id]
		(groups[i["group"]] as MultiMeshInstance3D).multimesh.set_instance_custom_data(i["index"], Color(c.r, c.g, c.b, 1.0))
		_drawn[id] = Color(c.r, c.g, c.b, 1.0)
		changed += 1
	if sieges_now != sieges:
		sieges = sieges_now.duplicate()
		_build_camps()
	return changed


## Model base height on a slope: the highest ground under the footprint (so the uphill side isn't
## buried), but at most `sink` above the centre (the walls reach that far down, so nothing floats).
static func seat_height(ground: TerrainMesh, centre: Vector2, radius: float, sink: float) -> float:
	var c := maxf(ground.height_at(centre), 0.0)
	var top := c
	for k in 8:
		var a := TAU * k / 8.0
		top = maxf(top, ground.height_at(centre + Vector2(cos(a), sin(a)) * radius * 0.8))
	return minf(top, c + sink * 0.8)


## The owner colour a settlement is drawn with right now (tests, label icons). Kept here because
## MultiMesh data can't be read back under the headless (dummy) renderer.
func drawn_color(id: String) -> Color:
	return _drawn.get(id, Color.WHITE)


func tent_count() -> int:
	return _tents.multimesh.instance_count


func smoke_count() -> int:
	return _smoke.size()


func _build_camps() -> void:
	var sc: Dictionary = cfg.get("siege", {})
	var per := int(sc.get("tents", 7))
	var gap := float(sc.get("radius", 0.5))           # camp ring: this far outside the walls
	var tent_scale := float(sc.get("tent_scale", 2.2))
	var xforms := []
	var tints := []
	for id in sieges:
		if not info.has(id):
			continue
		var centre: Vector3 = info[id]["pos"]
		var radius: float = float(info[id]["radius"]) + gap
		var c: Color = colors.get(sieges[id], Color.GRAY)
		for k in per:
			var a := TAU * k / per + float(absi(hash(id)) % 100) * 0.01
			var p := Vector2(centre.x, centre.z) + Vector2(cos(a), sin(a)) * radius * (0.9 + 0.2 * float(k % 2))
			var y := maxf(_ground.height_at(p), 0.0)
			xforms.append(Transform3D(Basis(Vector3.UP, a).scaled(Vector3.ONE * tent_scale), Vector3(p.x, y, p.y)))
			tints.append(Color(c.r, c.g, c.b, 1.0))
	var tm := _tents.multimesh
	tm.instance_count = xforms.size()
	for i in xforms.size():
		tm.set_instance_transform(i, xforms[i])
		tm.set_instance_custom_data(i, tints[i])
	for id in _smoke.keys():                      # smoke follows the camps
		if not sieges.has(id):
			_smoke[id].queue_free()
			_smoke.erase(id)
	if sc.get("smoke", true):
		for id in sieges:
			if info.has(id) and not _smoke.has(id):
				var fx := _smoke_fx()
				fx.position = info[id]["pos"] + Vector3(0.7, 0.0, 0.5) * (float(info[id]["radius"]) + gap)
				add_child(fx)
				_smoke[id] = fx


static func _tent_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	ScatterMeshes._cone(st, Vector3(0, -0.02, 0), 0.11, 0.16, 4, SettlementMeshes.TINT)
	ScatterMeshes._prism(st, Vector3(0, 0, 0), 0.005, 0.005, 0.2, 3, Color("#3a3028"))
	st.generate_normals()
	return st.commit()


static func _smoke_fx() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 18
	p.lifetime = 4.0
	p.preprocess = 4.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.12
	p.direction = Vector3(0.2, 1, 0)
	p.spread = 12.0
	p.gravity = Vector3(0.05, 0.12, 0)
	p.initial_velocity_min = 0.15
	p.initial_velocity_max = 0.3
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.4))
	grow.add_point(Vector2(1, 1.6))
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(0.35, 0.33, 0.32, 0.75))
	fade.set_color(1, Color(0.75, 0.74, 0.72, 0.0))
	p.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(0.45, 0.45)
	var puff := Gradient.new()                         # a soft round puff instead of a square
	puff.set_color(0, Color(1, 1, 1, 1))
	puff.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = puff
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	quad.material = m
	p.mesh = quad
	return p
