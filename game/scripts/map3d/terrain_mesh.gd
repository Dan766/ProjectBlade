class_name TerrainMesh
extends RefCounted
## The continent as a 3D surface (Phase G): an ArrayMesh built from TerrainMap heights, with the
## tunables in res://data/config/map3d.json. 1 cell = 1 world unit, sea level is y = 0, and cell
## (x, y) is centred at (x + 0.5, h, y + 0.5).
## Two vertices per cell per axis: one at each cell centre (that cell's height) and one on every
## cell edge and corner (the average of the cells touching it), so the surface is smooth but each
## cell still owns its centre. Per-vertex terrain weights for the splat shader (they sum to 1):
##   COLOR   = water, plains, forest, hills
##   CUSTOM0 = mountains, marsh, desert, ash   (RGBA8 unorm)
## UV = position on the map, 0..1.

const SPLAT_ORDER := "~.fhmsda"
const WATER := 126                       # "~"

var map_size: Vector2i                   # cells
var grid_size: Vector2i                  # vertices: map_size * 2 + 1
var cell_heights: PackedFloat32Array     # world y per cell, after smoothing (row-major)
var vertex_heights: PackedFloat32Array   # world y per vertex (row-major, 0.5 units apart)
var max_height := 0.0
var max_slope := 0.0                     # steepest rise per unit along x or z (bounds raycast steps)
var mesh: ArrayMesh


static func build(t: TerrainMap, cfg: Dictionary) -> TerrainMesh:
	var m := TerrainMesh.new()
	m._build_heights(t, cfg)
	m._build_mesh(t)
	return m


## World y of the rendered surface at world position (x, z), exact on the triangles.
func height_at(p: Vector2) -> float:
	var u := clampf(p.x * 2.0, 0.0, grid_size.x - 1.001)
	var v := clampf(p.y * 2.0, 0.0, grid_size.y - 1.001)
	var i := int(u)
	var j := int(v)
	var fu := u - i
	var fv := v - j
	var a := vertex_heights[j * grid_size.x + i]
	var b := vertex_heights[j * grid_size.x + i + 1]
	var c := vertex_heights[(j + 1) * grid_size.x + i]
	var d := vertex_heights[(j + 1) * grid_size.x + i + 1]
	if fu + fv <= 1.0:                   # triangle a-b-c, else b-d-c (see _build_mesh)
		return a + (b - a) * fu + (c - a) * fv
	return d + (c - d) * (1.0 - fu) + (b - d) * (1.0 - fv)


## Where a ray (e.g. the mouse ray from the camera) first meets the ground or the sea surface
## (y = 0), or null if it never does. Marches the exact rendered surface, then bisects, so picks
## on slopes land where the player sees the terrain (Phase G3). Each step is the height gap divided
## by the steepest slope on the map, so the ray can't jump over a thin crest (a fixed step did).
func raycast(origin: Vector3, dir: Vector3, max_dist: float = 3000.0, min_step: float = 0.005) -> Variant:
	dir = dir.normalized()
	if origin.y - _surface(origin) <= 0.0:
		return null
	var t := 0.0
	if origin.y > max_height:                # nothing to hit above the highest peak
		if dir.y >= 0.0:
			return null
		t = (origin.y - max_height) / -dir.y
	var closing := maxf(-dir.y, 0.0) + max_slope * Vector2(dir.x, dir.z).length()
	var prev := t
	while t <= max_dist:
		var p := origin + dir * t
		var gap := p.y - _surface(p)
		if gap <= 0.0:
			var lo := prev
			var hi := t
			for _i in 20:
				var mid := (lo + hi) * 0.5
				var q := origin + dir * mid
				if q.y - _surface(q) > 0.0:
					lo = mid
				else:
					hi = mid
			return origin + dir * hi
		if dir.y >= 0.0 and p.y > max_height:
			return null                      # climbing away above every peak
		prev = t
		t += maxf(gap / maxf(closing, 0.001), min_step)
	return null


func _surface(p: Vector3) -> float:
	return maxf(height_at(Vector2(p.x, p.z)), 0.0)


func cell_height(cell: Vector2i) -> float:
	return vertex_heights[(cell.y * 2 + 1) * grid_size.x + cell.x * 2 + 1]


func cell_to_3d(cell: Vector2i) -> Vector3:
	return Vector3(cell.x + 0.5, cell_height(cell), cell.y + 0.5)


