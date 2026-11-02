class_name TestCase
extends RefCounted
## Base class for tests run by res://tests/run_tests.gd. Methods named test_* are run in turn;
## failed checks are recorded (GDScript has no exceptions, so a check never stops a test).

var failures: PackedStringArray = []
var current := ""


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append("%s: %s" % [current, message])


func check_eq(actual, expected, message: String = "") -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s %s" % [current, str(expected), str(actual), message])


func check_near(actual: float, expected: float, tolerance: float, message: String = "") -> void:
	if absf(actual - expected) > tolerance:
		failures.append("%s: expected %.3f +- %.3f, got %.3f %s" % [current, expected, tolerance, actual, message])


## Called once after all of a suite's tests; free nodes the suite created here.
func cleanup() -> void:
	pass
