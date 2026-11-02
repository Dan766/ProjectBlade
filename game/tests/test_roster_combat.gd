extends TestCase
## Troop rosters and the Phase 2 stand-in battle resolver.

const POWER := [1.0, 1.8, 3.0]


func _rng(seed: int = 7) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func test_make_size_mix_and_strength() -> void:
	var r := Roster.make(1000, [0.5, 0.5, 0.0], [1.0, 0.0, 0.0], _rng())
	check_eq(Roster.size(r), 1000)
	check_eq(r["cavalry"], [0, 0, 0], "no cavalry when its share is 0")
	check(absi(r["infantry"][0] - 500) < 80, "about half infantry: %d" % r["infantry"][0])
	var s := Roster.empty()
	Roster.add(s, "archers", 2, 2)
	Roster.add(s, "infantry", 0, 3)
	check_near(Roster.strength(s, POWER), 3.0 + 6.0, 1e-6)


func test_remove_fraction_and_train_keep_counts_sane() -> void:
	var rng := _rng()
	var r := Roster.make(200, [0.4, 0.3, 0.3], [0.6, 0.3, 0.1], rng)
	var removed := Roster.remove_fraction(r, 0.25, rng)
	check(removed > 30 and removed < 70, "about a quarter removed: %d" % removed)
	check_eq(Roster.size(r), 200 - removed)
	var before := Roster.size(r)
	Roster.train(r, 0.5, 0.5, rng)
	check_eq(Roster.size(r), before, "training moves troops between tiers, never adds or removes")
	check_eq(Roster.remove_fraction(r, 1.0, rng), before)
	check_eq(Roster.size(r), 0)


## The Phase 2 stand-in was replaced by Battle in Phase 3: these are now covered in test_battle.gd.
