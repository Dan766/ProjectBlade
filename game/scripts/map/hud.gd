class_name Hud
extends CanvasLayer
## Screen-space info (restyled in G7, look from UiTheme): a top bar with the date, speed and your
## company; a card for the hovered/selected settlement or party; realm news; a controls bar; short
## notices ("Can't travel there"). Built in code to keep the scene file trivial.

var _clock: Label
var _speed: Label
var _company: Label
var _card_title: Label
var _card_sub: Label
var _info: Label
var _info_panel: PanelContainer
var _notice: Label
var _notice_panel: PanelContainer
var _notice_left := 0.0
var _feed: Label
var _feed_lines: Array[String] = []
var _card_settlement := ""            # the settlement the card shows, refreshed as owners/sieges change
var _card_refresh := 0.0

const FEED_SIZE := 7
const CARD_REFRESH_SECONDS := 1.0
const HELP := "Click  travel / meet     Shift+click  attack     R  hire     J / L  join / leave     B  besiege     X  raid     P  reputation     Space  pause     1-3  speed     WASD  pan     Q / E  rotate     Wheel  zoom     F  find party"
const GOAL_TEXT := {
	"raid": "Riding to raid %s", "trade": "Trading at %s", "recruit": "Recruiting in %s",
	"patrol": "Patrolling toward %s", "home": "Heading home to %s", "flee": "Fleeing from %s",
	"chase": "Chasing %s", "roam": "Roaming the wilds", "idle": "Resting",
}


func _ready() -> void:
	# Top bar: the date on the left, speed in the middle, your company on the right.
	var bar := PanelContainer.new()
	bar.anchor_right = 1.0
	bar.offset_left = 8
	bar.offset_right = -8
	bar.offset_top = 6
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	bar.add_child(row)
	_clock = UiTheme.label("", "HeaderMedium")
	row.add_child(_clock)
	_speed = UiTheme.label("")                       # body font: Cinzel turns "1x" into "IX"
	_speed.add_theme_color_override("font_color", UiTheme.color("notice"))
	row.add_child(_speed)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_company = UiTheme.label("")
	row.add_child(_company)

	# The card for whatever is hovered or selected.
	_info_panel = PanelContainer.new()
	_info_panel.position = Vector2(8, 62)
	_info_panel.custom_minimum_size = Vector2(400, 0)
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)
	_info_panel.add_child(card)
	_card_title = UiTheme.label("", "HeaderMedium")
	card.add_child(_card_title)
	_card_sub = UiTheme.label("", "MutedLabel")
	card.add_child(_card_sub)
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size = Vector2(376, 0)
	card.add_child(_info)
	_info_panel.visible = false
	add_child(_info_panel)

	# Controls, along the bottom edge.
	var help_bar := PanelContainer.new()
	help_bar.anchor_top = 1.0
	help_bar.anchor_bottom = 1.0
	help_bar.anchor_right = 1.0
	help_bar.offset_left = 8
	help_bar.offset_right = -8
	help_bar.offset_top = -38
	help_bar.offset_bottom = -6
	var help := UiTheme.label(HELP, "MutedLabel")
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_bar.add_child(help)
	add_child(help_bar)

	# Realm news, top right under the bar.
	var feed_panel := PanelContainer.new()
	feed_panel.anchor_left = 1.0
	feed_panel.anchor_right = 1.0
	feed_panel.position = Vector2(-468, 62)
	feed_panel.custom_minimum_size = Vector2(460, 0)
	var feed_box := VBoxContainer.new()
	feed_panel.add_child(feed_box)
	feed_box.add_child(UiTheme.label("Realm news", "HeaderSmall"))
	_feed = UiTheme.label("The realm is quiet... for now.", "MutedLabel")
	_feed.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feed.custom_minimum_size = Vector2(436, 0)
	feed_box.add_child(_feed)
	add_child(feed_panel)
	EventBus.sim_event.connect(_on_sim_event)

	# Short notices, centred under the bar; hidden when there is nothing to say.
	_notice_panel = PanelContainer.new()
	_notice_panel.anchor_left = 0.5
	_notice_panel.anchor_right = 0.5
	_notice_panel.offset_top = 62
	_notice_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_notice = UiTheme.label("", "NoticeLabel")
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_panel.add_child(_notice)
	_notice_panel.visible = false
	add_child(_notice_panel)


func _process(delta: float) -> void:
	_clock.text = "%s  ·  %s" % [GameState.continent, SimClock.time_string()]
	_speed.text = "Paused" if SimClock.is_paused() else "Speed ×%d" % SimClock.speed
	var p: Party = GameState.world.player if GameState.world else null
	if p:
		var hurt := Roster.size(p.wounded)
		_company.text = "%d troops%s   ·   %d gold%s   ·   %s" % [p.troops(), " (+%d wounded)" % hurt if hurt else "",
			p.gold, "   ·   %d prisoners" % p.prisoners if p.prisoners else "",
			"Sworn to the " + GameState.factions[p.faction]["name"] if p.faction != "" else "Free company"]
	if _notice_left > 0.0:
		_notice_left -= delta
		if _notice_left <= 0.0:
			_notice.text = ""
			_notice_panel.visible = false
	if _card_settlement != "" and _info_panel.visible:
		_card_refresh -= delta
		if _card_refresh <= 0.0:                     # owners, garrisons and sieges change while it is open
			show_settlement(_card_settlement)


