extends TestCase
## Game time: speeds, pausing, formatting.


func _clock() -> Node:
	return load("res://scripts/autoload/sim_clock.gd").new()


func test_speed_scales_time_and_pause_stops_it() -> void:
	var c := _clock()
	var start: float = c.hours
	c.set_speed(2)
	check_near(c.advance(1.5), 1.5 / c.SECONDS_PER_HOUR * 2.0, 1e-6, "2x speed doubles game time")
	c.set_speed(0)
	check_eq(c.advance(10.0), 0.0)
	check(c.is_paused(), "paused")
	check_near(c.hours - start, 1.5 / c.SECONDS_PER_HOUR * 2.0, 1e-6)
	c.free()


func test_toggle_pause_restores_previous_speed() -> void:
	var c := _clock()
	c.set_speed(4)
	c.toggle_pause()
	check_eq(c.speed, 0)
	c.toggle_pause()
	check_eq(c.speed, 4)
	c.free()


func test_time_string() -> void:
	var c := _clock()
	c.hours = 24.0 * 2 + 13.5
	check_eq(c.time_string(), "Day 3, 13:30")
	c.free()


func test_ticked_reports_hours() -> void:
	var c := _clock()
	var got := []
	c.ticked.connect(func(h): got.append(h))
	c.set_speed(1)
	c.advance(c.SECONDS_PER_HOUR * 2.0)
	check_eq(got.size(), 1)
	check_near(got[0], 2.0, 1e-6)
	c.free()
