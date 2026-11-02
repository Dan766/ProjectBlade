class_name SettlementMeshes
extends RefCounted
## Low-poly town, castle and village models built in code (Phase G5), one look per culture:
##   canal    stone houses, red gables, spired towers, a canal through town   (Orlagua)
##   fen      round reed huts with thatched cones, timber palisades           (Saaravenn)
##   ash      black-stone blocks with flat roofs, crenellated keeps           (Tsevaret)
##   forest   long timber halls with steep moss roofs, palisades              (Tesnovar)
##   regency  white walls, slate gables, round towers with cone roofs         (Lauresse)
##   oasis    sand-brick blocks, flat roofs and domes                         (Ighrast)
## Vertex colour alpha 0 (TINT) marks flags and keep roofs; the shader paints those in the current
## owner's colour. Unit: 1 cell = 1; models are centred on the origin, ground at y = 0. Walls reach
## SINK below ground so buildings never float on slopes.

const TINT := Color(1, 1, 1, 0)
const SINK := 0.25

var st: SurfaceTool
var style := "regency"
var wall: Color
var roof: Color
var trim: Color
var accent: Color
var dirt: Color
var fields: Array = []
var rng := RandomNumberGenerator.new()


## pal: {style, wall, roof, trim, accent} (sRGB hex); fields: hex colours of farmland.
static func build(kind: String, variant: int, pal: Dictionary, field_colors: Array, dirt_hex: String) -> ArrayMesh:
	var b := SettlementMeshes.new()
	b.style = pal.get("style", "regency")
	b.wall = Color(pal.get("wall", "#cccccc"))
	b.roof = Color(pal.get("roof", "#884444"))
	b.trim = Color(pal.get("trim", "#888888"))
	b.accent = Color(pal.get("accent", "#4477aa"))
	b.dirt = Color(dirt_hex)
	for f in field_colors:
		b.fields.append(Color(f))
	b.rng.seed = hash("%s/%s/%d" % [b.style, kind, variant])
	b.st = SurfaceTool.new()
	b.st.begin(Mesh.PRIMITIVE_TRIANGLES)
	b.st.set_smooth_group(-1)
	match kind:
		"village":
			b._village()
		"castle":
			b._castle()
		_:
			b._town()
	b.st.generate_normals()
	return b.st.commit()


# --- layouts -------------------------------------------------------------------------------

func _village() -> void:
	var n := 3 + rng.randi() % 3
	for i in n:
		var a := TAU * i / n + rng.randf_range(-0.3, 0.3)
		var at := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.17, 0.28)
		_house(at, -a + PI * 0.5, 0.9)
	var field_count := 1 if style in ["fen", "ash"] else 3
	for i in field_count:
		var a := rng.randf() * TAU
		var at := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.45, 0.55)
		var col: Color = fields[rng.randi() % fields.size()] if style != "ash" else dirt.darkened(0.3)
		_box(at, Vector3(0.26, 0.012, 0.18), -a, col, 0.12)
	_flag(Vector3(0.02, 0, -0.04), 0.22, 0.7)


func _castle() -> void:
	_pad(0.48)
	var s := 0.34
	var corners := [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(s, 0, s), Vector3(-s, 0, s)]
	_wall_ring(corners, 0.15, 0.05, -1)
	for c in corners:
		_tower(c, 0.065, 0.3)
	_keep(Vector3.ZERO, 0.26, 0.36)


func _town() -> void:
	var r := 0.82
	_pad(r * 0.98)
	var ring := []
	for i in 10:
		var a := TAU * i / 10.0 + 0.2
		ring.append(Vector3(cos(a), 0, sin(a)) * r)
	_wall_ring(ring, 0.13, 0.045, 0)              # a gate gap in the first segment
	for i in range(1, ring.size(), 2):
		_tower(ring[i], 0.06, 0.26)
	if style == "canal":
		_box(Vector3(0, 0, 0.32), Vector3(1.7, 0.012, 0.1), 0.15, accent, 0.05)
	var placed: Array = [Vector3.ZERO]
	var tries := 0
	while placed.size() < 13 and tries < 400:
		tries += 1
		var a := rng.randf() * TAU
		var at := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.27, 0.62)
		if style == "canal" and absf(at.z - 0.32 - 0.15 * (at.x)) < 0.12:
			continue                               # keep the canal clear
		var ok := true
		for p in placed:
			if at.distance_to(p) < (0.32 if p == Vector3.ZERO else 0.15):
				ok = false
				break
		if ok:
			placed.append(at)
			_house(at, rng.randf() * TAU, 1.0)
	_keep(Vector3.ZERO, 0.3, 0.42)
	_flag(Vector3(0.0, 0, 0.0) + Vector3(-0.2, 0, -0.18), 0.5, 1.0)


