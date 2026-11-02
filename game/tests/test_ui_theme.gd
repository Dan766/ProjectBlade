extends TestCase
## Phase G7: the UI theme (UiTheme + data/config/ui.json). Screens are reviewed by screenshot
## (docs/screenshots/g7/); this checks the parts a screenshot can't prove.

func _cfg() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/config/ui.json"))


## WCAG relative luminance contrast between two sRGB colours.
static func _contrast(a: Color, b: Color) -> float:
	var la := 0.2126 * _lin(a.r) + 0.7152 * _lin(a.g) + 0.0722 * _lin(a.b)
	var lb := 0.2126 * _lin(b.r) + 0.7152 * _lin(b.g) + 0.0722 * _lin(b.b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)


func test_bundled_fonts_load_and_are_credited() -> void:
	UiTheme.apply(_cfg())
	var credits := FileAccess.get_file_as_string("res://assets/CREDITS.md")
	for kind in ["body", "italic", "display"]:
		var path: String = _cfg()["fonts"][kind]
		check(ResourceLoader.exists(path), "%s font present: %s" % [kind, path])
		var f := UiTheme.font(kind) as FontVariation
		check(f != null and f.base_font != ThemeDB.fallback_font, "%s font is the bundled one, not the fallback" % kind)
		check(credits.contains(path.get_file()), "%s listed in assets/CREDITS.md" % path.get_file())
		check(FileAccess.file_exists(path.get_base_dir() + "/" + ("Cinzel" if kind == "display" else "EBGaramond") + "-OFL.txt"),
			"licence text ships next to %s" % path.get_file())


func test_apply_reaches_every_control() -> void:
	UiTheme.apply(_cfg())
	var d := ThemeDB.get_default_theme()
	var panel := d.get_stylebox("panel", "PanelContainer") as StyleBoxFlat
	check(panel != null and panel.bg_color.is_equal_approx(Color(UiTheme.color("wood_dark"), panel.bg_color.a)), "wood panels")
	check_eq(d.get_color("font_color", "Label"), UiTheme.color("text"))
	check_eq(d.get_font("font", "HeaderLarge"), UiTheme.font("display"), "titles in the display font")
	check_eq(d.default_font_size, UiTheme.size("body"))
	var l := Label.new()                                  # a bare Label, no theme of its own
	check_eq(l.get_theme_color("font_color"), UiTheme.color("text"), "a plain Label picks the theme up")
	l.free()


## The sub-theme's own values. (Propagation to a dialog's children only happens inside the scene
## tree, which these headless tests are not; the dialog screenshots show ink on parchment.)
func test_parchment_dialogs_use_ink() -> void:
	UiTheme.apply(_cfg())
	var p := UiTheme.parchment()
	check_eq((p.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color.to_html(false), UiTheme.color("parchment").to_html(false))
	check_eq(p.get_color("font_color", "Label"), UiTheme.color("ink"), "labels are ink")
	check_eq(p.get_color("font_color", "HeaderLarge"), UiTheme.color("ink_title"))
	check(not p.has_stylebox("normal", "Button"), "buttons are left to the wood theme")


func test_text_is_readable_on_both_looks() -> void:
	UiTheme.apply(_cfg())
	var pairs := {
		"body on wood": [UiTheme.color("text"), UiTheme.color("wood_dark")],
		"muted on wood": [UiTheme.color("text_muted"), UiTheme.color("wood_dark")],
		"titles on wood": [UiTheme.color("gold"), UiTheme.color("wood_dark")],
		"button text": [UiTheme.color("text"), UiTheme.color("wood")],
		"ink on parchment": [UiTheme.color("ink"), UiTheme.color("parchment")],
		"muted ink on parchment": [UiTheme.color("ink_muted"), UiTheme.color("parchment")],
		"titles on parchment": [UiTheme.color("ink_title"), UiTheme.color("parchment")],
		"friends on parchment": [UiTheme.color("good"), UiTheme.color("parchment")],
		"enemies on parchment": [UiTheme.color("bad"), UiTheme.color("parchment")],
	}
	for name in pairs:
		var ratio := _contrast(pairs[name][0], pairs[name][1])
		check(ratio >= 4.5, "%s contrast %.1f (WCAG AA needs 4.5)" % [name, ratio])


func test_persona_lines_name_the_player() -> void:
	check_eq("Sit down, {player}. The road will wait.".format({"player": "Wanderer"}), "Sit down, Wanderer. The road will wait.")
	check(Hud.fill_names("Hello {player}") != "Hello {player}", "Hud.fill_names fills {player}")
