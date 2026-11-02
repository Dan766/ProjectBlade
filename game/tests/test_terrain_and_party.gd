extends TestCase
## Terrain costs, pathfinding and party movement on a tiny hand-made map, so the expected
## numbers are exact:
##   row 0  . . . . . . .      plains
##   row 1  . ~ ~ ~ ~ ~ .      a lake in the middle
##   row 2  f f f f f f f      forest (cost 1.6)


func _map() -> TerrainMap:
	var t := TerrainMap.new()
	t.load_dict({
		"width": 7, "height": 3, "cell_size": 10,
		"legend": {"~": {"name": "water", "cost": 0}, ".": {"name": "plains", "cost": 1.0}, "f": {"name": "forest", "cost": 1.6}},
		"rows": [".......", ".~~~~~.", "fffffff"],
		"region_legend": {"1": "faction_01"},
		"regions": ["1111111", "1000001", "1111111"],
	})
	return t


func test_costs_and_lookup() -> void:
	var t := _map()
	check_eq(t.cost_at(Vector2i(0, 0)), 1.0)
	check_eq(t.cost_at(Vector2i(0, 2)), 1.6)
	check(not t.is_passable(Vector2i(2, 1)), "water is impassable")
	check(not t.is_passable(Vector2i(-1, 0)), "outside the map is impassable")
	check_eq(t.terrain_name(Vector2i(3, 2)), "forest")
	check_eq(t.faction_at(Vector2i(3, 0)), "faction_01")
	check_eq(t.faction_at(Vector2i(3, 1)), "")
	check_eq(t.world_to_cell(t.cell_to_world(Vector2i(5, 2))), Vector2i(5, 2))


func test_path_goes_around_water_and_prefers_cheap_terrain() -> void:
	var t := _map()
	var path := t.find_path(Vector2i(0, 1), Vector2i(6, 1))
	check(not path.is_empty(), "path exists around the lake")
	for c in path:
		check(t.is_passable(c), "path crosses %s" % str(c))
	check(path.all(func(c): return c.y != 2), "takes the plains row, not the forest: %s" % str(path))
	check(t.find_path(Vector2i(0, 0), Vector2i(3, 1)).is_empty(), "no path into water")


func test_party_moves_speed_cells_per_hour_on_plains() -> void:
	var t := _map()
	var p := Party.new("p", t.cell_to_world(Vector2i(0, 0)))
	p.speed = 2.0
	check(p.set_destination(t, Vector2i(6, 0)), "destination accepted")
	p.advance(1.0, t)
	check_near(p.position.x, t.cell_to_world(Vector2i(2, 0)).x, 0.01, "2 cells in 1 hour")
	check(p.is_moving(), "still travelling")


func test_forest_is_slower_by_its_cost() -> void:
	var t := _map()
	var p := Party.new("p", t.cell_to_world(Vector2i(0, 2)))
	p.speed = 2.0
	p.set_destination(t, Vector2i(6, 2))
	p.advance(1.6, t)
	check_near(p.position.x, t.cell_to_world(Vector2i(2, 2)).x, 0.01, "2 forest cells take 1.6 hours")


func test_party_arrives_and_signals_once() -> void:
	var t := _map()
	var p := Party.new("p", t.cell_to_world(Vector2i(0, 0)))
	var hits := []
	p.arrived.connect(func(c): hits.append(c))
	p.set_destination(t, Vector2i(3, 0))
	for i in 20:
		p.advance(0.25, t)
	check_eq(hits, [Vector2i(3, 0)])
	check(not p.is_moving(), "stopped")
	check_eq(p.position, t.cell_to_world(Vector2i(3, 0)))


func test_unreachable_destination_keeps_old_route() -> void:
	var t := _map()
	var p := Party.new("p", t.cell_to_world(Vector2i(0, 0)))
	p.set_destination(t, Vector2i(6, 0))
	var before := p.path.duplicate()
	check(not p.set_destination(t, Vector2i(3, 1)), "lake rejected")
	check_eq(p.path, before)