# --- buildings -------------------------------------------------------------------------------

func _house(at: Vector3, yaw: float, size: float) -> void:
	var w := rng.randf_range(0.11, 0.16) * size
	var d := rng.randf_range(0.09, 0.12) * size
	var h := rng.randf_range(0.08, 0.12) * size
	match style:
		"fen":
			ScatterMeshes._prism(st, at - Vector3(0, SINK, 0), w * 0.55, w * 0.55, h * 0.8 + SINK, 6, wall)
			ScatterMeshes._cone(st, at + Vector3(0, h * 0.8, 0), w * 0.75, h * 1.1, 6, roof)
		"forest":
			_box(at, Vector3(w * 1.6, h * 0.8, d), yaw, wall)
			_gable(at + Vector3(0, h * 0.8, 0), w * 1.6, d, h * 1.2, yaw, roof)
		"ash":
			_box(at, Vector3(w, h, d), yaw, wall)
			_box(at + Vector3(0, h, 0), Vector3(w * 1.08, 0.02, d * 1.08), yaw, trim, 0.0)
			_box(at + _rot(Vector3(0, h * 0.35, d * 0.5), yaw), Vector3(w * 0.3, h * 0.25, 0.012), yaw, accent, 0.0)
		"oasis":
			_box(at, Vector3(w, h * (1.0 + rng.randf() * 0.5), d), yaw, wall)
			if rng.randf() < 0.35:
				ScatterMeshes._blob(st, at + Vector3(0, h, 0), Vector3(w, w, w) * 0.42, roof, 9)
		_:
			var floors := 1.0 + float(rng.randf() < 0.3) * 0.6
			_box(at, Vector3(w, h * floors, d), yaw, wall)
			_gable(at + Vector3(0, h * floors, 0), w, d, h * 0.7, yaw, roof)


func _tower(at: Vector3, r: float, h: float) -> void:
	match style:
		"regency", "canal":
			ScatterMeshes._prism(st, at - Vector3(0, SINK, 0), r, r * 0.92, h + SINK, 8, wall.darkened(0.04))
			var spire := 0.5 if style == "canal" else 0.32
			ScatterMeshes._cone(st, at + Vector3(0, h, 0), r * 1.25, h * spire + 0.05, 8, roof)
		"fen", "forest":
			_box(at, Vector3(r * 1.6, h * 1.1, r * 1.6), 0.0, trim)
			ScatterMeshes._cone(st, at + Vector3(0, h * 1.1, 0), r * 1.4, r * 1.6, 4, roof)
		"oasis":
			_box(at, Vector3(r * 1.7, h, r * 1.7), 0.0, wall.darkened(0.05))
			ScatterMeshes._blob(st, at + Vector3(0, h, 0), Vector3(r, r * 0.9, r), roof, 3)
		_:
			_box(at, Vector3(r * 1.8, h, r * 1.8), 0.0, wall)
			_crenels(at + Vector3(0, h, 0), r * 0.9, trim)


## The lord's keep or hall: its roof (or dome) and its flag take the owner's colour.
func _keep(at: Vector3, w: float, h: float) -> void:
	match style:
		"oasis":
			_box(at, Vector3(w, h, w), 0.0, wall)
			ScatterMeshes._blob(st, at + Vector3(0, h, 0), Vector3(w, w * 0.8, w) * 0.55, TINT, 7)
		"ash":
			_box(at, Vector3(w, h * 1.1, w), 0.0, wall)
			_box(at + Vector3(0, h * 1.1, 0), Vector3(w * 1.06, 0.03, w * 1.06), 0.0, TINT, 0.0)
			_crenels(at + Vector3(0, h * 1.1 + 0.03, 0), w * 0.5, trim)
		"fen", "forest":
			_box(at, Vector3(w * 1.5, h * 0.6, w * 0.8), 0.0, wall)
			_gable(at + Vector3(0, h * 0.6, 0), w * 1.5, w * 0.8, h * 0.75, 0.0, TINT)
		_:
			_box(at, Vector3(w, h, w * 0.85), 0.0, wall.darkened(0.03))
			_gable(at + Vector3(0, h, 0), w, w * 0.85, h * 0.45, 0.0, TINT)
	_flag(at + Vector3(w * 0.3, h + 0.08, 0.0), 0.26, 1.0)


