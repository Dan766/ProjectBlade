class_name UiTheme
extends RefCounted
## The game's look for every screen (Phase G7), built from res://data/config/ui.json:
##   wood       HUD bars, cards, chat: dark wood panels, bronze edges, parchment-coloured text
##   parchment  dialogs (encounter, reputation, battle): parchment panels with ink text
## Fonts: Cinzel for titles, buttons and tabs; EB Garamond for body text and chat (OFL, see
## assets/CREDITS.md). apply() merges the wood theme into Godot's default theme, so every Control
## gets it, including those under CanvasLayers (a theme set on the root window does not reach them).
## Dialogs set `panel.theme = UiTheme.parchment()` on their root panel; it covers their children.
## Label variations: HeaderLarge/Medium/Small (titles), MutedLabel, NoticeLabel.

static var cfg: Dictionary = {}
static var _fonts: Dictionary = {}
static var _parchment: Theme


static func apply(c: Dictionary) -> void:
	cfg = c
	_fonts.clear()
	_parchment = null
	var t := build()
	var d := ThemeDB.get_default_theme()
	d.merge_with(t)
	d.default_font = t.default_font
	d.default_font_size = t.default_font_size


static func color(name: String) -> Color:
	return Color(cfg.get("colors", {}).get(name, "#ff00ff"))


static func size(name: String) -> int:
	return int(cfg.get("sizes", {}).get(name, 16))


static func font(kind: String) -> Font:
	if _fonts.has(kind):
		return _fonts[kind]
	var f: Dictionary = cfg.get("fonts", {})
	var base_path: String = f.get("display" if kind == "display" else ("italic" if kind == "italic" else "body"), "")
	var base: Font = load(base_path) if base_path != "" and ResourceLoader.exists(base_path) else ThemeDB.fallback_font
	var weight := float(f.get({"display": "display_weight", "bold": "bold_weight"}.get(kind, "body_weight"), 500))
	var v := FontVariation.new()
	v.base_font = base
	v.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	_fonts[kind] = v
	return v


## The wood theme (everything except dialog panels).
static func build() -> Theme:
	var t := Theme.new()
	t.default_font = font("body")
	t.default_font_size = size("body")
	var text := color("text")

	t.set_color("font_color", "Label", text)
	t.set_color("font_shadow_color", "Label", color("shadow"))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)
	_header(t, "HeaderLarge", size("h_large"), color("gold"))
	_header(t, "HeaderMedium", size("h_medium"), color("gold"))
	_header(t, "HeaderSmall", size("h_small"), color("text_muted"))
	t.set_type_variation("MutedLabel", "Label")
	t.set_color("font_color", "MutedLabel", color("text_muted"))
	t.set_font_size("font_size", "MutedLabel", size("small"))
	t.set_type_variation("NoticeLabel", "Label")
	t.set_color("font_color", "NoticeLabel", color("notice"))
	t.set_font("font", "NoticeLabel", font("display"))
	t.set_font_size("font_size", "NoticeLabel", size("h_small"))

	t.set_stylebox("panel", "PanelContainer", _box(color("wood_dark"), color("bronze"), 2, 4, Vector4(12, 8, 12, 8), true))
	t.set_stylebox("panel", "Panel", _box(color("wood_dark"), color("bronze"), 2, 4, Vector4(12, 8, 12, 8), true))

	t.set_font("font", "Button", font("display"))
	t.set_font_size("font_size", "Button", size("button"))
	t.set_stylebox("normal", "Button", _box(color("wood"), color("bronze"), 1, 3, Vector4(14, 6, 14, 6), false))
	t.set_stylebox("hover", "Button", _box(color("wood_light"), color("gold"), 1, 3, Vector4(14, 6, 14, 6), false))
	t.set_stylebox("pressed", "Button", _box(color("wood_dark"), color("gold"), 2, 3, Vector4(14, 7, 14, 5), false))
	t.set_stylebox("disabled", "Button", _box(color("wood").darkened(0.3), color("bronze").darkened(0.4), 1, 3, Vector4(14, 6, 14, 6), false))
	var focus := _box(Color(0, 0, 0, 0), color("gold"), 2, 3, Vector4.ZERO, false)
	focus.draw_center = false
	t.set_stylebox("focus", "Button", focus)
	t.set_color("font_color", "Button", text)
	t.set_color("font_hover_color", "Button", color("gold"))
	t.set_color("font_pressed_color", "Button", color("gold"))
	t.set_color("font_focus_color", "Button", text)
	t.set_color("font_disabled_color", "Button", color("text_muted").darkened(0.35))

	t.set_font("font", "TabContainer", font("display"))
	t.set_font_size("font_size", "TabContainer", size("tab"))
	t.set_stylebox("panel", "TabContainer", _box(color("wood_dark").darkened(0.15), color("bronze"), 1, 3, Vector4(8, 6, 8, 6), false))
	t.set_stylebox("tab_selected", "TabContainer", _tab(color("wood_light"), color("gold")))
	t.set_stylebox("tab_unselected", "TabContainer", _tab(color("wood"), color("bronze").darkened(0.3)))
	t.set_stylebox("tab_hovered", "TabContainer", _tab(color("wood_light"), color("bronze")))
	t.set_color("font_selected_color", "TabContainer", color("gold"))
	t.set_color("font_unselected_color", "TabContainer", color("text_muted"))
	t.set_color("font_hovered_color", "TabContainer", text)

	t.set_font("normal_font", "RichTextLabel", font("body"))
	t.set_font("italics_font", "RichTextLabel", font("italic"))
	t.set_font("bold_font", "RichTextLabel", font("bold"))
	for k in ["normal_font_size", "italics_font_size", "bold_font_size"]:
		t.set_font_size(k, "RichTextLabel", size("chat"))
	t.set_color("default_color", "RichTextLabel", text)

	for bar in ["VScrollBar", "HScrollBar"]:
		var track := _box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 4, Vector4(3, 3, 3, 3), false)
		t.set_stylebox("scroll", bar, track)
		t.set_stylebox("scroll_focus", bar, track)
		t.set_stylebox("grabber", bar, _box(color("bronze"), Color(0, 0, 0, 0), 0, 4, Vector4(4, 4, 4, 4), false))
		t.set_stylebox("grabber_highlight", bar, _box(color("gold"), Color(0, 0, 0, 0), 0, 4, Vector4(4, 4, 4, 4), false))
		t.set_stylebox("grabber_pressed", bar, _box(color("gold"), Color(0, 0, 0, 0), 0, 4, Vector4(4, 4, 4, 4), false))

	t.set_stylebox("panel", "TooltipPanel", _box(color("parchment"), color("parchment_edge"), 1, 3, Vector4(8, 5, 8, 5), true))
	t.set_color("font_color", "TooltipLabel", color("ink"))
	t.set_font("font", "TooltipLabel", font("body"))
	t.set_font_size("font_size", "TooltipLabel", size("small"))
	return t


