extends Node
## The generated dialogue (res://data/generated): archetype pools, persona signature lines and
## scripted conversations, plus line picking, placeholder filling and per-persona typing style.
##
## pick(): a persona's own signature line wins with probability `signature_bias` when one fits
## (event, channel, relationship); otherwise the archetype pool for (event, relationship, channel),
## falling back to the "neutral" band. Lines used within `cooldown_s` are skipped unless nothing
## else is left (then the least recently used one is reused).

const GENERATED := "res://data/generated"

var manifest: Dictionary = {}
var events: Dictionary = {}              # event id -> {channels, relationships, placeholders, group}
var personas: Dictionary = {}            # id -> persona
var pools: Dictionary = {}               # archetype -> {event: {rel: {channel: [{id, text}]}}}
var signatures: Dictionary = {}          # persona id -> {username, signature: {event: [{id, channel, rel, text}]}}
var conversations: Array = []
var places: Dictionary = {}              # "town" | "castle" | "village" -> [{name, faction}]
var faction_names: Dictionary = {}       # faction id -> name
var cooldown_s := 900.0
var last_used: Dictionary = {}           # line id -> time it was last used
var errors: PackedStringArray = []


func _ready() -> void:
	if not load_bundle(GENERATED):
		push_warning("DialogueDB: " + "; ".join(errors))


func load_bundle(dir: String) -> bool:
	errors.clear()
	manifest = _json(dir + "/manifest.json", {})
	var ev: Dictionary = _json(dir + "/events.json", {})
	events = ev.get("events", {})
	for p in _json(dir + "/personas.json", []):
		personas[p["id"]] = p
	var archetypes := {}
	for p in personas.values():
		archetypes[p["archetype"]] = true
	for a in archetypes:
		pools[a] = _json("%s/dialogue/archetypes/%s.json" % [dir, a], {})
	for pid in personas:
		signatures[pid] = _json("%s/dialogue/personas/%s.json" % [dir, pid], {"signature": {}})
	conversations = _json(dir + "/dialogue/conversations.json", [])
	for f in _json(dir + "/world/factions.json", []):
		faction_names[f["id"]] = f["name"]
	for s in _json(dir + "/world/settlements.json", []):
		places.get_or_add(s["type"], []).append({"name": s["name"], "faction": s["faction"], "id": s["id"]})
	return errors.is_empty()


func _json(path: String, fallback):
	if not FileAccess.file_exists(path):
		errors.append("missing " + path)
		return fallback
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		errors.append("invalid JSON " + path)
		return fallback
	return data


## The relationship key an event uses: "any" for events that don't care about the player.
func rel_key(event: String, band: String) -> String:
	var rels: Array = events.get(event, {}).get("relationships", ["hostile", "neutral", "friendly"])
	return "any" if rels == ["any"] else band


## Lines persona `pid` could say. Returns {"signature": [...], "pool": [...]}.
func candidates(pid: String, event: String, band: String, channel: String) -> Dictionary:
	var rel := rel_key(event, band)
	var arch: String = personas[pid]["archetype"]
	var pool_event: Dictionary = pools.get(arch, {}).get(event, {})
	var pool: Array = pool_event.get(rel, {}).get(channel, [])
	if pool.is_empty() and rel != "any":
		pool = pool_event.get("neutral", {}).get(channel, [])
	var sig: Array = signatures.get(pid, {}).get("signature", {}).get(event, []).filter(
		func(l): return l["channel"] == channel and (l["rel"] == rel or l["rel"] == "any"))
	return {"signature": sig, "pool": pool}


