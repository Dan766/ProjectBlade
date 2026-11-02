extends Node
## All world data, as plain dictionaries and RefCounted objects (not nodes).
## Content comes from the pipeline bundle (res://data/generated, never edited by hand);
## map geometry from hand-editable data (res://data/world, made by tools/gen_map.py).

const GENERATED := "res://data/generated"
const WORLD := "res://data/world"
const BUNDLE_VERSION := 1

var continent: String = ""
var factions: Dictionary = {}       # id -> {name, adjective, ruler_title, lore, colors, troop_names}
var settlements: Dictionary = {}    # id -> bundle fields + "cell": Vector2i (+ "bound_to" for villages)
var personas: Dictionary = {}       # id -> persona
var terrain: TerrainMap
var sim_config: Dictionary = {}
var battle_config: Dictionary = {}
var chat_config: Dictionary = {}
var map3d_config: Dictionary = {}
var relationship_bands: Dictionary = {"hostile_below": -30, "friendly_above": 30}
var world: World                    # the running simulation (created in _ready, not by load_all)
var errors: PackedStringArray = []

const SIM_CONFIG := "res://data/config/sim.json"
const BATTLE_CONFIG := "res://data/config/battle.json"
const CHAT_CONFIG := "res://data/config/chat.json"
const MAP3D_CONFIG := "res://data/config/map3d.json"
const UI_CONFIG := "res://data/config/ui.json"


func _ready() -> void:
	var ui = _read_json(UI_CONFIG)
	UiTheme.apply(ui if ui != null else {})             # before any screen is built
	if not load_all(GENERATED, WORLD):
		for e in errors:
			push_error("GameState: " + e)
		return
	world = new_world(1)
	world.sim_event.connect(func(kind: String, data: Dictionary) -> void: EventBus.sim_event.emit(kind, data))


## A fresh simulation over the loaded data. Tests make their own with a fixed seed.
func new_world(seed: int) -> World:
	var w := World.new()
	w.setup(self, sim_config, seed)
	return w


func load_all(generated: String, world: String) -> bool:
	errors.clear()
	factions.clear()
	settlements.clear()
	personas.clear()
	var manifest = _read_json(generated + "/manifest.json")
	if manifest == null:
		return false
	if int(manifest.get("bundle_version", 0)) != BUNDLE_VERSION:
		errors.append("bundle_version %s, game expects %d" % [manifest.get("bundle_version"), BUNDLE_VERSION])
	continent = manifest.get("continent", "")
	for f in _read_json(generated + "/world/factions.json"):
		factions[f["id"]] = f
	for s in _read_json(generated + "/world/settlements.json"):
		settlements[s["id"]] = s
	for p in _read_json(generated + "/personas.json"):
		personas[p["id"]] = p

	var layout = _read_json(world + "/layout.json")
	if layout != null:
		for entry in layout["settlements"]:
			var id: String = entry["id"]
			if not settlements.has(id):
				errors.append("layout.json places unknown settlement " + id)
				continue
			settlements[id]["cell"] = Vector2i(int(entry["x"]), int(entry["y"]))
			if entry.has("bound_to"):
				settlements[id]["bound_to"] = entry["bound_to"]
	for id in settlements:
		if not settlements[id].has("cell"):
			errors.append("settlement %s has no map position (rerun tools/gen_map.py)" % id)

	terrain = TerrainMap.from_file(world + "/terrain.json")
	if terrain == null:
		errors.append("could not load terrain.json")
	var sim = _read_json(SIM_CONFIG)
	if sim != null:
		sim_config = sim
	var battle = _read_json(BATTLE_CONFIG)
	if battle != null:
		battle_config = battle
	var chat = _read_json(CHAT_CONFIG)
	if chat != null:
		chat_config = chat
	var map3d = _read_json(MAP3D_CONFIG)
	if map3d != null:
		map3d_config = map3d
	var ev = _read_json(generated + "/events.json")
	if ev != null:
		relationship_bands = ev["relationship_bands"]
	return errors.is_empty()


func faction_color(faction_id: String, which: String = "primary") -> Color:
	return Color(factions[faction_id]["colors"][which])


## The settlement nearest `world_pos` within `radius_px`, or "" if none.
func settlement_near(world_pos: Vector2, radius_px: float, types: Array = ["town", "castle", "village"]) -> String:
	var best := ""
	var best_d := radius_px * radius_px
	for id in settlements:
		var s: Dictionary = settlements[id]
		if not types.has(s["type"]):
			continue
		var d := terrain.cell_to_world(s["cell"]).distance_squared_to(world_pos)
		if d <= best_d:
			best_d = d
			best = id
	return best


func _read_json(path: String):
	if not FileAccess.file_exists(path):
		errors.append("missing " + path)
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		errors.append("invalid JSON in " + path)
	return data
