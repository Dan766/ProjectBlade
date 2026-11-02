extends Node
## Game time. At 1x one game hour passes every SECONDS_PER_HOUR real seconds.
## Everything that moves on the map advances from `ticked`, so pausing stops the world.

signal ticked(hours: float)
signal speed_changed(speed: int)

const SECONDS_PER_HOUR := 1.0
const SPEEDS: Array[int] = [0, 1, 2, 4]

var hours: float = 8.0            # day 1, 08:00
var speed: int = 1
var _speed_before_pause: int = 1


func _process(delta: float) -> void:
	advance(delta)


## Advance by `real_seconds` of wall time; returns the game hours that passed.
func advance(real_seconds: float) -> float:
	var h := real_seconds / SECONDS_PER_HOUR * speed
	if h > 0.0:
		hours += h
		ticked.emit(h)
	return h


func set_speed(new_speed: int) -> void:
	speed = new_speed
	if new_speed > 0:
		_speed_before_pause = new_speed
	speed_changed.emit(speed)


func toggle_pause() -> void:
	set_speed(0 if speed > 0 else _speed_before_pause)


func is_paused() -> bool:
	return speed == 0


func day() -> int:
	return int(hours / 24.0) + 1


func time_string() -> String:
	return "Day %d, %02d:%02d" % [day(), int(hours) % 24, int(fmod(hours, 1.0) * 60.0)]