func _flag(at: Vector3, h: float, size: float) -> void:
	ScatterMeshes._prism(st, at, 0.008, 0.006, h, 4, Color("#2a2420"))
	var cloth := Vector3(0.14, 0.08, 0.008) * size
	_box(at + Vector3(cloth.x * 0.5, h - cloth.y, 0), cloth, 0.0, TINT, 0.0)


func _wall_ring(points: Array, h: float, thick: float, gate: int) -> void:
	var col := trim if style in ["fen", "forest"] else wall.darkened(0.08)
	for i in points.size():
		if i == gate:
			continue
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % points.size()]
		var dvec := b - a
		_box((a + b) * 0.5, Vector3(dvec.length(), h, thick), atan2(-dvec.z, dvec.x), col)
		if style in ["fen", "forest"]:            # pointed palisade stakes along the top
			var n := int(dvec.length() / 0.05)
			for k in n:
				var p := a + dvec * (k + 0.5) / n + Vector3(0, h, 0)
				ScatterMeshes._cone(st, p, thick * 0.5, 0.04, 4, col)


func _crenels(at: Vector3, r: float, col: Color) -> void:
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		_box(at + Vector3(cos(a), 0, sin(a)) * r, Vector3(0.03, 0.03, 0.03), a, col, 0.0)


## A packed-earth platform under forts and towns, sunk so it also covers sloping ground.
func _pad(r: float) -> void:
	ScatterMeshes._prism(st, Vector3(0, -SINK, 0), r, r, SINK + 0.015, 12, dirt)


# --- geometry ----------------------------------------------------------------------------------

static func _rot(v: Vector3, yaw: float) -> Vector3:
	return Vector3(v.x * cos(yaw) + v.z * sin(yaw), v.y, -v.x * sin(yaw) + v.z * cos(yaw))


## A box standing on `at` (bottom centre), rotated by yaw, reaching `sink` below ground.
func _box(at: Vector3, size: Vector3, yaw: float, col: Color, sink: float = SINK) -> void:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var lo := -sink
	var hi := size.y
	var c := []
	for y in [lo, hi]:
		for p in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]:
			c.append(at + _rot(Vector3(p.x, y, p.y), yaw))
	var centre := at + Vector3(0, (lo + hi) * 0.5, 0)
	_quad(c[0], c[1], c[2], c[3], centre, col.darkened(0.3))   # bottom
	_quad(c[4], c[5], c[6], c[7], centre, col.lightened(0.04))  # top
	for i in 4:
		var j := (i + 1) % 4
		_quad(c[i], c[j], c[j + 4], c[i + 4], centre, col.darkened(0.07 * (i % 2)))


## A pitched roof sitting on `at` (centre of the wall top): ridge along local x.
func _gable(at: Vector3, w: float, d: float, h: float, yaw: float, col: Color) -> void:
	var o := 0.015
	var e := [Vector3(-w * 0.5 - o, 0, -d * 0.5 - o), Vector3(w * 0.5 + o, 0, -d * 0.5 - o),
		Vector3(w * 0.5 + o, 0, d * 0.5 + o), Vector3(-w * 0.5 - o, 0, d * 0.5 + o)]
	var r := [Vector3(-w * 0.5 - o, h, 0), Vector3(w * 0.5 + o, h, 0)]
	var p := []
	for v in e + r:
		p.append(at + _rot(v, yaw))
	var centre := at + Vector3(0, h * 0.3, 0)
	_quad(p[0], p[1], p[5], p[4], centre, col)
	_quad(p[3], p[2], p[5], p[4], centre, col.darkened(0.1))
	ScatterMeshes._tri(st, p[0], p[4], p[3], centre, wall.darkened(0.05) if col.a > 0.5 else col)
	ScatterMeshes._tri(st, p[1], p[5], p[2], centre, wall.darkened(0.05) if col.a > 0.5 else col)
	_quad(p[0], p[1], p[2], p[3], centre + Vector3(0, 1, 0), col.darkened(0.3))


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, centre: Vector3, col: Color) -> void:
	ScatterMeshes._tri(st, a, b, c, centre, col)
	ScatterMeshes._tri(st, a, c, d, centre, col)
