class_name ReputationScreen
extends CanvasLayer
## P toggles this: your realm, its wars, your fiefs, and the ten players who like you most and
## least, each with the latest reason they feel that way (Relations.reason). Parchment look (G7).

const SHOW := 10


func open(w: World) -> void:
	layer = 9
	var view := get_viewport().get_visible_rect().size
	add_child(UiTheme.dim_rect(view))
	var panel := PanelContainer.new()
	panel.theme = UiTheme.parchment()
	panel.custom_minimum_size = Vector2(1200, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	box.add_child(UiTheme.label("Reputation", "HeaderLarge"))
	var head := UiTheme.label("", "HeaderSmall")
	var mine := w.player.faction
	if mine == "":
		head.text = "You serve no realm.  (J in a town swears allegiance to its owner.)"
	else:
		var foes := w.factions.keys().filter(func(f): return w.at_war(mine, f)).map(func(f): return w.factions[f]["name"])
		var fiefs := w._forts.filter(func(id): return w.state[id]["holder"] == "player").map(func(id): return w.settlements[id]["name"])
		head.text = "Sworn to the %s  ·  At war with: %s  ·  Your fiefs: %s" % [w.factions[mine]["name"],
			", ".join(foes) if foes else "no one", ", ".join(fiefs) if fiefs else "none yet"]
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size = Vector2(1148, 0)
	box.add_child(head)
	box.add_child(UiTheme.label("Renown %d   ·   Battles won %d, lost %d   ·   Current streak %d" % [w.player_stats["renown"],
		w.player_stats["wins"], w.player_stats["losses"], w.player_stats["streak"]]))
	box.add_child(HSeparator.new())

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 36)
	box.add_child(cols)
	var ids := w.personas.keys()
	ids.sort_custom(func(a, b): return w.relations.score(a) > w.relations.score(b))
	cols.add_child(_column(w, "Friends", ids.slice(0, SHOW), UiTheme.color("good")))
	ids.reverse()
	cols.add_child(_column(w, "Enemies", ids.slice(0, SHOW), UiTheme.color("bad")))

	var foot := UiTheme.label("P or Esc to close", "MutedLabel")
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(foot)
	panel.reset_size()
	panel.position = ((view - panel.get_combined_minimum_size()) * 0.5).floor()


func _column(w: World, title: String, ids: Array, color: Color) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(556, 0)
	col.add_theme_constant_override("separation", 4)
	var t := UiTheme.label(title, "HeaderMedium")
	t.add_theme_color_override("font_color", color)
	col.add_child(t)
	for pid in ids:
		var p: Dictionary = w.personas[pid]
		var row := RichTextLabel.new()
		row.bbcode_enabled = true
		row.fit_content = true
		row.scroll_active = false
		row.custom_minimum_size = Vector2(556, 0)
		row.text = "[color=#%s][b]%+d[/b][/color]  [b]%s[/b]  [i](%s, %s)[/i]  -  %s" % [color.to_html(false),
			int(w.relations.score(pid)), _esc(p["username"]), p["archetype"].replace("_", " "), w.factions[p["faction"]]["name"],
			_esc(w.relations.reason(pid))]
		col.add_child(row)
	return col


static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_P, KEY_ESCAPE]:
		get_viewport().set_input_as_handled()
		queue_free()
