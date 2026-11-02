class_name TerrainMap
extends RefCounted
## The continent as a grid of terrain cells (from res://data/world/terrain.json, made by
## tools/gen_map.py): movement costs, faction regions, heights, roads and pathfinding.

var width: int
var height: int
var cell_size: int
var codes: PackedByteArray          # one terrain code (ASCII) per cell, row-major
var regions: PackedByteArray        # 0 = sea, 1..N = faction index
var region_factions: Dictionary = {}    # region index -> faction id
var costs: Dictionary = {}              # terrain code (int) -> movement cost (0 = impassable)
var names: Dictionary = {}              # terrain code (int) -> "plains", ...
var heights: PackedByteArray        # elevation 0..255 per cell, row-major (empty on maps without it)
var sea_level: int = 0              # land cells are above it, water below
var roads: Array = []               # {a, b, kind: "road"|"track", cells: Array[Vector2i]}
var astar: AStarGrid2D


static func from_file(path: String) -> TerrainMap:
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		return null
	var t := TerrainMap.new()
	t.load_dict(data)
	return t


func load_dict(d: Dictionary) -> void:
	width = int(d["width"])
	height = int(d["height"])
	cell_size = int(d["cell_size"])
	for code in d["legend"]:
		costs[code.unicode_at(0)] = float(d["legend"][code]["cost"])
		names[code.unicode_at(0)] = d["legend"][code]["name"]
	for key in d["region_legend"]:
		region_factions[int(key)] = d["region_legend"][key]
	codes = PackedByteArray()
	regions = PackedByteArray()
	codes.resize(width * height)
	regions.resize(width * height)
	for y in height:
		var row: String = d["rows"][y]
		var reg: String = d["regions"][y]
		for x in width:
			codes[y * width + x] = row.unicode_at(x)
			regions[y * width + x] = reg.unicode_at(x) - 48   # "0".."9"
	heights = PackedByteArray()
	if d.has("heights"):
		sea_level = int(d["sea_level"])
		for row in d["heights"]:
			heights.append_array((row as String).hex_decode())
	roads.clear()
	for r in d.get("roads", []):
		var cells: Array[Vector2i] = []
		var flat: Array = r["path"]
		for i in range(0, flat.size(), 2):
			cells.append(Vector2i(int(flat[i]), int(flat[i + 1])))
		roads.append({"a": r["a"], "b": r["b"], "kind": r["kind"], "cells": cells})
	_build_astar()


func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, width, height)
	astar.cell_size = Vector2(cell_size, cell_size)
	astar.offset = Vector2(cell_size, cell_size) * 0.5    # paths in world space run through cell centers
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for y in height:
		for x in width:
			var c := Vector2i(x, y)
			var cost := cost_at(c)
			if cost <= 0.0:
				astar.set_point_solid(c, true)
			else:
				astar.set_point_weight_scale(c, cost)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height


func code_at(cell: Vector2i) -> int:
	return codes[cell.y * width + cell.x]


func cost_at(cell: Vector2i) -> float:
	return costs.get(code_at(cell), 0.0) if in_bounds(cell) else 0.0


func is_passable(cell: Vector2i) -> bool:
	return cost_at(cell) > 0.0


func terrain_name(cell: Vector2i) -> String:
	return names.get(code_at(cell), "?") if in_bounds(cell) else "beyond the map"


func has_heights() -> bool:
	return heights.size() == width * height


## Raw elevation 0..255 (sea_level on maps without heights).
func height_at(cell: Vector2i) -> int:
	if not has_heights():
		return sea_level
	var c := Vector2i(clampi(cell.x, 0, width - 1), clampi(cell.y, 0, height - 1))
	return heights[c.y * width + c.x]


func faction_at(cell: Vector2i) -> String:
	if not in_bounds(cell):
		return ""
	return region_factions.get(int(regions[cell.y * width + cell.x]), "")


func cell_to_world(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size


func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.y / cell_size))


func world_size() -> Vector2:
	return Vector2(width, height) * cell_size


## Cells from `from` to `to` inclusive, cheapest by terrain cost; empty if unreachable.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not (is_passable(from) and is_passable(to)):
		return []
	return astar.get_id_path(from, to)
