class_name BattleScreen
extends CanvasLayer
## Modal battle screen for the player's battles. Each round the player picks a command (buttons
## or H/A/F/C/R); the enemy's AI picks by persona; the round plays and the screen refreshes.
## When the battle ends it shows the aftermath and, for a captured lord, Release / Ransom.
## Emits `closed(result, choice)`; the map hands that to World.apply_player_battle().

signal closed(result: Dictionary, choice: String)

const KEYS := {KEY_H: "hold", KEY_A: "advance", KEY_F: "flank", KEY_C: "charge", KEY_R: "retreat"}

var battle: Battle
var _armies: Array[VBoxContainer] = []
var _round: Label
var _log: Label
var _commands: HBoxContainer
var _after: VBoxContainer
var _result: Dictionary = {}
var _panel: PanelContainer


func open(b: Battle) -> void:
	battle = b
	layer = 10
	_build()
	_refresh()


func _build() -> void:
	var view := get_viewport().get_visible_rect().size
	add_child(UiTheme.dim_rect(view))

	_panel = PanelContainer.new()
	var panel := _panel
	panel.theme = UiTheme.parchment()
	panel.custom_minimum_size = Vector2(1040, 0)             # height follows the content; re-centred in _refresh
	add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title := UiTheme.label("Battle on the %s" % battle.terrain_name, "HeaderLarge")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)
	var vs := UiTheme.label("%s  versus  %s" % [battle.a.name, _enemy_title()], "HeaderSmall")
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(vs)
	root.add_child(HSeparator.new())

	var sides := HBoxContainer.new()
	sides.add_theme_constant_override("separation", 40)
	root.add_child(sides)
	for i in 2:
		var col := VBoxContainer.new()
		col.custom_minimum_size = Vector2(474, 170)
		sides.add_child(col)
		_armies.append(col)

	_round = UiTheme.label("", "HeaderMedium")
	_round.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_round)

	_commands = HBoxContainer.new()
	_commands.alignment = BoxContainer.ALIGNMENT_CENTER
	_commands.add_theme_constant_override("separation", 12)
	root.add_child(_commands)
	var help: Dictionary = battle.rules["command_help"]
	for cmd in Battle.COMMANDS:
		var btn := Button.new()
		btn.text = "%s (%s)" % [cmd.capitalize(), cmd.substr(0, 1).to_upper()]
		btn.tooltip_text = help[cmd]
		btn.custom_minimum_size = Vector2(150, 40)
		btn.pressed.connect(play.bind(cmd))
		_commands.add_child(btn)
	var auto := Button.new()
	auto.text = "Auto-resolve"
	auto.tooltip_text = "Let your sergeants fight the rest of the battle."
	auto.pressed.connect(_auto_resolve)
	_commands.add_child(auto)

	_log = UiTheme.label("", "MutedLabel")
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.custom_minimum_size = Vector2(988, 0)
	root.add_child(_log)

	_after = VBoxContainer.new()
	_after.visible = false
	root.add_child(_after)


func _enemy_title() -> String:
	var e := battle.b
	if e.kind == "lord":
		var per: Dictionary = GameState.personas[e.persona_id]
		return "%s (%s of the %s)" % [e.name, per["archetype"].replace("_", " ").capitalize(), GameState.factions[e.faction]["name"]]
	return e.name


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if not battle.over and KEYS.has(event.keycode):
			play(KEYS[event.keycode])
			get_viewport().set_input_as_handled()
		elif battle.over and event.keycode in [KEY_ENTER, KEY_SPACE, KEY_KP_ENTER] and not _result.get("captured", false):
			_close("")
			get_viewport().set_input_as_handled()


## Play one round with the player's command.
func play(cmd: String) -> void:
	if battle.over:
		return
	var enemy_cmd := battle.ai_command(battle.b, battle.a, battle.role_b, battle.last_cmd["a"])
	battle.play_round(cmd, enemy_cmd)
	_refresh()


func _auto_resolve() -> void:
	battle.auto_play()
	_refresh()


