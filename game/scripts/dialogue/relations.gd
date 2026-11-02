class_name Relations
extends RefCounted
## What every persona remembers about the player: a relationship score (-100 hostile .. 100
## friendly), counters and flags. Owned by World so the sim can act on grudges, saved with it.

var cfg: Dictionary                  # chat.json "relationship"
var bands: Dictionary                # events.json relationship_bands
var memory: Dictionary = {}          # persona id -> {score, beaten_by_player, beat_player, released, ransomed, allied}


func setup(chat_relationship: Dictionary, relationship_bands: Dictionary, personas: Dictionary, rng: RandomNumberGenerator) -> void:
	cfg = chat_relationship
	bands = relationship_bands
	var ids := personas.keys()
	ids.sort()
	var jitter := float(cfg["start_jitter"])
	for pid in ids:
		var start := float(cfg["start"].get(personas[pid]["archetype"], 0))
		memory[pid] = {"score": clampf(start + rng.randf_range(-jitter, jitter), -100.0, 100.0),
			"beaten_by_player": 0, "beat_player": 0, "released": 0, "ransomed": 0, "allied": false}


func score(pid: String) -> float:
	return memory[pid]["score"] if memory.has(pid) else 0.0


func adjust(pid: String, delta: float) -> void:
	if memory.has(pid):
		memory[pid]["score"] = clampf(memory[pid]["score"] + delta, -100.0, 100.0)


func count(pid: String, key: String, by: int = 1) -> int:
	if not memory.has(pid):
		return 0
	memory[pid][key] += by
	return memory[pid][key]


func get_value(pid: String, key: String):
	return memory[pid][key] if memory.has(pid) else null


func set_value(pid: String, key: String, value) -> void:
	if memory.has(pid):
		memory[pid][key] = value


## Change the score and remember why (newest reason first, last 3 kept): the reputation screen
## shows the reason, e.g. "You took Brenzolo from them".
func adjust_why(pid: String, delta: float, why: String) -> void:
	adjust(pid, delta)
	if memory.has(pid):
		var notes: Array = memory[pid].get_or_add("notes", [])
		notes.push_front(why)
		if notes.size() > 3:
			notes.resize(3)


func reason(pid: String) -> String:
	var notes: Array = memory.get(pid, {}).get("notes", [])
	return notes[0] if not notes.is_empty() else "First impressions."


## "hostile" | "neutral" | "friendly" for the dialogue lookup.
func band(pid: String) -> String:
	var s := score(pid)
	if s < float(bands["hostile_below"]):
		return "hostile"
	if s > float(bands["friendly_above"]):
		return "friendly"
	return "neutral"
