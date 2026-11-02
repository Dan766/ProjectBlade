class_name LabelOverlay
extends Control
## Settlement names (and, when zoomed out, owner-coloured icons) drawn as crisp 2D text over the 3D
## map (Phase G5): each settlement is projected through the camera. Level of detail is in zoom-level
## units (MapView3D.zoom_level(): 0.2 farthest .. 3.0 nearest): villages and minor names appear as you
## zoom in. Icons hide when the models are big enough to read.
## Redraws only when something it shows can have changed (camera, hover/selection, party names on
## screen) and a few times a second for owner colours and sieges: redrawing every frame cost ~1.6 ms.

const REFRESH_SECONDS := 0.25
const ICON_PX := {"town": 7.0, "castle": 5.0, "village": 2.5}           # icon half-size, screen px
const FONT_PX := {"town": 15, "castle": 12, "village": 11}
const SHOW_ICON_AT := {"town": 0.0, "castle": 0.0, "village": 0.32}     # minimum zoom level
const SHOW_LABEL_AT := {"town": 0.0, "castle": 0.55, "village": 1.3}

var view                              # MapView3D: zoom_level(), rig, settlements
var hovered := ""
var selected := ""
var icon_hide_at := 1.2
var lord_name_zoom := 1.4
var _last_cam := Transform3D()
var _last_marks := ""
var _since := 0.0
var _by_kind: Dictionary = {}         # kind -> [[id, top: Vector3, name]], built once
var _settlement_cells: Dictionary = {}   # Vector2i -> true, built once


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if view == null or view.models == null:
		return
	_since += delta
	var cam: Transform3D = view.rig.camera.global_transform
	var marks: String = "%s|%s|%s" % [hovered, selected, view.hovered_party_id()]
	var names_move: bool = view.zoom_level() >= lord_name_zoom or view.hovered_party_id() != ""
	if names_move or _since >= REFRESH_SECONDS or marks != _last_marks or not cam.is_equal_approx(_last_cam):
		_since = 0.0
		_last_cam = cam
		_last_marks = marks
		queue_redraw()


var draw_usec_total := 0              # profiling (printed by campaign_map automation)
var draw_calls := 0


func _draw() -> void:
	if view == null or view.models == null:
		return
	var t0 := Time.get_ticks_usec()
	_draw_all()
	draw_usec_total += Time.get_ticks_usec() - t0
	draw_calls += 1


func _draw_all() -> void:
	var cam: Camera3D = view.rig.camera
	var z: float = view.zoom_level()
	var font := UiTheme.font("display")                  # Cinzel for places (G7)
	var models: Settlements3D = view.models
	var screen := get_viewport_rect().size
	if _by_kind.is_empty():
		for kind in ["village", "castle", "town"]:
			_by_kind[kind] = []
		for id in models.info:
			var i: Dictionary = models.info[id]
			_by_kind[i["type"]].append([id, i["pos"] + Vector3(0, i["top"], 0), GameState.settlements[id]["name"]])
	for kind in ["village", "castle", "town"]:            # towns drawn last, on top
		var show_icon: bool = z >= SHOW_ICON_AT[kind] and z < icon_hide_at
		var label_all: bool = z >= SHOW_LABEL_AT[kind]
		if not (show_icon or label_all or hovered != "" or selected != ""):
			continue
		for entry in _by_kind[kind]:
			var id: String = entry[0]
			var marked: bool = id == hovered or id == selected
			var labelled: bool = label_all or marked
			if not (show_icon or labelled):
				continue
			var top: Vector3 = entry[1]                          # just above the flags
			if cam.is_position_behind(top):
				continue
			var p := cam.unproject_position(top)
			if p.x < -100 or p.y < -40 or p.x > screen.x + 100 or p.y > screen.y + 40:
				continue
			var r: float = ICON_PX[kind]
			if show_icon:
				_icon(p, kind, r, models.drawn_color(id), marked, models.sieges.has(id))
			if labelled:
				_label(font, p + Vector2(0, -(r + 4.0) if show_icon else 0.0), entry[2], FONT_PX[kind], marked)
	_party_names(cam, z, UiTheme.font("bold"), screen)


## Lord names when zoomed in, and whichever party is hovered. Lords waiting inside a settlement get
## no name (several at home would print on top of each other); hovering one still shows it.
func _party_names(cam: Camera3D, z: float, font: Font, screen: Vector2) -> void:
	if view.parties == null:
		return
	var hovered_party: String = view.hovered_party_id()
	var lift: float = 0.3 * view.parties.scale_for(view.rig.distance())
	if _settlement_cells.is_empty():                     # O(1) "is this lord at home" check
		for id in GameState.settlements:
			_settlement_cells[GameState.settlements[id]["cell"]] = true
	var terrain: TerrainMap = GameState.terrain
	for entry in view.parties.shown:
		var p: Party = entry[0]
		var marked := p.id == hovered_party
		if not (marked or (p.kind == "lord" and z >= lord_name_zoom)):
			continue
		if not marked and _settlement_cells.has(terrain.world_to_cell(p.position)):
			continue
		var top: Vector3 = entry[1] + Vector3(0, lift, 0)
		if cam.is_position_behind(top):
			continue
		var at := cam.unproject_position(top)
		if at.x < -100 or at.y < -40 or at.x > screen.x + 100 or at.y > screen.y + 40:
			continue
		_label(font, at, p.name, 14, marked)


func _icon(p: Vector2, kind: String, r: float, fill: Color, marked: bool, besieged: bool) -> void:
	var edge := Color.WHITE if marked else Color(0.08, 0.08, 0.08)
	match kind:
		"town":
			draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2), fill)
			draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2), edge, false, 1.5)
		"castle":
			var d := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
			draw_colored_polygon(d, fill)
			d.append(d[0])
			draw_polyline(d, edge, 1.5)
		_:
			draw_circle(p, r, fill.lightened(0.35))
	if besieged:
		draw_arc(p, r + 8.0, 0, TAU, 24, Color("#ff4a3a"), 2.5)


func _label(font: Font, at: Vector2, text: String, size: int, marked: bool) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var pos := at - Vector2(w * 0.5, 0)
	draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.85))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(1, 1, 0.75) if marked else Color(1, 1, 0.95))
