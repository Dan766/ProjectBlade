class_name StrategyCamera
extends Node3D
## The 3D map's camera rig (Phase G3). It orbits a pivot on the ground: `zoom` 0 (nearest, flatter
## view) .. 1 (farthest, more top-down) sets both distance and pitch; `yaw` turns the view.
##   pan:    WASD / arrows, screen edges, middle-drag
##   zoom:   mouse wheel, toward the point under the cursor
##   rotate: Q / E, right-drag
## The pivot stays on the map. Tunables: "camera" in res://data/config/map3d.json.
## Pure math (target_transform, pan, rotate, zoom_toward) works without a viewport, for tests.

var camera: Camera3D
var map_size := Vector2(240, 150)
var ground: TerrainMesh                  # the pivot and the eye follow the surface
var pick: Callable                       # () -> Variant: world point under the mouse (Vector3) or null
var pivot := Vector2.ZERO                # world xz
var yaw := 0.0                           # radians; 0 = looking north (-z)
var zoom := 0.5
var edge_scroll := true
var cfg: Dictionary = {}
var _drag_pan := false
var _drag_rotate := false


func setup(size: Vector2, mesh: TerrainMesh, c: Dictionary) -> void:
	map_size = size
	ground = mesh
	cfg = c
	pivot = size * 0.5
	camera = Camera3D.new()
	camera.fov = float(cfg.get("fov", 50))
	camera.near = 0.1
	camera.far = 3000.0
	add_child(camera)
	camera.transform = target_transform()


func distance() -> float:
	var near := float(cfg.get("min_distance", 6))
	var far := float(cfg.get("max_distance", 190))
	return near * pow(far / near, zoom)                     # even steps feel even at every zoom


func pitch_degrees() -> float:
	return lerpf(float(cfg.get("pitch_near", 34)), float(cfg.get("pitch_far", 62)), zoom)


func focus_point() -> Vector3:
	var y := maxf(ground.height_at(pivot), 0.0) if ground else 0.0
	return Vector3(pivot.x, y, pivot.y)


## Where the camera should be for the current pivot, yaw and zoom.
func target_transform() -> Transform3D:
	var focus := focus_point()
	var p := deg_to_rad(pitch_degrees())
	var d := distance()
	var back := Vector3(sin(yaw), 0.0, cos(yaw))
	var eye := focus + back * cos(p) * d + Vector3.UP * sin(p) * d
	if ground:                                              # never dip into a mountainside
		eye.y = maxf(eye.y, maxf(ground.height_at(Vector2(eye.x, eye.z)), 0.0) + float(cfg.get("min_clearance", 1.0)))
	return Transform3D(Basis(), eye).looking_at(focus, Vector3.UP)


## The mouse ray through screen pixel `px` of a `size` viewport: [origin, direction], in world space.
## Same maths as Camera3D.project_ray_* (perspective, vertical fov), but usable outside the scene
## tree, so picking is testable headless. The rig itself sits at the world origin.
func screen_ray(px: Vector2, size: Vector2) -> Array:
	var xf := transform * camera.transform
	var tan_h := tan(deg_to_rad(camera.fov) * 0.5)
	var ndc := Vector2(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0)
	var local := Vector3(ndc.x * tan_h * size.x / size.y, ndc.y * tan_h, -1.0)
	return [xf.origin, (xf.basis * local).normalized()]


## Inverse of screen_ray: the pixel where world point `p` appears.
func world_to_screen(p: Vector3, size: Vector2) -> Vector2:
	var xf := transform * camera.transform
	var v := xf.basis.inverse() * (p - xf.origin)
	var tan_h := tan(deg_to_rad(camera.fov) * 0.5)
	var ndc := Vector2(v.x / -v.z / (tan_h * size.x / size.y), v.y / -v.z / tan_h)
	return Vector2((ndc.x + 1.0) * 0.5 * size.x, (1.0 - ndc.y) * 0.5 * size.y)


## Ground directions for the current yaw: forward = away from the camera, right = screen right.
func forward() -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


func right() -> Vector2:
	return Vector2(cos(yaw), -sin(yaw))


## dir in screen terms: x = right, y = down (W is y = -1). amount in world units.
func pan(dir: Vector2, amount: float) -> void:
	pivot += (right() * dir.x - forward() * dir.y) * amount
	_clamp()


func rotate_by(radians: float) -> void:
	yaw = wrapf(yaw + radians, -PI, PI)


## Change zoom by `step`; with a ground point, keep that point roughly under the cursor.
func zoom_toward(step: float, point = null) -> void:
	var old_d := distance()
	zoom = clampf(zoom + step, 0.0, 1.0)
	if point is Vector3:
		var p2 := Vector2(point.x, point.z)
		pivot = p2 + (pivot - p2) * (distance() / old_d)
	_clamp()


func look_at_world(xz: Vector2) -> void:
	pivot = xz
	_clamp()


func _clamp() -> void:
	pivot = pivot.clamp(Vector2.ZERO, map_size)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var step := float(cfg.get("zoom_step", 0.06))
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_toward(-step, pick.call() if pick.is_valid() else null)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_toward(step, pick.call() if pick.is_valid() else null)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag_pan = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag_rotate = mb.pressed
	elif event is InputEventMouseMotion:
		var rel := (event as InputEventMouseMotion).relative
		if _drag_pan:
			var per_px := 2.0 * distance() * tan(deg_to_rad(camera.fov) * 0.5) / maxf(get_viewport().get_visible_rect().size.y, 1.0)
			pan(-rel, per_px * float(cfg.get("drag_pan", 1.0)))
		elif _drag_rotate:
			rotate_by(-deg_to_rad(rel.x * float(cfg.get("drag_rotate", 0.3))))


func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1
	if edge_scroll and DisplayServer.window_is_focused() and not (_drag_pan or _drag_rotate):
		var m := get_viewport().get_mouse_position()
		var size := get_viewport().get_visible_rect().size
		var margin := float(cfg.get("edge_margin", 12))
		if m.x >= 0 and m.y >= 0 and m.x <= size.x and m.y <= size.y:
			if m.x < margin:
				dir.x -= 1
			elif m.x > size.x - margin:
				dir.x += 1
			if m.y < margin:
				dir.y -= 1
			elif m.y > size.y - margin:
				dir.y += 1
	if dir != Vector2.ZERO:
		pan(dir.normalized(), float(cfg.get("pan_speed", 1.1)) * distance() * delta)
	var turn := 0.0
	if Input.is_key_pressed(KEY_Q):
		turn += 1.0
	if Input.is_key_pressed(KEY_E):
		turn -= 1.0
	if turn != 0.0:
		rotate_by(deg_to_rad(float(cfg.get("rotate_speed", 90))) * turn * delta)
	# Ease toward the target so zoom and pan steps glide instead of jumping.
	var k := 1.0 - exp(-float(cfg.get("smoothing", 12)) * delta)
	camera.transform = camera.transform.interpolate_with(target_transform(), k)


## Jump straight to the target (no easing), e.g. after focus() or for screenshots.
func snap() -> void:
	camera.transform = target_transform()
