class_name MapTextures
extends RefCounted
## Data textures the 3D map shaders read (Phase G2). All cover the whole map; UV = world xz / map size.
##   regions: R8, one texel per cell, value = region index (0 = sea, 1..N = faction)
##   region masks: 2 x RGBA8, one texel per cell, one channel per region (see region_masks)
##   roads:   R8, ROAD_RES texels per cell, 1.0 on roads, TRACK_VALUE on tracks
##   heights: RF, one texel per cell, world y of the cell (TerrainMesh.cell_heights), for water depth

const ROAD_RES := 4
const TRACK_VALUE := 0.6


static func region_image(t: TerrainMap) -> Image:
	return Image.create_from_data(t.width, t.height, false, Image.FORMAT_R8, t.regions)


## Soft region masks for borders: two RGBA8 images, one channel per region, 255 inside it.
## [0] = regions 1..4 (r, g, b, a), [1] = regions 5..8. Sampled with linear filtering, the line
## where two masks are equal is a smooth border instead of a staircase of cells.
@warning_ignore("integer_division")
static func region_masks(t: TerrainMap) -> Array[Image]:
	var data: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	for d in data:
		d.resize(t.width * t.height * 4)
	for i in t.regions.size():
		var r := int(t.regions[i])
		if r >= 1 and r <= 8:
			data[(r - 1) / 4][i * 4 + (r - 1) % 4] = 255
	var out: Array[Image] = []
	for d in data:
		out.append(Image.create_from_data(t.width, t.height, false, Image.FORMAT_RGBA8, d))
	return out


static func height_image(m: TerrainMesh) -> Image:
	return Image.create_from_data(m.map_size.x, m.map_size.y, false, Image.FORMAT_RF, m.cell_heights.to_byte_array())


static func road_image(t: TerrainMap) -> Image:
	var img := Image.create_empty(t.width * ROAD_RES, t.height * ROAD_RES, false, Image.FORMAT_R8)
	var size := Vector2i(img.get_width(), img.get_height())
	for r in t.roads:
		var value := 1.0 if r["kind"] == "road" else TRACK_VALUE
		var cells: Array[Vector2i] = r["cells"]
		for k in range(cells.size() - 1):
			var a := (Vector2(cells[k]) + Vector2(0.5, 0.5)) * ROAD_RES
			var b := (Vector2(cells[k + 1]) + Vector2(0.5, 0.5)) * ROAD_RES
			for s in ROAD_RES * 2 + 1:
				_stamp(img, size, Vector2i(a.lerp(b, float(s) / (ROAD_RES * 2))), value)
	return img


## A soft 3x3 dot (centre full, ring half), so linear filtering gives an even line, not beads.
static func _stamp(img: Image, size: Vector2i, c: Vector2i, value: float) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var p := c + Vector2i(dx, dy)
			var v := value if dx == 0 and dy == 0 else value * 0.5
			if p.x >= 0 and p.y >= 0 and p.x < size.x and p.y < size.y and img.get_pixelv(p).r < v:
				img.set_pixelv(p, Color(v, 0, 0))


## Faction colours in linear space, indexed by region (index 0 = sea), padded to `count`.
static func region_colors(t: TerrainMap, faction_colors: Dictionary, count: int = 8) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(count)
	for idx in t.region_factions:
		var c: Color = faction_colors.get(t.region_factions[idx], Color.GRAY)
		c = c.srgb_to_linear()
		if int(idx) < count:
			out[int(idx)] = Vector3(c.r, c.g, c.b)
	return out
