class_name AutoResolve
extends RefCounted
## Off-screen battles (AI vs AI, or the player choosing to auto-resolve): the full Phase 3
## Battle, with both sides' commands chosen by their AI, then its aftermath applied.


## Returns Battle.finish(): {winner, loser, routed, fled, withdrew, rounds, loot, prisoners,
## winner_lost, loser_lost, losses, captured, terrain}. Mutates both parties.
static func resolve(a: Party, b: Party, role_a: String, role_b: String, terrain: String, rules: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var battle := Battle.new(a, b, role_a, role_b, terrain, rules, rng)
	battle.auto_play()
	return battle.finish()
