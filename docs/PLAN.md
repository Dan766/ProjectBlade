# Implementation Plan

## 1. Vision
A pausable real-time campaign map spanning a whole continent. The player leads a war party, recruits,
fights simplified round-based battles, takes fiefs and joins factions. Around them, ~120 "players"
(AI lords) behave and *talk* like people on a live multiplayer server: global chat, whispers, rivalries,
grudges that escalate, alliances, drama. All dialogue is pre-generated (Phase 0) and selected at runtime.

**Design pillar:** fake players must be backed by real map behaviour. A persona who brags about raiding
must actually raid. Archetype drives both AI weights and dialogue.

## 2. Scope: "full continent"
| Item | Target |
|---|---|
| Factions | 6 (each with its own culture, naming style, troop tree flavour) |
| Towns / castles / villages | ~24 / ~40 / ~100 |
| Persona lords ("fake players") | ~120 (~20 per faction) |
| Other parties | Bandits, caravans, villager parties (no persona, no dialogue) |
| Troop types | Infantry / Archers / Cavalry, 3 tiers, per-culture names |
| Map | One large 3D campaign map (Phase G) over a coarse terrain grid for pathfinding |

## 3. Tech stack
- **Godot 4.x stable, GDScript.** Verify the installed version with `godot --version` and record it in
  the Decision Log. Use static typing in GDScript.
- **Tests:** in-house headless runner (`game/tests/run_tests.gd`) via `tools/godot.sh test` (GUT was dropped to avoid an addon download).
- **Pipeline:** Python 3.11+ (stdlib `tomllib`, `json`, `concurrent.futures`, `subprocess`) plus
  `jsonschema`. Calls the `claude` CLI with the Haiku model.
- **Data:** the pipeline outputs JSON into `game/data/`. Godot loads it at startup.

## 4. Godot architecture
**Simulation is data, not nodes.** Parties, settlements and factions are plain `RefCounted` / `Resource`
objects in `GameState`. Nodes only render what is visible. This keeps 300+ parties cheap and makes
saves trivial.

Autoloads (singletons):
| Autoload | Responsibility |
|---|---|
| `GameState` | All world data: factions, settlements, parties, persona memory, player |
| `SimClock` | Game time, pause/speed (0x/1x/2x/4x), emits `tick(hours)` |
| `EventBus` | Typed signals for world events (`battle_ended`, `siege_started`, `war_declared`, ...) |
| `DialogueDB` | Loads `game/data/dialogue/**`, indexes pools, picks lines, fills placeholders |
| `ChatDirector` | Listens to EventBus, decides who speaks, when, on which channel; schedules messages |
| `SaveSystem` | Serialises GameState to JSON in `user://saves/` |

Scenes:
`Main` → `CampaignMap` (map render, camera, party sprites, settlement icons, input) ·
`BattleScreen` (round-based UI) · `SettlementMenu` (recruit, trade, siege) · `ChatPanel` (global feed,
whisper tabs) · `EncounterDialog` (face-to-face) · `ReputationScreen` (who likes or hates you, and why).

## 5. Phases

Each phase lists milestones with acceptance criteria. Detailed specs live in `docs/specs/`.

### Phase 0: Content pipeline (FIRST) → `docs/specs/pipeline.md`
Builds world names and lore, personas, dialogue pools, signature lines and scripted conversations
with Haiku, then validates, dedupes and bundles them into `game/data/`.
**Done when:** `python -m pipeline all` completes from a clean state, `validate` reports 0 errors,
the `report` command shows every (archetype × event × relationship × channel) cell meets its minimum
variant count, and a human has reviewed `sample` output for every archetype.

### Phase 1: Godot skeleton and continent map
- 1.1 Godot project in `game/`, autoload stubs, GUT installed, a headless test runs.
- 1.2 Continent map: terrain image plus a coarse terrain-cost grid (`AStarGrid2D`). Settlement layout
  in `game/data/world/layout.json` (id, type, position, faction). Names come from the pipeline output
  by id.
- 1.3 Camera pan, zoom and edge-scroll. Settlement icons and labels with level-of-detail hiding.
- 1.4 Player party: click to move, pathfinding, speed by terrain, time controls.
**Accept:** you can cross the continent; pausing works; 60 fps at full zoom-out with all settlements.

