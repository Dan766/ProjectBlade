extends TestCase
## The bundle + map data load, agree with each other, and the continent is fully connected.

var gs: Node


func _state() -> Node:
	if gs == null:
		gs = load("res://scripts/autoload/game_state.gd").new()
		gs.load_all("res://data/generated", "res://data/world")
	return gs


func cleanup() -> void:
	if gs != null:
		gs.free()


func test_bundle_and_map_load_without_errors() -> void:
	var g := _state()
	check_eq(g.errors.size(), 0, str(g.errors))
	check_eq(g.continent, "Ormerath")
	check_eq(g.factions.size(), 6)
	check_eq(g.settlements.size(), 164)
	check_eq(g.personas.size(), 120)


func test_every_settlement_sits_on_passable_land_in_its_own_realm() -> void:
	var g := _state()
	for id in g.settlements:
		var s: Dictionary = g.settlements[id]
		check(g.terrain.is_passable(s["cell"]), "%s on %s" % [id, g.terrain.terrain_name(s["cell"])])
		check_eq(g.terrain.faction_at(s["cell"]), s["faction"], id)


func test_every_settlement_reachable_from_the_first_town() -> void:
	var g := _state()
	var start: Vector2i = g.settlements["town_01_01"]["cell"]
	var unreachable := []
	for id in g.settlements:
		if g.terrain.find_path(start, g.settlements[id]["cell"]).is_empty():
			unreachable.append(id)
	check_eq(unreachable, [], "unreachable settlements")


func test_villages_are_bound_to_a_lord_of_their_realm() -> void:
	var g := _state()
	for id in g.settlements:
		var s: Dictionary = g.settlements[id]
		if s["type"] == "village":
			var lord: Dictionary = g.settlements[s["bound_to"]]
			check(lord["type"] != "village" and lord["faction"] == s["faction"], id)


func test_settlement_near_picks_the_closest_within_radius() -> void:
	var g := _state()
	var p: Vector2 = g.terrain.cell_to_world(g.settlements["town_01_01"]["cell"])
	check_eq(g.settlement_near(p + Vector2(3, 0), 10.0), "town_01_01")
	check_eq(g.settlement_near(p, 10.0, ["village"]) == "town_01_01", false, "type filter")
