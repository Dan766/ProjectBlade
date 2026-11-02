class_name Party
extends RefCounted
## A party on the campaign map, as plain data: the simulation owns these and nodes only draw
## them, so hundreds of AI parties stay cheap (Phase 2) and saving is just serialising fields.

signal arrived(cell: Vector2i)

var id: String
var position: Vector2                 # world pixels
var path: Array[Vector2i] = []        # cells still to visit, next first
var speed: float = 5.0                # cells per game hour on plains (terrain cost divides it)

# --- simulation state (Phase 2; owned and updated by World) ---
var kind := "player"                  # player | lord | bandit | caravan
var name := ""                        # shown on the map: persona username, "Bandits", "... caravan"
var faction := ""
var persona_id := ""
var home := ""                        # settlement id lords return to and respawn at
var roster: Dictionary = Roster.empty()
var wounded: Dictionary = Roster.empty()  # out of action; heal back into `roster` over days
var prisoners := 0                        # common soldiers held for ransom (the player ransoms them in towns)
var gold := 0
var morale := 70.0
var goal := "idle"                    # idle | recruit | raid | trade | patrol | home | flee | chase | roam | travel
var goal_target := ""                 # settlement id or party id the goal is about
var goal_until := -1.0                # waiting (raiding, resting) until this time
var next_decision := 0.0              # re-plan at the latest by this time
var chase_until := -1.0
var battle_cooldown_until := -1.0
var routed_until := -1.0              # a routed lord is off the map until this time
var spawn_cell := Vector2i.ZERO       # bandits roam around where they spawned
var last_progress := 0.0              # last time it moved, waited on purpose or re-planned


func _init(party_id: String = "", start: Vector2 = Vector2.ZERO) -> void:
	id = party_id
	position = start


func is_active(now: float) -> bool:
	return routed_until < 0.0 or now >= routed_until


func troops() -> int:
	return Roster.size(roster)


func is_moving() -> bool:
	return not path.is_empty()


## Plan a route to `target`. Returns false (and keeps the old route) if it can't be reached.
func set_destination(terrain: TerrainMap, target: Vector2i) -> bool:
	var route := terrain.find_path(terrain.world_to_cell(position), target)
	if route.is_empty():
		return false
	route.remove_at(0)                # the cell we are standing in
	path = route
	if path.is_empty():
		arrived.emit(target)
	return true


func stop() -> void:
	path.clear()


## Move along the route for `hours` of game time. Entering a cell costs its terrain cost, so a
## party covers `speed` cells per hour on plains and fewer in forest, marsh or hills.
func advance(hours: float, terrain: TerrainMap) -> void:
	var budget := hours * speed       # in plains-cells
	while budget > 0.0 and not path.is_empty():
		var next: Vector2i = path[0]
		var target := terrain.cell_to_world(next)
		var cost := terrain.cost_at(next)
		var need := position.distance_to(target) / terrain.cell_size * cost
		if need <= budget:
			position = target
			budget -= need
			path.remove_at(0)
			if path.is_empty():
				arrived.emit(next)
		else:
			position = position.move_toward(target, budget / cost * terrain.cell_size)
			budget = 0.0


## Remaining route in world coordinates, starting at the party (for drawing).
func route_points(terrain: TerrainMap) -> PackedVector2Array:
	var pts := PackedVector2Array([position])
	for c in path:
		pts.append(terrain.cell_to_world(c))
	return pts