## Dialog sub-theme: parchment panels and ink-coloured labels (buttons stay wood).
static func parchment() -> Theme:
	if _parchment != null:
		return _parchment
	var t := Theme.new()
	var p := _box(color("parchment"), color("parchment_edge"), 3, 6, Vector4(26, 20, 26, 20), true)
	p.shadow_size = 14
	t.set_stylebox("panel", "PanelContainer", p)
	t.set_color("font_color", "Label", color("ink"))
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	for v in ["HeaderLarge", "HeaderMedium"]:
		t.set_color("font_color", v, color("ink_title"))
		t.set_color("font_shadow_color", v, Color(0, 0, 0, 0))
	t.set_color("font_color", "HeaderSmall", color("ink_muted"))
	t.set_color("font_color", "MutedLabel", color("ink_muted"))
	t.set_color("font_shadow_color", "MutedLabel", Color(0, 0, 0, 0))
	t.set_color("default_color", "RichTextLabel", color("ink"))
	_parchment = t
	return t


## A label in one of the theme's variations.
static func label(text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l


## The dim backdrop behind modal dialogs.
static func dim_rect(view: Vector2) -> ColorRect:
	var dim := ColorRect.new()
	dim.color = color("dim")
	dim.size = view
	return dim


static func _header(t: Theme, variation: String, px: int, col: Color) -> void:
	t.set_type_variation(variation, "Label")
	t.set_font("font", variation, font("display"))
	t.set_font_size("font_size", variation, px)
	t.set_color("font_color", variation, col)


static func _box(bg: Color, edge: Color, border: int, radius: int, margins: Vector4, shadow: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(bg.r, bg.g, bg.b, bg.a * (float(cfg.get("panel_alpha", 0.93)) if shadow else 1.0))
	s.border_color = edge
	s.set_border_width_all(border)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margins.x
	s.content_margin_top = margins.y
	s.content_margin_right = margins.z
	s.content_margin_bottom = margins.w
	if shadow:
		s.shadow_color = Color(0, 0, 0, 0.45)
		s.shadow_size = 6
		s.shadow_offset = Vector2(0, 2)
	return s


static func _tab(bg: Color, edge: Color) -> StyleBoxFlat:
	var s := _box(bg, edge, 0, 3, Vector4(12, 5, 12, 5), false)
	s.border_width_top = 2
	s.corner_radius_bottom_left = 0
	s.corner_radius_bottom_right = 0
	return s
