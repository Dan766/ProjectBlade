extends Node
## Global signals between systems.
##
## sim_event(kind, data) relays everything World emits: battle, village_raided, trade,
## recruited, party_defeated, party_destroyed, lord_respawned, caravan_spawned, caravan_arrived,
## caravan_robbed, bandits_spawned, desertion. `data` holds party / settlement ids and "time".
## Phase 4's ChatDirector maps these (plus player actions from Phases 3 and 5) onto the dialogue
## taxonomy in res://data/generated/events.json; see docs/PLAN.md, "Sim events -> dialogue events".

signal settlement_selected(settlement_id: String)
signal settlement_hovered(settlement_id: String)
signal party_arrived(party_id: String, cell: Vector2i)
signal sim_event(kind: String, data: Dictionary)
