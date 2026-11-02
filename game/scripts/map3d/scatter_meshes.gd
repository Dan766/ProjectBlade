class_name ScatterMeshes
extends RefCounted
## Low-poly scatter models built in code (Phase G4), so no asset pack is needed: flat-shaded,
## vertex-coloured, about 0.6 units tall for a tree (a cell is 1 unit). Colours here are the base;
## Scatter tints each instance. All faces are wound for Godot (clockwise = front) automatically.

const BARK := Color("#5b4331")
const PINE := Color("#2f5a35")
const LEAF := Color("#4d7a38")
const BUSH := Color("#5f7f3c")
const STONE := Color("#8b857d")
const REED := Color("#a3a65a")
const SAND := Color("#d8bf88")
const DRY := Color("#8c7b4a")
const CHAR := Color("#2b2522")
const ASH_STONE := Color("#3d3634")


static func build(kind: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)                      # flat shading: one normal per face
	match kind:
		"conifer":
			_prism(st, Vector3.ZERO, 0.035, 0.035, 0.14, 5, BARK)
			_cone(st, Vector3(0, 0.1, 0), 0.21, 0.3, 6, PINE)
			_cone(st, Vector3(0, 0.25, 0), 0.16, 0.26, 6, PINE.lightened(0.06))
			_cone(st, Vector3(0, 0.4, 0), 0.1, 0.22, 6, PINE.lightened(0.12))
		"broadleaf":
			_prism(st, Vector3.ZERO, 0.04, 0.03, 0.24, 5, BARK)
			_blob(st, Vector3(0, 0.34, 0), Vector3(0.22, 0.18, 0.22), LEAF, 1)
		"bush":
			_blob(st, Vector3(0, 0.05, 0), Vector3(0.1, 0.08, 0.1), BUSH, 2)
		"shrub":
			_blob(st, Vector3(0, 0.04, 0), Vector3(0.08, 0.05, 0.08), DRY, 3)
		"rock":
			_blob(st, Vector3(0, 0.03, 0), Vector3(0.13, 0.08, 0.11), STONE, 4)
		"ashrock":
			_blob(st, Vector3(0, 0.03, 0), Vector3(0.12, 0.09, 0.1), ASH_STONE, 5)
		"dune":
			_blob(st, Vector3(0, -0.02, 0), Vector3(0.45, 0.09, 0.2), SAND, 6)
		"stump":
			_prism(st, Vector3.ZERO, 0.055, 0.045, 0.09, 6, CHAR)
		"deadtree":
			_prism(st, Vector3.ZERO, 0.03, 0.015, 0.42, 5, CHAR)
			_prism_tilted(st, Vector3(0, 0.22, 0), Vector3(0.12, 0.12, 0.02), 0.012, CHAR)
			_prism_tilted(st, Vector3(0, 0.3, 0), Vector3(-0.09, 0.1, -0.04), 0.01, CHAR)
		"reeds":
			for i in 7:
				var a := TAU * i / 7.0 + 0.4 * sin(i * 2.3)
				var lean := Vector3(cos(a), 0, sin(a)) * (0.03 + 0.02 * (i % 3))
				var base := Vector3(cos(a), 0, sin(a)) * 0.03
				_blade(st, base, lean + Vector3(0, 0.18 + 0.03 * (i % 4), 0), 0.012, REED.lightened(0.05 * (i % 3)))
		_:
			push_error("ScatterMeshes: unknown kind " + kind)
	st.generate_normals()
	return st.commit()


## Adds a triangle facing away from `center` (clockwise seen from outside, Godot's front face).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, center: Vector3, col: Color) -> void:
	var outward := (a + b + c) / 3.0 - center
	if (b - a).cross(c - a).dot(outward) > 0.0:   # counter-clockwise from outside: flip
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_color(col)
		st.add_vertex(v)


static func _ring(center: Vector3, r: float, sides: int, phase: float = 0.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in sides:
		var a := TAU * i / sides + phase
		out.append(center + Vector3(cos(a) * r, 0, sin(a) * r))
	return out


static func _cone(st: SurfaceTool, base: Vector3, r: float, h: float, sides: int, col: Color) -> void:
	var ring := _ring(base, r, sides, 0.3)
	var tip := base + Vector3(0, h, 0)
	var mid := base + Vector3(0, h * 0.35, 0)
	for i in sides:
		var a := ring[i]
		var b := ring[(i + 1) % sides]
		_tri(st, a, b, tip, mid, col.darkened(0.08 * (i % 2)))
		_tri(st, a, b, base, base + Vector3(0, 1, 0), col.darkened(0.25))   # underside faces down


static func _prism(st: SurfaceTool, base: Vector3, r0: float, r1: float, h: float, sides: int, col: Color) -> void:
	var lo := _ring(base, r0, sides)
	var hi := _ring(base + Vector3(0, h, 0), r1, sides)
	var mid := base + Vector3(0, h * 0.5, 0)
	for i in sides:
		var j := (i + 1) % sides
		_tri(st, lo[i], lo[j], hi[i], mid, col)
		_tri(st, lo[j], hi[j], hi[i], mid, col)
		_tri(st, hi[i], hi[j], base + Vector3(0, h, 0), base, col.lightened(0.1))  # top cap


## A thin square beam from `from` along `dir` (branches).
static func _prism_tilted(st: SurfaceTool, from: Vector3, dir: Vector3, r: float, col: Color) -> void:
	var side := dir.cross(Vector3.UP).normalized() * r
	var up := side.cross(dir).normalized() * r
	var a := [from + side + up, from - side + up, from - side - up, from + side - up]
	var b := []
	for p in a:
		b.append(p + dir)
	var mid := from + dir * 0.5
	for i in 4:
		var j := (i + 1) % 4
		_tri(st, a[i], a[j], b[i], mid, col)
		_tri(st, a[j], b[j], b[i], mid, col)


static func _blade(st: SurfaceTool, base: Vector3, tip: Vector3, w: float, col: Color) -> void:
	var side := (tip - base).cross(Vector3.UP).normalized() * w
	# Single-sided triangle; the reeds material draws both sides.
	for v in [base - side, base + side, tip]:
		st.set_color(col)
		st.add_vertex(v)


## A jittered icosahedron: rocks, canopies, bushes. `variant` varies the jitter per kind.
static func _blob(st: SurfaceTool, center: Vector3, radii: Vector3, col: Color, variant: int) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var faces := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4],
		[11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var pts := []
	for i in v.size():
		var n: Vector3 = (v[i] as Vector3).normalized()
		var jitter := 0.82 + 0.36 * fposmod(sin(float(i * 12 + variant * 7) * 12.9898) * 43758.5453, 1.0)
		pts.append(center + n * radii * jitter)
	for f in faces:
		var shade: float = 0.06 * ((int(f[0]) + int(f[1])) % 3)
		_tri(st, pts[f[0]], pts[f[1]], pts[f[2]], center, col.darkened(shade))