### Phase 2: World simulation
- 2.1 Party model: roster (troop type × tier × count), gold, food, morale, speed.
- 2.2 Party AI (utility-based): patrol, raid, besiege, defend, trade, chase, flee, recruit. **Archetype
  weights** come from `personas.json` (griefer → raid/chase, trader → caravan routes, newbie → flee
  often, and so on).
- 2.3 Economy-lite: village → town production, prosperity, garrisons, recruitment pools.
- 2.4 Bandits and caravans spawning.
- 2.5 EventBus emits every world event in the taxonomy (see the pipeline spec, Event Taxonomy).
**Accept:** a 30-day headless sim with 120 lords runs without errors; event counts are logged; no party
gets stuck (stuck detector test).

#### Sim events → dialogue events (for Phase 4's ChatDirector)
| Source | Dialogue events it should trigger |
|---|---|
| `village_raided` (World) | owner faction's lords: `ambient_complaint`; the raider: `ambient_brag`. If the raider is the player (Phase 3/5): `player_raided_my_village` for the owner |
| `party_defeated`, `battle` between lords (World) | winner: `ambient_brag`; loser: `ambient_complaint`; occasionally an event-triggered conversation |
| `caravan_robbed` (World) | the caravan faction's traders: `ambient_complaint` / `ambient_trade` |
| Player battles (Phase 3) | `beat_by_player`, `beat_by_player_repeat`, `beat_player`, `captured_by_player`, `released_by_player`, `fought_alongside_player`, `player_fled_from_me`, `player_win_streak`, `player_big_defeat`, `player_renown_up` |
| Player meets a lord on the map (Phase 4) | `encounter_*`; persona-initiated `whisper_*` on timers and by relationship |
| Diplomacy and sieges (Phase 5) | `war_declared`, `peace_made`, `player_besieging_my_fief`, `player_took_my_fief`, `my_faction_took_fief`, `player_joined_my_faction`, `player_left_my_faction`, `player_granted_fief` |
| Timers (Phase 4) | `ambient_chatter`, `ambient_trade`, `ambient_lfg` and scripted conversations |

### Phase 3: Simplified battle system
- 3.1 Auto-resolve formula: strength = Σ(count × tier power × type matchup) × leader skill × terrain
  × random(0.85–1.15).
- 3.2 BattleScreen: 3–5 rounds. Each round the player picks Hold / Advance / Flank / Charge / Retreat.
  The AI picks by archetype. A command matrix modifies the troop-type matchup. Battle log text.
- 3.3 Outcomes: casualties (killed vs wounded), prisoners, XP, troop upgrades, loot, and lords
  captured or released.
- 3.4 The same resolver is used for AI vs AI battles off-screen.
**Accept:** unit tests for the matchup and command matrices; 10k auto-resolve runs produce sane win
rates (the balance report script prints them).

### Phase 4: Fake-player dialogue runtime (the hook)
- 4.1 `DialogueDB`: load the bundle, then lookup **persona-specific → archetype → generic fallback**.
- 4.2 Persona memory: relationship score (-100..100), counters (`times_beaten_by_player`,
  `times_spared`, ...), flags (`betrayed`, `owes_player`). Saved with the game.
- 4.3 `ChatDirector`: event → affected personas (involved, same faction, nearby, rivals) → probability
  gate → channel → delay ("typing" time scales with length) → post. Per-line cooldown and per-persona
  recency memory so nobody repeats themselves.
- 4.4 Ambient chatter scheduler and playback of scripted multi-speaker conversations.
- 4.5 ChatPanel UI: global feed, whisper tabs, click a username to see their party on the map.
- 4.6 EncounterDialog: greeting → player choices (threaten / trade / propose alliance / leave) →
  pooled responses → outcome.
**Accept:** in a 2-hour soak sim, no line repeats within the cooldown window, there are no unfilled
`{placeholders}`, and every emitted event with eligible speakers produces chat at the configured rate.

### Phase 5: Factions, sieges, politics
- 5.1 War and peace AI per faction. Relations matrix.
- 5.2 Sieges: siege camp → assault (multi-round battle against garrison plus walls modifier) → fief
  ownership change.