func _refresh() -> void:
	_fill_army(_armies[0], battle.a, battle.start_a)
	_fill_army(_armies[1], battle.b, battle.start_b)
	_round.text = "Round %d of %d" % [battle.round, int(battle.rules["max_rounds"])] if not battle.over else "The battle is over"
	_log.text = "\n".join(battle.log.slice(maxi(0, battle.log.size() - 7)))
	if battle.over and _result.is_empty():
		_commands.visible = false
		_show_aftermath()
	_recentre.call_deferred()                            # after the rows above have been laid out


func _recentre() -> void:
	if not is_inside_tree() or not is_instance_valid(_panel):
		return
	_panel.reset_size()
	_panel.position = ((get_viewport().get_visible_rect().size - _panel.get_combined_minimum_size()) * 0.5).floor()


func _fill_army(col: VBoxContainer, p: Party, start: float) -> void:
	for c in col.get_children():
		col.remove_child(c)                              # out of the layout now, not at frame end
		c.queue_free()
	var pct := int(100.0 * battle.strength(p) / maxf(start, 0.001))
	col.add_child(UiTheme.label(p.name, "HeaderMedium"))
	col.add_child(UiTheme.label("%d troops  ·  strength %d%%" % [p.troops(), pct], "MutedLabel"))
	var unit_colors: Dictionary = UiTheme.cfg.get("unit_colors", {})
	for t in Roster.TYPES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lab := Label.new()
		var n: int = p.roster[t][0] + p.roster[t][1] + p.roster[t][2]
		var hurt: int = p.wounded[t][0] + p.wounded[t][1] + p.wounded[t][2]
		lab.text = "%s  %d  (tiers %d/%d/%d, %d wounded)" % [t.capitalize(), n, p.roster[t][0], p.roster[t][1], p.roster[t][2], hurt]
		lab.custom_minimum_size = Vector2(300, 0)
		row.add_child(lab)
		var bar := ColorRect.new()
		bar.color = Color(unit_colors.get(t, "#7a6a50"))
		bar.custom_minimum_size = Vector2(mini(160, n * 2), 12)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		col.add_child(row)


func _show_aftermath() -> void:
	_result = battle.finish()
	_after.visible = true
	var won: bool = _result["winner"] == battle.a
	var how := "routed them" if _result["routed"] else ("they escaped" if _result["fled"] else "they withdrew")
	if not won:
		how = "you were routed" if _result["routed"] else ("you escaped" if _result["fled"] else "you withdrew")
	var verdict := UiTheme.label("Victory" if won else "Defeat", "HeaderLarge")
	verdict.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	verdict.add_theme_color_override("font_color", UiTheme.color("good") if won else UiTheme.color("bad"))
	_after.add_child(verdict)
	var text := Label.new()
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text = "%s (%s).  You lost %d, they lost %d.  Loot: %d gold.  Prisoners: %d." % [
		"You beat " + battle.b.name if won else battle.b.name + " beat you", how,
		_result["winner_lost"] if won else _result["loser_lost"], _result["loser_lost"] if won else _result["winner_lost"],
		_result["loot"] if won else 0, _result["prisoners"] if won else 0]
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(960, 0)
	_after.add_child(text)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	_after.add_child(buttons)
	if _result.get("captured", false):
		var note := Label.new()
		var plea: String = ChatDirector.speak_now(battle.b.persona_id, "captured_by_player", "face")
		note.text = "%s is your prisoner.%s" % [battle.b.name, "  \"%s\"" % plea if plea != "" else ""]
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size = Vector2(960, 0)
		_after.add_child(note)
		_after.move_child(note, 1)
		_button(buttons, "Release %s" % battle.b.name, "release")
		_button(buttons, "Ransom for %d gold" % int(battle.rules["lord_ransom"]), "ransom")
	else:
		_button(buttons, "Continue (Enter)", "")


func _button(parent: Node, text: String, choice: String) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 40)
	b.pressed.connect(_close.bind(choice))
	parent.add_child(b)


func _close(choice: String) -> void:
	closed.emit(_result, choice)
	queue_free()