func _build_heights(t: TerrainMap, cfg: Dictionary) -> void:
	map_size = Vector2i(t.width, t.height)
	grid_size = map_size * 2 + Vector2i.ONE
	var scale := float(cfg.get("height_scale", 0.06))
	var margin := float(cfg.get("shore_margin", 0.1))
	var n := t.width * t.height
	cell_heights = PackedFloat32Array()
	cell_heights.resize(n)
	if t.has_heights():
		for i in n:
			cell_heights[i] = float(t.heights[i] - t.sea_level) * scale
	for _pass in int(cfg.get("smooth_passes", 0)):
		cell_heights = _blur(cell_heights, t.width, t.height)
	for i in n:                          # smoothing never moves the coast: land above the sea, water below
		if t.codes[i] == WATER:
			cell_heights[i] = minf(cell_heights[i], -margin)
		else:
			cell_heights[i] = maxf(cell_heights[i], margin)

	# Each vertex averages the (up to 4) cells around it; a centre vertex samples its cell 4 times.
	var gx := _covering_cells(grid_size.x, t.width)
	var gy := _covering_cells(grid_size.y, t.height)
	vertex_heights = PackedFloat32Array()
	vertex_heights.resize(grid_size.x * grid_size.y)
	for j in grid_size.y:
		var r0 := gy[j * 2] * t.width
		var r1 := gy[j * 2 + 1] * t.width
		for i in grid_size.x:
			var x0 := gx[i * 2]
			var x1 := gx[i * 2 + 1]
			vertex_heights[j * grid_size.x + i] = 0.25 * (cell_heights[r0 + x0] + cell_heights[r0 + x1] + cell_heights[r1 + x0] + cell_heights[r1 + x1])
	max_height = 0.0
	max_slope = 0.0
	for j in grid_size.y:
		for i in grid_size.x:
			var h := vertex_heights[j * grid_size.x + i]
			max_height = maxf(max_height, h)
			if i > 0:
				max_slope = maxf(max_slope, absf(h - vertex_heights[j * grid_size.x + i - 1]) * 2.0)
			if j > 0:
				max_slope = maxf(max_slope, absf(h - vertex_heights[(j - 1) * grid_size.x + i]) * 2.0)
	max_slope *= 2.0                         # a triangle's diagonal gradient can exceed either axis; stay safe


func _build_mesh(t: TerrainMap) -> void:
	var splat := PackedInt32Array()
	splat.resize(256)
	splat.fill(1)                        # unknown codes paint as plains
	for k in SPLAT_ORDER.length():
		splat[SPLAT_ORDER.unicode_at(k)] = k
	var gx := _covering_cells(grid_size.x, t.width)
	var gy := _covering_cells(grid_size.y, t.height)
	var nv := grid_size.x * grid_size.y
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var custom := PackedByteArray()
	var uvs := PackedVector2Array()
	verts.resize(nv)
	normals.resize(nv)
	colors.resize(nv)
	custom.resize(nv * 4)
	uvs.resize(nv)
	var w := PackedFloat32Array()
	w.resize(8)
	var last_x := grid_size.x - 1
	var last_y := grid_size.y - 1
	for j in grid_size.y:
		var r0 := gy[j * 2] * t.width
		var r1 := gy[j * 2 + 1] * t.width
		var jn := maxi(j - 1, 0)
		var js := mini(j + 1, last_y)
		for i in grid_size.x:
			var idx := j * grid_size.x + i
			var x0 := gx[i * 2]
			var x1 := gx[i * 2 + 1]
			verts[idx] = Vector3(i * 0.5, vertex_heights[idx], j * 0.5)
			uvs[idx] = Vector2(float(i) / last_x, float(j) / last_y)
			var iw := maxi(i - 1, 0)
			var ie := mini(i + 1, last_x)
			var dhdx := (vertex_heights[j * grid_size.x + ie] - vertex_heights[j * grid_size.x + iw]) / ((ie - iw) * 0.5)
			var dhdz := (vertex_heights[js * grid_size.x + i] - vertex_heights[jn * grid_size.x + i]) / ((js - jn) * 0.5)
			normals[idx] = Vector3(-dhdx, 1.0, -dhdz).normalized()
			w.fill(0.0)
			w[splat[t.codes[r0 + x0]]] += 0.25
			w[splat[t.codes[r0 + x1]]] += 0.25
			w[splat[t.codes[r1 + x0]]] += 0.25
			w[splat[t.codes[r1 + x1]]] += 0.25
			colors[idx] = Color(w[0], w[1], w[2], w[3])
			custom[idx * 4] = int(w[4] * 255.0 + 0.5)
			custom[idx * 4 + 1] = int(w[5] * 255.0 + 0.5)
			custom[idx * 4 + 2] = int(w[6] * 255.0 + 0.5)
			custom[idx * 4 + 3] = int(w[7] * 255.0 + 0.5)

	# Two clockwise (front-facing in Godot) triangles per quad, seen from above:
	# a-b-c and b-d-c, with a = (i, j), b = (i + 1, j), c = (i, j + 1), d = (i + 1, j + 1).
	var indices := PackedInt32Array()
	indices.resize(last_x * last_y * 6)
	var k := 0
	for j in last_y:
		for i in last_x:
			var a := j * grid_size.x + i
			var c := a + grid_size.x
			indices[k] = a
			indices[k + 1] = a + 1
			indices[k + 2] = c
			indices[k + 3] = a + 1
			indices[k + 4] = c + 1
			indices[k + 5] = c
			k += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)


## For each vertex index along one axis, the two cells it averages (the same cell twice at a centre
## or on the map edge), flattened: [c0, c1, c0, c1, ...].
@warning_ignore("integer_division")
static func _covering_cells(vertex_count: int, cell_count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(vertex_count * 2)
	for i in vertex_count:
		if i % 2 == 1:
			out[i * 2] = (i - 1) / 2
			out[i * 2 + 1] = (i - 1) / 2
		else:
			out[i * 2] = clampi(i / 2 - 1, 0, cell_count - 1)
			out[i * 2 + 1] = clampi(i / 2, 0, cell_count - 1)
	return out


static func _blur(h: PackedFloat32Array, w: int, hgt: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(h.size())
	for y in hgt:
		for x in w:
			var sum := 0.0
			var count := 0
			for yy in range(maxi(y - 1, 0), mini(y + 2, hgt)):
				for xx in range(maxi(x - 1, 0), mini(x + 2, w)):
					sum += h[yy * w + xx]
					count += 1
			out[y * w + x] = sum / count
	return out