- 5.3 Player joining or leaving factions, vassalage, fief grants. Betrayal events for leaving.
- 5.4 ReputationScreen: top friends and enemies, each with a one-line reason built from the memory log.
**Accept:** a 1-year headless sim produces wars, peace and fief changes without a faction being wiped
out by day 60 (balance guard).

### Phase 6: Content scale-up and tuning
- 6.1 Run the full pipeline at target scale (if Phase 0 shipped a pilot subset).
- 6.2 Playtest pass: tune chat frequency, escalation thresholds, cooldowns.
- 6.3 Fill coverage gaps reported by the pipeline's `report` command.

### Phase G: Graphics overhaul and 3D campaign map → `docs/specs/graphics.md`
Replaces the placeholder visuals with a **stylised low-poly 3D campaign map** and a matching medieval
UI at 60 fps, with the full simulation running. A new presentation layer only: `World`, `Party`,
`Politics`, battles and chat are unchanged (sim pixels → 3D via cell height; clicks raycast to a cell).
Art direction (stylised low-poly, CC0 assets) is recorded in the spec as approved by the user
2026-11-01. **Every asset download needs the user's OK per pack**; every asset file is listed in
`game/assets/CREDITS.md`.
- G1 heights and roads exported by `tools/gen_map.py` into `terrain.json` (additive fields; settlement
  cells unchanged) + `Terrain3D` mesh builder · G2 terrain shader, water, sky · G3 strategy camera and
  raycast picking · G4 scatter (forests, rocks, reeds…) · G5 3D settlements tinted by owner, siege
  effects · G6 3D parties · G7 UI theme for every screen · G8 3D battle diorama · G9 quality presets,
  profiling (the 2D map was removed after G6, user decision).
**Accept:** per-milestone criteria in the spec (e.g. 60 fps with full scatter at far zoom; 300 parties
at 60 fps at 4×; all existing tests still pass; screenshots reviewed by the user at G2).

### Phase 8: Readability and trade (added 2026-11-01 at the user's request)
Makes the map readable and gives the player an economy. Runs before Phase 7 so the ship phase polishes the final game.
- 8.1 Smaller population: `sim.json` sets how many of the 120 personas are active at a new game. The rest stay
  in the bundle, dormant. Proposed default: 60 active lords. Chat rates re-tuned by playtest.
- 8.2 Strength readout: party and hover cards show a rating against the player's company (Weaker / Even /
  Stronger) and a troop-power number. Same formula as the battle resolver (3.1), so the rating predicts fights.
- 8.3 Trade goods and town markets: goods defined in data (`game/data/config/trade.json`); towns produce and
  consume by prosperity and garrison; prices move with stock. Caravans carry goods between towns. Food returns as a good.
- 8.4 Player trading: a Market tab in the settlement menu (buy, sell, capacity limited by troop count) and the
  encounter "trade" choice (4.6) opens the same market with a lord.
**Accept:** per milestone in `docs/PROGRESS.md` (Phase 8).

### Phase 7: Polish and ship
Save and load UI, settings, audio hooks, tutorial whispers from a "mentor" persona, and desktop exports
(Windows/Mac/Linux).

## 6. Cross-cutting conventions
- All tunables live in `game/data/config/*.json` (battle matrices, AI weights, chat rates).
- Every system exposes a headless-testable API. UI is a thin layer on top.
- IDs are stable `snake_case` strings (`town_vellmoor`, `persona_017`), never array indices.
- The game must run with a **partial** dialogue bundle (fallbacks always resolve). This lets Phase 1–3
  proceed in parallel with content generation.

## 7. Risks
| Risk | Mitigation |
|---|---|
| Repetitive chat | Cooldowns, many variants for frequent events, signature lines per persona, fragment mixing |
| Too many combinations to generate | Archetype-level pools + small persona-specific layer; channels limited per event |
| Persona voice drift | Style bible in every prompt; persona card injected into its jobs; human `sample` review |
| Chat doesn't match behaviour | Archetype drives AI weights (Phase 2.2) |
| Haiku output breaks JSON | Strict output instructions, retry with the error message, schema validation |
| `claude` CLI picks up project or user context and hooks | Run jobs from an empty temp cwd; verify flags that skip settings/hooks |