func notify(text: String, seconds: float = 2.5) -> void:
	_notice.text = text
	_notice_left = seconds
	_notice_panel.visible = text != ""
	_notice_panel.reset_size()                       # shrink-wrap around the new text, still centred


func _card(title: String, sub: String, body: Array) -> void:
	_card_title.text = title
	_card_sub.text = sub
	_card_sub.visible = sub != ""
	_info.text = "\n".join(body)
	_info_panel.visible = true
	_info_panel.reset_size()


## Show a settlement card, or hide it when id is "".
func show_settlement(id: String, extra: String = "") -> void:
	_card_settlement = id
	_card_refresh = CARD_REFRESH_SECONDS
	if id == "":
		_info_panel.visible = false
		return
	var s: Dictionary = GameState.settlements[id]
	var w := GameState.world
	var owner_id: String = w.owner(id) if w else s["faction"]
	var f: Dictionary = GameState.factions[owner_id]
	var lines := [s["blurb"]]
	if owner_id != s["faction"]:
		lines.append("Taken from the %s." % GameState.factions[s["faction"]]["name"])
	if w and s["type"] != "village":
		var st: Dictionary = w.state[id]
		var holder: String = st["holder"]
		var who: String = "you" if holder == "player" else (GameState.personas[holder]["username"] if holder != "" else "the crown")
		lines.append("Held by %s. Garrison %d." % [who, Roster.size(st["garrison"])])
		if not st["siege"].is_empty():
			lines.append("UNDER SIEGE by the %s." % GameState.factions[st["siege"]["faction"]]["name"])
	if s.has("bound_to"):
		lines.append("Pays its dues to %s." % GameState.settlements[s["bound_to"]]["name"])
	lines.append("Terrain: %s" % GameState.terrain.terrain_name(s["cell"]))
	if extra != "":
		lines.append(extra)
	_card(s["name"], "%s of the %s" % [(s["type"] as String).capitalize(), f["name"]], lines)


## A card for a simulated party (lord, bandits or caravan).
func show_party(p: Party) -> void:
	_card_settlement = ""
	var lines: Array[String] = []
	var sub := ""
	if p.kind == "lord":
		var per: Dictionary = GameState.personas[p.persona_id]
		sub = "%s of the %s" % [per["archetype"].replace("_", " ").capitalize(), GameState.factions[p.faction]["name"]]
		lines.append("\"%s\"" % fill_names(per["catchphrases"][0]))
	elif p.kind == "caravan":
		sub = "Merchants under the %s's protection" % GameState.factions[p.faction]["name"] if GameState.factions.has(p.faction) else "Merchants"
	elif p.kind == "bandit":
		sub = "Outlaws"
	lines.append("%d troops (%s), morale %d" % [p.troops(), Roster.describe(p.roster), int(p.morale)])
	lines.append(_goal_text(p))
	_card(p.name, sub, lines)


## Persona lines may name the player ("{player}"); cards show them filled in, as chat does.
static func fill_names(text: String) -> String:
	var p: Party = GameState.world.player if GameState.world else null
	return text.format({"player": p.name if p and p.name != "" else "Wanderer"})


func _goal_text(p: Party) -> String:
	var fmt: String = GOAL_TEXT.get(p.goal, p.goal)
	if not fmt.contains("%s"):
		return fmt
	return fmt % _name_of(p.goal_target)


func _name_of(id: String) -> String:
	if GameState.settlements.has(id):
		return GameState.settlements[id]["name"]
	var w := GameState.world
	if w != null and w.by_id.has(id):
		return w.by_id[id].name
	return "someone"


func _on_sim_event(kind: String, data: Dictionary) -> void:
	var text := ""
	match kind:
		"battle":
			text = "%s beat %s" % [_name_of(data["winner"]), _name_of(data["loser"])]
		"village_raided":
			text = "%s raided %s" % [_name_of(data["party"]), _name_of(data["village"])]
		"party_defeated":
			text = "%s was routed by %s" % [_name_of(data["party"]), _name_of(data["by"])]
		"caravan_robbed":
			text = "%s robbed a caravan" % _name_of(data["by"])
		"lord_respawned":
			text = "%s is back in the field" % _name_of(data["party"])
		"war_declared":
			text = "WAR: the %s and the %s" % [GameState.factions[data["a"]]["name"], GameState.factions[data["b"]]["name"]]
		"peace_made":
			text = "Peace between the %s and the %s" % [GameState.factions[data["a"]]["name"], GameState.factions[data["b"]]["name"]]
		"fief_captured":
			text = "%s takes %s for the %s" % [_name_of(data["by"]), _name_of(data["fief"]), GameState.factions[data["faction"]]["name"]]
		"siege_failed":
			text = "The siege of %s is broken" % _name_of(data["fief"])
		"player_raided_village":
			text = "You raided %s" % _name_of(data["village"])
	if text == "":
		return
	_feed_lines.push_front("%s  %s" % [SimClock.time_string().get_slice(", ", 1), text])
	_feed_lines.resize(mini(_feed_lines.size(), FEED_SIZE))
	_feed.text = "\n".join(_feed_lines)
