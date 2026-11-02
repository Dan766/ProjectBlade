class_name MapView3D
extends Node3D
## The 3D campaign map as a view behind campaign_map.gd (Phase G3): Map3DView (terrain, sea, sky),
## a StrategyCamera, mouse picking on the terrain, settlement models (G5) with projected labels, every
## party (G6) with the player's route, and hover and selection rings. campaign_map.gd talks to it in
## sim world pixels (1 cell = cell_size px = 1 unit).

const ZOOM_LEVEL_MIN := 0.2                  # zoom level (as --zoom and the label rules use it), mapped onto StrategyCamera.zoom
const ZOOM_LEVEL_MAX := 3.0
const PARTY_HOVER_PX := 16.0              # pointer within this many pixels of a banner hovers it

var terrain: TerrainMap
var world: World
var player: Party
var map: Map3DView
var rig: StrategyCamera
var models: Settlements3D
var parties: Parties3D
var labels: LabelOverlay
var _cell_size := 16.0
var _player_ring: MeshInstance3D
var _route: MeshInstance3D
var _route_mesh: ImmediateMesh
var _hover_ring: MeshInstance3D
var _select_ring: MeshInstance3D
var _party_ring: MeshInstance3D
var _refresh_every := 0.5
var _refresh_in := 0.0
var _hovered := ""
var _selected := ""
var _hovered_party := ""
var _pick_frame := -1
var _pick_mouse := Vector2(-1, -1)
var _pick_hit = null
var mouse_override = null                 # Vector2 screen pixel for automation (--click), else null


func setup(t: TerrainMap, w: World, p: Party) -> void:
	terrain = t
	world = w
	player = p
	_cell_size = float(t.cell_size)
	var colors := {}
	for f in GameState.factions:
		colors[f] = GameState.faction_color(f)
	map = Map3DView.new()
	add_child(map)
	map.setup(t, colors, GameState.map3d_config, settlement_cells())

	rig = StrategyCamera.new()
	add_child(rig)
	rig.setup(Vector2(t.width, t.height), map.terrain_mesh, GameState.map3d_config.get("camera", {}))
	rig.pick = func(): return _pick()
	rig.camera.make_current()

	parties = Parties3D.new()
	parties.name = "Parties"
	add_child(parties)
	parties.setup(w, map.terrain_mesh, _cell_size, colors, GameState.map3d_config.get("parties", {}))
	_player_ring = _make_ring(Color("#e8c45a"))         # always under the player's party
	_player_ring.visible = true
	_route_mesh = ImmediateMesh.new()
	_route = MeshInstance3D.new()
	_route.mesh = _route_mesh
	_route.material_override = _overlay_material(Color(1, 1, 1, 0.75))
	_route.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_route)
	_hover_ring = _make_ring(Color(1, 0.95, 0.7, 0.9))
	_select_ring = _make_ring(Color(1, 1, 1, 1))
	_party_ring = _make_ring(Color(1, 0.95, 0.7, 0.9))

	var scfg: Dictionary = GameState.map3d_config.get("settlements", {})
	models = Settlements3D.new()
	models.name = "Settlements"
	add_child(models)
	models.setup(map.terrain_mesh, settlement_cells(), colors, scfg)
	_refresh_every = float(scfg.get("refresh_seconds", 0.5))
	_refresh_models()
	var layer := CanvasLayer.new()
	layer.layer = 0                                      # under the HUD (layer 1)
	add_child(layer)
	labels = LabelOverlay.new()
	labels.view = self
	labels.icon_hide_at = float(scfg.get("icon_hide_at", 1.2))
	labels.lord_name_zoom = float(GameState.map3d_config.get("parties", {}).get("lord_name_zoom", 1.4))
	layer.add_child(labels)


## [{id, cell, type, culture}] for every settlement; culture = the realm that founded it.
static func settlement_cells() -> Array:
	var out := []
	for id in GameState.settlements:
		var s: Dictionary = GameState.settlements[id]
		out.append({"id": id, "cell": s["cell"], "type": s["type"], "culture": s["faction"]})
	return out


## Current owners and sieges from the simulation -> model colours and siege camps.
func _refresh_models() -> void:
	var owners := {}
	var sieges := {}
	for id in models.info:
		owners[id] = world.owner(id) if world else GameState.settlements[id]["faction"]
		if world and world.state.has(id) and world.state[id].has("siege") and not world.state[id]["siege"].is_empty():
			sieges[id] = world.state[id]["siege"]["faction"]
	models.refresh(owners, sieges)


# --- the view interface used by campaign_map.gd -----------------------------------------

func pointer_world() -> Variant:
	var hit = _pick()
	return Vector2(hit.x, hit.z) * _cell_size if hit != null else null


## 12 screen pixels at the picked point, in sim pixels.
func hover_radius() -> float:
	var hit = _pick()
	var d := rig.camera.global_position.distance_to(hit) if hit != null else rig.distance()
	var per_px := 2.0 * d * tan(deg_to_rad(rig.camera.fov) * 0.5) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
	return 12.0 * per_px * _cell_size


func visible_types() -> Array:
	var z := zoom_level()
	return LabelOverlay.SHOW_ICON_AT.keys().filter(func(k): return z >= LabelOverlay.SHOW_ICON_AT[k])


func set_highlight(hovered: String, selected: String) -> void:
	_hovered = hovered
	_selected = selected
	if labels:
		labels.hovered = hovered
		labels.selected = selected


