class_name Parties3D
extends Node3D
## Every party on the 3D map (Phase G6), synced from World each frame: one MultiMeshInstance3D per
## kind (PartyMeshes), lords and caravans in their realm's colour, the player in their realm's (red
## when free). Parties turn smoothly toward where they are heading and grow with camera distance so
## they stay readable when zoomed out ("parties" in res://data/config/map3d.json).

const SHADER := preload("res://scripts/map3d/settlement.gdshader")
const KINDS := ["lord", "bandit", "caravan", "player"]

var world                              # World (anything with `parties` and `time`; tests use a stub)
var ground: TerrainMesh
var colors: Dictionary = {}           # faction -> Color
var cfg: Dictionary = {}
var cell_size := 16.0
var shown: Array = []                 # [[Party, Vector3 anchor]] drawn this frame (hover, labels)
var _mm: Dictionary = {}              # kind -> MultiMesh
var _buf: Dictionary = {}             # kind -> PackedFloat32Array instance data (see _sync)
const FLOATS := 16
var _yaw: Dictionary = {}             # party id -> current facing
var _last: Dictionary = {}            # party id -> sim position last frame


func setup(w, g: TerrainMesh, cell: float, faction_colors: Dictionary, c: Dictionary) -> void:
	world = w
	ground = g
	cell_size = cell
	colors = faction_colors
	cfg = c
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	for kind in KINDS:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = PartyMeshes.build(kind)
		_mm[kind] = mm
		_buf[kind] = PackedFloat32Array()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Parties_" + kind
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-50, -20, -50), Vector3(400, 80, 300))   # instances span the map
		add_child(mmi)


## Scale factor for a camera this far from its pivot.
func scale_for(distance: float) -> float:
	return clampf(distance / float(cfg.get("scale_div", 36.0)), float(cfg.get("scale_min", 0.45)), float(cfg.get("scale_max", 3.0)))


## Rebuilds every instance from the world. k: model scale; delta: seconds, for turning.
func sync(k: float, delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_sync(k, delta)
	sync_usec_total += Time.get_ticks_usec() - t0
	sync_calls += 1


var sync_usec_total := 0              # profiling: time spent in sync, and how often it ran
var sync_calls := 0


## Writes each kind's instances straight into its MultiMesh buffer (16 floats each: a 3x4 transform,
## row-major, then the custom colour), one upload per kind: ~600 set_instance_* calls a frame cost
## more than the rest of the sync.
@warning_ignore("integer_division")
func _sync(k: float, delta: float) -> void:
	var by_kind := {}
	for kind in KINDS:
		by_kind[kind] = []
	for p in world.parties:
		if p.is_active(world.time) and by_kind.has(p.kind):
			by_kind[p.kind].append(p)
	shown.clear()
	var turn := 1.0 - exp(-float(cfg.get("turn_speed", 8.0)) * delta)
	for kind in KINDS:
		var list: Array = by_kind[kind]
		# One local handle per kind: packed arrays are copy-on-write, so writing through the
		# dictionary entry for each party would copy the whole buffer every time.
		var b: PackedFloat32Array = _buf[kind]
		if b.size() < list.size() * FLOATS:
			b.resize((list.size() + 64) * FLOATS)        # grown rarely, with headroom
		var s := k * (1.25 if kind == "player" else 1.0)
		for n in list.size():
			var p: Party = list[n]
			var xz: Vector2 = p.position / cell_size
			var last: Vector2 = _last.get(p.id, xz)
			var yaw: float = _yaw.get(p.id, 0.0)
			var step := xz - last
			if step.length_squared() > 1e-8:
				yaw = lerp_angle(yaw, atan2(-step.x, -step.y), turn)
			_yaw[p.id] = yaw
			_last[p.id] = xz
			var y := maxf(ground.height_at(xz), 0.0)
			var c := cos(yaw) * s
			var sn := sin(yaw) * s
			var tint := _tint(p)
			var o := n * FLOATS
			b[o] = c;       b[o + 1] = 0.0; b[o + 2] = sn;  b[o + 3] = xz.x     # Basis(UP, yaw) * s, origin
			b[o + 4] = 0.0; b[o + 5] = s;   b[o + 6] = 0.0; b[o + 7] = y
			b[o + 8] = -sn; b[o + 9] = 0.0; b[o + 10] = c;  b[o + 11] = xz.y
			b[o + 12] = tint.r; b[o + 13] = tint.g; b[o + 14] = tint.b; b[o + 15] = 1.0
			if kind != "player":
				shown.append([p, Vector3(xz.x, y + 0.3 * s, xz.y)])
		_buf[kind] = b
		var mm: MultiMesh = _mm[kind]
		var cap := b.size() / FLOATS
		if mm.instance_count != cap:
			mm.instance_count = cap
		mm.buffer = b
		mm.visible_instance_count = list.size()
	if _yaw.size() > world.parties.size() * 2:            # forget long-gone parties now and then
		var alive := {}
		for p in world.parties:
			alive[p.id] = true
		for id in _yaw.keys():
			if not alive.has(id):
				_yaw.erase(id)
				_last.erase(id)


func count(kind: String) -> int:
	return (_mm[kind] as MultiMesh).visible_instance_count


func _tint(p: Party) -> Color:
	if p.kind == "player":
		return colors.get(p.faction, Color(cfg.get("player_color", "#b8322a"))) if p.faction != "" else Color(cfg.get("player_color", "#b8322a"))
	return colors.get(p.faction, Color.WHITE)
