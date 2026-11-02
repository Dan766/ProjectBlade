class_name ChatPanel
extends CanvasLayer
## Server chat, bottom-left: a Global tab plus one tab per persona who whispers you (marked with
## a dot while unread). Usernames are links: clicking one emits persona_clicked so the map can
## find that lord.

signal persona_clicked(persona_id: String)

const MAX_LINES := 150

var _tabs: TabContainer
var _global: RichTextLabel
var _whisper: Dictionary = {}          # persona id -> RichTextLabel


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.position = Vector2(8, -294)
	panel.custom_minimum_size = Vector2(600, 248)
	panel.size = panel.custom_minimum_size
	var see_through := (panel.get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
	see_through.bg_color.a = 0.72                  # the map shows through the chat
	panel.add_theme_stylebox_override("panel", see_through)
	add_child(panel)
	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(576, 232)
	var tab_bg := (_tabs.get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
	tab_bg.bg_color.a = 0.0
	_tabs.add_theme_stylebox_override("panel", tab_bg)
	_tabs.tab_changed.connect(_on_tab_changed)
	panel.add_child(_tabs)
	_global = _make_log("Global")
	if ChatDirector.has_signal("message_posted"):
		ChatDirector.message_posted.connect(_on_message)


func _make_log(title: String) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.name = title
	r.bbcode_enabled = true
	r.scroll_following = true
	r.meta_underlined = false                      # usernames are links, coloured by realm
	r.meta_clicked.connect(func(meta): persona_clicked.emit(str(meta)))
	_tabs.add_child(r)
	return r


func _on_message(msg: Dictionary) -> void:
	var name_color := GameState.faction_color(msg["faction"]).lightened(0.45)
	var who := "[b][color=#%s][url=%s]%s[/url][/color][/b]" % [name_color.to_html(false), msg["pid"], msg["name"]]
	var text := _escape(msg["text"])
	if msg["channel"] == "global":
		_append(_global, "%s: %s" % [who, text])
		return
	var log := _whisper_log(msg["pid"], msg["name"])
	_append(log, "[i]%s whispers:[/i] %s" % [who, text])
	_append(_global, "[i][color=#%s]%s whispered to you.[/color][/i]" % [UiTheme.color("whisper").to_html(false), who])
	if _tabs.get_current_tab_control() != log:
		_tabs.set_tab_title(log.get_index(), "@%s *" % msg["name"])


func _whisper_log(pid: String, username: String) -> RichTextLabel:
	if not _whisper.has(pid):
		_whisper[pid] = _make_log("@" + username)
	return _whisper[pid]


func _append(r: RichTextLabel, bbcode: String) -> void:
	r.append_text(bbcode + "\n")
	while r.get_paragraph_count() > MAX_LINES:
		r.remove_paragraph(0)


func _on_tab_changed(index: int) -> void:
	var title := _tabs.get_tab_title(index)
	if title.ends_with(" *"):
		_tabs.set_tab_title(index, title.trim_suffix(" *"))


func _escape(text: String) -> String:
	return text.replace("[", "[lb]")
