class_name EncounterDialog
extends CanvasLayer
## Meeting a lord on the map. They greet you in their own voice (encounter_greeting, by how they
## feel about you); you can threaten them, offer gold, propose an alliance, attack, or leave.
## Every choice is answered with their line for it and changes how they remember you.
## Emits closed("leave" | "attack" | "ambushed").

signal closed(action: String)

var world: World
var lord: Party
var pid: String
var _speech: Label
var _status: Label
var _buttons: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func open(w: World, lord_party: Party) -> void:
	world = w
	lord = lord_party
	pid = lord.persona_id
	_rng.randomize()
	layer = 10
	_build()
	_say("encounter_greeting", {"my_faction": GameState.factions[lord.faction]["name"]})


func _build() -> void:
	var view := get_viewport().get_visible_rect().size
	add_child(UiTheme.dim_rect(view))
	var panel := PanelContainer.new()
	panel.theme = UiTheme.parchment()
	panel.custom_minimum_size = Vector2(780, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var per: Dictionary = GameState.personas[pid]
	box.add_child(UiTheme.label(lord.name, "HeaderLarge"))
	box.add_child(UiTheme.label("%s of the %s  ·  %d troops" % [per["archetype"].replace("_", " ").capitalize(),
		GameState.factions[lord.faction]["name"], lord.troops()], "HeaderSmall"))
	_status = UiTheme.label("", "MutedLabel")
	box.add_child(_status)
	_speech = Label.new()
	_speech.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_speech.custom_minimum_size = Vector2(728, 96)
	_speech.add_theme_font_size_override("font_size", 21)
	box.add_child(_speech)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var gift := int(world.chat_cfg["encounter"]["gift"])
	for spec in [["threaten", "Threaten"], ["gift", "Offer %d gold" % gift], ["alliance", "Propose alliance"],
			["attack", "Attack"], ["leave", "Leave"]]:
		var b := Button.new()
		b.text = spec[1]
		b.custom_minimum_size = Vector2(132, 40)
		b.pressed.connect(choose.bind(spec[0]))
		row.add_child(b)
		_buttons[spec[0]] = b
	_refresh_status()
	panel.reset_size()
	panel.position = ((view - panel.get_combined_minimum_size()) * 0.5).floor()


func _refresh_status() -> void:
	var r := world.relations
	var extra := "  (allied)" if r.get_value(pid, "allied") else ""
	_status.text = "How they feel about you: %d (%s)%s   ·   Beaten by you %d times" % [
		int(r.score(pid)), r.band(pid), extra, int(r.get_value(pid, "beaten_by_player"))]


func _say(event: String, ctx: Dictionary = {}, note: String = "") -> void:
	var line: String = ChatDirector.speak_now(pid, event, "face", ctx)
	_speech.text = ("\"%s\"" % line if line != "" else "...") + ("\n\n" + note if note != "" else "")


## Player picks an option (also used by tests and automation).
func choose(action: String) -> void:
	var rel: Dictionary = world.chat_cfg["relationship"]
	var enc: Dictionary = world.chat_cfg["encounter"]
	var r := world.relations
	match action:
		"threaten":
			_buttons["threaten"].disabled = true
			var ratio := world.strength(world.player) / maxf(world.strength(lord), 1.0)
			var honor := float(world.weights(lord).get("honor", 0.5))
			if ratio > 1.5 and _rng.randf() < (1.0 - honor) * 0.9:
				var paid := mini(lord.gold, _rng.randi_range(int(enc["threaten_pay"][0]), int(enc["threaten_pay"][1])))
				lord.gold -= paid
				world.player.gold += paid
				r.adjust_why(pid, float(rel["threatened_paid"]), "You shook them down for %d gold." % paid)
				_say("encounter_threatened", {"gold": str(paid)}, "They hand over %d gold." % paid)
			else:
				r.adjust_why(pid, float(rel["threatened_refused"]), "You threatened them.")
				var fights := float(world.weights(lord).get("aggression", 0.5)) >= 0.5 and ratio < 1.25
				_say("encounter_threatened", {}, "They draw steel!" if fights else "They refuse to be cowed.")
				if fights:
					_finish("ambushed", 1.2)
					return
		"gift":
			var gift := int(enc["gift"])
			if world.player.gold < gift:
				_speech.text = "You don't have %d gold." % gift
				return
			_buttons["gift"].disabled = true
			world.player.gold -= gift
			lord.gold += gift
			var bonus := float(rel["gift_trader_bonus"]) if GameState.personas[pid]["archetype"] == "trader" else 1.0
			r.adjust_why(pid, float(rel["gift_per_100_gold"]) * gift / 100.0 * bonus, "You gave them %d gold." % gift)
			_say("encounter_trade_offer", {"gold": str(gift)}, "They take your %d gold." % gift)
		"alliance":
			_buttons["alliance"].disabled = true
			if r.score(pid) >= float(enc["alliance_min_relationship"]) or r.get_value(pid, "allied"):
				r.set_value(pid, "allied", true)
				r.adjust_why(pid, float(rel["alliance_accepted"]), "You are allies.")
				_say("encounter_alliance_yes", {}, "%s is now your ally." % lord.name)
			else:
				r.adjust_why(pid, float(rel["alliance_refused"]), "They turned down your alliance.")
				_say("encounter_alliance_no")
		"attack":
			_finish("attack", 0.0)
			return
		"leave":
			for b in _buttons.values():
				b.disabled = true
			_say("encounter_farewell")
			_finish("leave", 1.6)
			return
	_refresh_status()


func _finish(action: String, after_s: float) -> void:
	for b in _buttons.values():
		b.disabled = true
	if after_s > 0.0:
		await get_tree().create_timer(after_s).timeout
	closed.emit(action)
	queue_free()
