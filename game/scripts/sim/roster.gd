class_name Roster
extends RefCounted
## A party's troops: {"infantry": [t1, t2, t3], "archers": [...], "cavalry": [...]} as counts.
## Static helpers only; rosters stay plain dictionaries so saving them is trivial.

const TYPES: Array[String] = ["infantry", "archers", "cavalry"]


static func empty() -> Dictionary:
	return {"infantry": [0, 0, 0], "archers": [0, 0, 0], "cavalry": [0, 0, 0]}


## `total` troops split by `mix` ([inf, arch, cav] shares) and `tiers` ([t1, t2, t3] shares).
static func make(total: int, mix: Array, tiers: Array, rng: RandomNumberGenerator) -> Dictionary:
	var r := empty()
	for i in total:
		add(r, TYPES[_pick(mix, rng)], _pick(tiers, rng), 1)
	return r


static func add(r: Dictionary, type: String, tier: int, n: int) -> void:
	r[type][tier] = max(0, r[type][tier] + n)


static func size(r: Dictionary) -> int:
	var n := 0
	for t in TYPES:
		for c in r[t]:
			n += c
	return n


static func strength(r: Dictionary, tier_power: Array) -> float:
	var s := 0.0
	for t in TYPES:
		for tier in 3:
			s += r[t][tier] * float(tier_power[tier])
	return s


## Remove about `fraction` of every stack (rounded randomly so small stacks still take losses).
## Returns how many troops were removed.
static func remove_fraction(r: Dictionary, fraction: float, rng: RandomNumberGenerator) -> int:
	var removed := 0
	fraction = clampf(fraction, 0.0, 1.0)
	for t in TYPES:
		for tier in 3:
			var exact: float = r[t][tier] * fraction
			var n := int(exact) + (1 if rng.randf() < exact - int(exact) else 0)
			n = min(n, r[t][tier])
			r[t][tier] -= n
			removed += n
	return removed


## Daily drill: a share of tier-1 troops become tier 2, a share of tier 2 become tier 3.
static func train(r: Dictionary, t1_to_t2: float, t2_to_t3: float, rng: RandomNumberGenerator) -> void:
	for t in TYPES:
		var up2 := _binomial(r[t][1], t2_to_t3, rng)
		var up1 := _binomial(r[t][0], t1_to_t2, rng)
		r[t][1] += up1 - up2
		r[t][2] += up2
		r[t][0] -= up1


## Move about `fraction` of each wounded stack back into the fighting roster.
static func heal(r: Dictionary, wounded: Dictionary, fraction: float, rng: RandomNumberGenerator) -> void:
	for t in TYPES:
		for tier in 3:
			var n := _binomial(wounded[t][tier], fraction, rng)
			wounded[t][tier] -= n
			r[t][tier] += n


static func describe(r: Dictionary) -> String:
	var parts := []
	for t in TYPES:
		var n: int = r[t][0] + r[t][1] + r[t][2]
		if n > 0:
			parts.append("%d %s" % [n, t])
	return ", ".join(parts) if parts else "no troops"


static func _pick(weights: Array, rng: RandomNumberGenerator) -> int:
	var x: float = rng.randf() * float(weights.reduce(func(a, b): return a + b, 0.0))
	for i in weights.size():
		x -= weights[i]
		if x <= 0.0:
			return i
	return weights.size() - 1


static func _binomial(n: int, p: float, rng: RandomNumberGenerator) -> int:
	var k := 0
	for i in n:
		if rng.randf() < p:
			k += 1
	return k