## A line for persona `pid` ({id, text}), or {} if the event has nothing for this channel.
## With allow_reuse false, returns {} rather than repeat a line inside its cooldown.
func pick(pid: String, event: String, band: String, channel: String, now: float, rng: RandomNumberGenerator, signature_bias: float, allow_reuse: bool = true) -> Dictionary:
	var c := candidates(pid, event, band, channel)
	var lines: Array = c["pool"]
	if not c["signature"].is_empty() and (lines.is_empty() or rng.randf() < signature_bias):
		lines = c["signature"]
	if lines.is_empty():
		return {}
	var fresh := lines.filter(func(l): return now - float(last_used.get(l["id"], -INF)) >= cooldown_s)
	var chosen: Dictionary
	if fresh.is_empty() and not allow_reuse:
		return {}
	if fresh.is_empty():
		chosen = lines[0]
		for l in lines:
			if float(last_used.get(l["id"], -INF)) < float(last_used.get(chosen["id"], -INF)):
				chosen = l
	else:
		chosen = fresh[rng.randi_range(0, fresh.size() - 1)]
	last_used[chosen["id"]] = now
	return chosen


## Apply a persona's typing style to a line template: lowercase for "lower" typists, and the
## occasional swapped letter for typo-prone ones. Placeholders are left untouched.
func style(text: String, persona: Dictionary, rng: RandomNumberGenerator, typo_rates: Dictionary) -> String:
	var cs: Dictionary = persona["chat_style"]
	var rate := float(typo_rates.get(cs["typos"], 0.0))
	var words := text.split(" ")
	for i in words.size():
		var w: String = words[i]
		if w.contains("{"):
			continue
		if cs["case"] == "lower":
			w = w.to_lower()
		if w.length() > 3 and rng.randf() < rate:
			# swap two neighbouring LETTERS inside the word; punctuation never moves ("wa?y?" read as broken)
			var spots := range(1, w.length() - 2).filter(func(j): return _is_letter(w[j]) and _is_letter(w[j + 1]))
			if not spots.is_empty():
				var j: int = spots[rng.randi_range(0, spots.size() - 1)]
				w = w.substr(0, j) + w[j + 1] + w[j] + w.substr(j + 2)
		words[i] = w
	return " ".join(words)


func _is_letter(c: String) -> bool:
	return c.to_lower() != c.to_upper()


## Fill every {placeholder}. Values in `ctx` win; anything missing gets a sensible random value,
## and {gold} / {troop_count} are drawn per occurrence unless given. Never leaves a brace.
func fill(text: String, ctx: Dictionary, rng: RandomNumberGenerator) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var open := text.find("{", i)
		if open < 0:
			out += text.substr(i)
			break
		var close := text.find("}", open)
		if close < 0:
			out += text.substr(i).replace("{", "")
			break
		out += text.substr(i, open - i)
		out += _value(text.substr(open + 1, close - open - 1), ctx, rng)
		i = close + 1
	return out.replace("}", "")


func _value(key: String, ctx: Dictionary, rng: RandomNumberGenerator) -> String:
	if ctx.has(key):
		return str(ctx[key])
	match key:
		"gold":
			return str(rng.randi_range(5, 150) * 10)
		"troop_count":
			return str(rng.randi_range(8, 120))
		"town", "castle", "village":
			return _random_place(key, ctx.get("faction_id", ""), rng)
		"fief":
			return _random_place("castle" if rng.randf() < 0.5 else "town", ctx.get("faction_id", ""), rng)
		"faction", "enemy_faction", "my_faction":
			var names := faction_names.values()
			return names[rng.randi_range(0, names.size() - 1)] if names else "the realm"
		"rival", "persona":
			var ids := personas.keys()
			return personas[ids[rng.randi_range(0, ids.size() - 1)]]["username"] if ids else "someone"
		"player":
			return "stranger"
	return ""


func _random_place(kind: String, faction_id: String, rng: RandomNumberGenerator) -> String:
	var all: Array = places.get(kind, [])
	var own := all.filter(func(p): return p["faction"] == faction_id)
	var from: Array = own if not own.is_empty() and rng.randf() < 0.7 else all
	return from[rng.randi_range(0, from.size() - 1)]["name"] if from else "the road"