## The party whose banner is drawn nearest the mouse (within PARTY_HOVER_PX on screen). Banners
## stand above the ground, so the ground point under the pointer (`_pos`) would miss them.
func party_near(_pos: Vector2, _radius: float) -> Party:
	var mouse: Vector2 = mouse_override if mouse_override != null else get_viewport().get_mouse_position()
	return nearest_on_screen(parties.shown, mouse, func(p: Vector3): return rig.camera.unproject_position(p),
		func(p: Vector3): return rig.camera.is_position_behind(p))


## [[Party, anchor]] -> the Party whose projected anchor is within PARTY_HOVER_PX of `mouse`, or null.
static func nearest_on_screen(shown: Array, mouse: Vector2, project: Callable, behind: Callable) -> Party:
	var best: Party = null
	var best_d := PARTY_HOVER_PX * PARTY_HOVER_PX
	for entry in shown:
		var anchor: Vector3 = entry[1]
		if behind.call(anchor):
			continue
		var d: float = (project.call(anchor) as Vector2).distance_squared_to(mouse)
		if d <= best_d:
			best_d = d
			best = entry[0]
	return best


func set_hovered_party(id: String) -> void:
	_hovered_party = id


func hovered_party_id() -> String:
	return _hovered_party


func focus(pos: Vector2) -> void:
	rig.look_at_world(pos / _cell_size)
	rig.snap()


## Zoom level: 0.2 farthest .. 3.0 nearest (the unit of --zoom and LabelOverlay's level of detail).
func set_zoom_level(z: float) -> void:
	rig.zoom = rig_zoom_for_level(z)
	rig.snap()


func zoom_level() -> float:
	return level_for_rig_zoom(rig.zoom)


## Zoom level (log scale, bigger = nearer) <-> StrategyCamera.zoom (0 nearest .. 1 farthest).
static func rig_zoom_for_level(z: float) -> float:
	return 1.0 - inverse_lerp(log(ZOOM_LEVEL_MIN), log(ZOOM_LEVEL_MAX), log(clampf(z, ZOOM_LEVEL_MIN, ZOOM_LEVEL_MAX)))


static func level_for_rig_zoom(t: float) -> float:
	return exp(lerpf(log(ZOOM_LEVEL_MIN), log(ZOOM_LEVEL_MAX), 1.0 - t))


func set_edge_scroll(on: bool) -> void:
	rig.edge_scroll = on


# --- per frame ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var k := clampf(rig.distance() / 30.0, 0.35, 5.0)      # route and rings keep a readable screen size
	var pk := parties.scale_for(rig.distance())            # party models likewise
	parties.sync(pk, delta)
	_player_ring.position = to_3d(player.position) + Vector3.UP * 0.03
	_player_ring.scale = Vector3.ONE * pk * 0.45
	_draw_route(k)
	_place_ring(_hover_ring, _hovered if _hovered != _selected else "", k)
	_place_ring(_select_ring, _selected, k * 1.15)
	var hp: Party = world.by_id.get(_hovered_party) if _hovered_party != "" else null
	_party_ring.visible = hp != null
	if hp:
		_party_ring.position = to_3d(hp.position) + Vector3.UP * 0.03
		_party_ring.scale = Vector3.ONE * pk * 0.45
	_refresh_in -= delta
	if _refresh_in <= 0.0:                             # owner colours update within refresh_seconds
		_refresh_in = _refresh_every
		_refresh_models()


## Sim pixels -> a point on the 3D surface (or the sea surface).
func to_3d(sim_pos: Vector2) -> Vector3:
	var xz := sim_pos / _cell_size
	return Vector3(xz.x, maxf(map.terrain_mesh.height_at(xz), 0.0), xz.y)


func _pick() -> Variant:
	var mouse: Vector2 = mouse_override if mouse_override != null else get_viewport().get_mouse_position()
	if _pick_frame == Engine.get_process_frames() and mouse == _pick_mouse:
		return _pick_hit
	_pick_frame = Engine.get_process_frames()
	_pick_mouse = mouse
	var ray := rig.screen_ray(mouse, get_viewport().get_visible_rect().size)
	_pick_hit = map.terrain_mesh.raycast(ray[0], ray[1])
	return _pick_hit


func _draw_route(k: float) -> void:
	_route_mesh.clear_surfaces()
	if not player.is_moving():
		return
	var pts := player.route_points(terrain)
	if pts.size() < 2:
		return
	var half := 0.12 * k
	_route_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in pts.size():
		var a := pts[maxi(i - 1, 0)] / _cell_size
		var b := pts[mini(i + 1, pts.size() - 1)] / _cell_size
		var tangent := (b - a).normalized()
		var side := Vector3(-tangent.y, 0.0, tangent.x) * half
		var p := to_3d(pts[i]) + Vector3.UP * 0.05
		_route_mesh.surface_add_vertex(p - side)
		_route_mesh.surface_add_vertex(p + side)
	_route_mesh.surface_end()


func _place_ring(ring: MeshInstance3D, id: String, k: float) -> void:
	ring.visible = id != "" and models.info.has(id)
	if ring.visible:
		var i: Dictionary = models.info[id]
		ring.position = i["pos"] + Vector3.UP * 0.05
		ring.scale = Vector3.ONE * maxf(k, float(i["radius"]) * 1.2 / 0.68)   # around the walls, not inside


# --- rings ---------------------------------------------------------------------------------

func _make_ring(color: Color) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.655
	torus.outer_radius = 0.68
	color.a *= 0.8
	ring.mesh = torus
	ring.material_override = _overlay_material(color)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	add_child(ring)
	return ring


## Unshaded, drawn on top of the terrain: routes and rings stay visible behind hills.
static func _overlay_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
