# Progress

Agents: work on the first unchecked milestone. Tick it only when its acceptance criteria are verified,
and add a one-line note with the evidence (command or test). Log decisions below.

## Phase 0: Content pipeline (`docs/specs/pipeline.md`)
- [x] 0.1 Scaffolding, `llm.py`, `smoke`, fake LLM, pytest
  - Evidence 2026-11-01: `.venv/Scripts/python -m pytest -q` → 13 passed; `python -m pipeline smoke` →
    valid JSON, attempts=1, cost $0.0028 per call on Haiku.
  - Setup: `python -m venv .venv` then `.venv/Scripts/python -m pip install -r pipeline/requirements.txt`.
  - Note for 0.5: 4 identical smoke prompts gave 4 usernames all starting "Thornwick". Expect low
    diversity across repeated calls. Persona batches need explicit variety constraints, a list of
    already-used names, and username dedupe.
- [x] 0.2 Config files (archetypes need **human approval**). Approved by the user 2026-11-01.
  - Written 2026-11-01: `world.toml` (6 factions), `events.toml` (34 events, 12 placeholders),
    `archetypes.toml` (8 archetypes), `blocklist.txt`, plus `pipeline.toml` [pilot]/[content].
  - Evidence: `python -m pipeline config` → config OK (976 pool cells, ≥6,064 lines, 272 S2 jobs);
    `pytest` → 29 passed.
- [x] 0.3 Job runner: resume, threads, budget cap
  - Evidence 2026-11-01: `pytest` → 45 passed (incl. rerun-skips-all, prompt-edit-reruns-only-affected,
    budget stop, failure log, dry run, 40 jobs on 8 threads). Real Haiku: `python -m pipeline run smoke`
    → ran=3 for $0.0121; a second run → skipped=3, $0.
  - The first real roleplayer job needed 2 attempts; a forced rerun took 1, so the cause wasn't seen.
    Retry reasons are now saved in `meta.retry_errors`; check them after the 0.6 pilot.
- [x] 0.4 S0 world: factions and settlement names
  - Evidence 2026-11-01: `python -m pipeline run world` → 7/7 ok on the first attempt; post step:
    6 factions, 24 towns, 40 castles, 100 villages, 0 errors, 0 warnings. `pytest` → 58 passed.
    Cost: v1 $0.049, then v2 regenerated only the 6 factions for $0.045 (continent job skipped).
  - v1 review found: lore naming spare towns that got cut, every faction choosing a gold secondary,
    unreadable troop names, and some real place names. All fixed in prompt v2 and the post step
    (see spec S0).
  - Factions: Orlagua Republic, Saaravenn Fen Confederacy, Tsevaret Ashmarches, Tesnovar Wardenry,
    Lauresse Regency, Ighrast Salt League.
  - Residual: a few forest-faction names may still be real Slavic words or villages (e.g. Brusnice,
    Hrastovec). Fix by hand-editing `out/validated/world/settlements.json` if they bother you.
- [x] 0.5 S1 personas + rivals
  - Evidence 2026-11-01: `python -m pipeline run personas` → 12/12 ok, 120 personas; by archetype
    griefer 16, memer 14, newbie 16, politician 14, roleplayer 14, trader 17, tryhard 17,
    veteran_mentor 12 (= shares × 120); 20 per faction. `pytest` → 75 passed.
    Cost: v1 $0.148 + v2 $0.146.
  - v1 review found: catchphrases copying archetype examples (many), backstories using `{player}` /
    `{village}` placeholders and invented player names, and the lowercase check flagging `xD`.
    v2 cut copied lines to 1 warning, 0 placeholder errors, and 113/120 backstories now name a real rival.
  - Remaining warnings (accepted): persona_107 has lowercase style but capitalised catchphrases;
    persona_111 has one catchphrase close to a veteran example; 4 usernames start with "Dame".
  - Lesson for S2/S3: Haiku copies sample lines readily. Say "never copy the samples" in the prompt
    AND check with `copies_example`.
- [x] 0.6 S2 pools pilot → human review → full run
  - [x] Pilot 2026-11-01 (griefer + roleplayer × 6 events = 12 jobs): 528 lines kept, 0 dropped,
    0 errors; no near-duplicate pairs anywhere; griefer all lowercase, roleplayer proper case.
    Cost: v1 $0.088, v2 $0.073 + one rerun $0.004. Full run estimate: 272 jobs ≈ $2.
    `pytest` → 86 passed.
  - Found and fixed in the pilot: wrongly nested cells (JSON shape hint added), lines assuming the
    player's gender (rule added; roleplayer guide now uses "ser" as gender-neutral), Haiku copying
    tone samples (filter catches them; a short cell errors with the rerun command), blocklist
    "i cannot" too broad (narrowed), `{persona}` used as if it were the player (placeholder
    descriptions rewritten), and a Windows temp-dir lock that crashed the run (hardened).
  - Residual: about 2/528 lines still gender {rival} or the player ("…his tactics"). 0.8 should add a
    soft gendered-pronoun warning.
  - [x] The user approved the pilot 2026-11-01; `scale.pilot = false`.
  - [x] Full run 2026-11-01: 272 jobs → **8,011 lines kept, 5 dropped, 0 errors**; cost $1.57 + $0.07
    for retries. About 1,000 lines per archetype; lowercase archetypes stay lowercase (tryhard 0,
    griefer 2, memer 10 capitalised lines); 0 near-duplicate pairs within any event; about 0.8% of
    lines contain gendered words, mostly about third parties.
  - Failure mode at scale: 9/272 face-only jobs returned broken JSON 4× in a row. A probe showed the
    cause is relationship objects nested inside each other with a lost brace (NOT stray quotes, as
    first assumed). Fixed by a specific retry hint in `llm._with_feedback` (which isn't hashed, so no
    finished jobs reran); all 9 succeeded within 3 resume passes. If it recurs, switch the pools
    schema to flat cell keys (`"hostile/face": [...]`). That changes every job hash, so it means a
    full ~$1.6 rerun.
- [x] 0.7 S3 signatures, S4 conversations
  - Signatures 2026-11-01: 120 jobs, $0.92, then 4 personas rerun ($0.03) after verbose types overran
    the 140-character global/whisper limit (the schema allows 220 because face lines may; the post
    step drops overruns). Result: **5,231 lines, 0 errors**. If overruns become a problem, make the
    schema length per-channel (changes every hash → ~$0.92 full rerun).
  - Conversations 2026-11-01: 60 jobs, $0.51, + 1 rerun. **300 threads (209 ambient, 91 event), 2,014
    lines, 0 dropped.** `{player}` is now accepted in every thread at post time (23 lines used it in
    ambient threads, and dropping lines broke those threads).
- [x] 0.8 Validate, dedupe, report, sample
  - Evidence: `python -m pipeline validate` → validate OK, 15,256 lines, 0 errors. Warnings: 99 lines
    pair `{player}`/`{rival}` with a gendered word (mostly horses, scouts, "sir knight"), 0 pool lines
    name a player, 0 lines shared across archetypes. `python -m pipeline report` → exit 0: 976/976
    cells at min_variants, 0 signature gaps, 0 open failures.
- [x] 0.9 Bundle into `game/data/` + contract tests
  - Evidence: `python -m pipeline bundle` → bundle OK, 133 files, 3.7 MB in `game/data/generated/`
    (120 persona dialogue files, 8 archetype files, conversations, events, world, personas,
    manifest with sha256 hashes). `pytest` → 102 passed.
  - **Phase 0 done.** Spend: $3.29 for the current raw outputs (about $3.7 including outputs later
    replaced by v2 prompts).

## Phase 1: Godot skeleton and map
- [x] 1.1 Project, autoload stubs, headless test runner (in-house, not GUT; see Decision Log)
  - `game/project.godot` (Godot 4.7). Autoloads: EventBus, SimClock, GameState (loads bundle +
    map data, all as data rather than nodes), DialogueDB (stub). `tools/godot.sh import|test|shot`.
- [x] 1.2 Continent map, terrain grid, `layout.json`
  - `tools/gen_map.py` (seed 1701) → `game/data/world/terrain.json` (240×150 cells, 16 px each,
    8 terrain types with costs, faction regions) and `layout.json` (164 settlements, villages
    `bound_to` their nearest town or castle). About 60% land; each realm's main terrain follows its
    concept (fen = marsh, forest = forest, salt league = desert, ashlands = ash/hills/mountains).
    `TerrainMap` builds the map image and an `AStarGrid2D` (water is solid; weight = terrain cost).
- [x] 1.3 Camera and settlement LOD
  - `MapCamera`: WASD/arrows, screen edges, middle-drag, wheel zoom toward the cursor (0.2–3×),
    clamped to the map. `SettlementLayer` draws all icons and labels in one pass at constant screen
    size: towns always, castle labels from 0.55×, villages from 0.32× (labels from 1.3×).
- [x] 1.4 Player movement, pathfinding, time controls
  - `Party` (data) moves along A* routes at 5 cells/hour on plains, divided by the terrain cost.
    Click to travel or select, Space to pause, 1–3 for speed, F to find the party, Esc to deselect.
    The HUD shows the clock, a settlement card and notices.
  - Evidence 2026-11-01: `tools/godot.sh test` → **17 tests, 0 failed** (incl. A* from the first
    town to all 164 settlements, exact terrain-cost movement, pause and speed, every script parses).
    `pytest` → 108 passed. `tools/godot.sh shot … --zoom=0.22 --frames=300` → **466 fps with all 164
    settlements fully zoomed out** (target 60). `--travel` → an 80-step route to the fen capital
    planned and followed at 4×. Screenshots reviewed: borders, icons, labels, LOD and route drawing OK.
  - **Phase 1 done.**

## Phase 2: World simulation
- [x] 2.1 Party model: `Party` gains kind, persona, faction, home, `Roster` (type × tier counts),
  gold, morale, goal state. Battles use `AutoResolve`, a **stand-in** (strength × luck) that 3.1 replaces.
- [x] 2.2 Utility AI with archetype weights (`scripts/sim/world.gd`): lords score recruit, raid,
  trade, patrol and home by their persona's `ai_weights`; hourly threat checks (and one at every
  decision) make them flee at `2.2 − 1.4·flee_threshold` × their strength, or chase prey weaker than
  `0.3 + 0.7·aggression` ×. Routed lords respawn at home after 48 h.
- [x] 2.3 Economy-lite: villages regrow recruits, gain prosperity and feed their lord's seat;
  raids cost a village 3 days, 20 prosperity and its recruits; lord upkeep, morale, desertion, drill.
- [x] 2.4 Bandits (spawn in the wilds, roam, cap 24) and caravans (town to town, cap 18, robbed by bandits or enemy lords).
- [x] 2.5 EventBus.`sim_event` relays every World event; the map has a parties layer, hover cards
  with persona and goal, and a live event feed. The dialogue taxonomy is mapped onto sim and player
  events in PLAN.md ("Sim events → dialogue events"); player-centred events arrive in Phases 3–5.
  - Evidence 2026-11-01: `tools/godot.sh test` → **28 tests, 0 failed, no leaks**. 30-day run with
    all 120 lords: **12 s, 0 stuck parties**, 666 battles, 157 raids, 206 trade runs, 733 recruitments,
    196 routs / 180 respawns, 68 caravans robbed, 111 bandit bands destroyed. Personas drive behaviour:
    griefers average 6.9 raids each and traders 0; traders average 5.0 trade runs each and griefers 0.06.
    `tests/bench_sim.gd`: ~0.5 s per simulated day. In-game at 4×: ~113 fps (target 60). Screenshots reviewed.
  - Bugs found on the way (all fixed, see Decision Log): a parse error in a test made the runner hang
    forever; a parse error in `roster.gd` made the first 10-minute "slow run"; lords ignored enemies for
    up to an hour after deciding; Party↔World signal cycles leaked every party.
  - **Phase 2 done.**

## Phase 3: Battle system
- [x] 3.1 Resolver (`scripts/battle/battle.gd`, rules in `data/config/battle.json`): type matchups
  (pikes > horse > bows > foot), a command rock-paper-scissors (Flank > Hold > Charge > Flank/Advance),
  per-command type emphasis, terrain modifiers, persona leader skill, luck, sub-linear numbers
  (`numbers_exponent` 0.8). Endings: routed (< 35% strength), fled (Retreat + cavalry-based escape
  roll), or withdrew after 5 rounds (ties are a coin flip). Battle AI by personality: griefers charge,
  roleplayers never retreat, traders hold and run, tryhards counter your last command; Retreat only
  when outmatched (`retreat_when_below`).
- [x] 3.2 BattleScreen: armies by type and tier with wounded, strength %, five commands (buttons +
  H/A/F/C/R, tooltips), Auto-resolve, round log, aftermath, Release/Ransom for a captured lord.
  The world pauses during the battle.
- [x] 3.3 Outcomes: killed vs wounded (wounded heal 15%/day), loot (50% of the loser's gold),
  prisoners (ransomed at towns), drill/XP for both sides, morale; a routed lord beaten by the player
  is captured. The player can attack any party (click it), is hunted by bandits, hires village
  recruits (R), and a defeated player regroups at the nearest town.
- [x] 3.4 AI-vs-AI battles use the same resolver (`AutoResolve` now runs `Battle.auto_play()`).
  - Evidence 2026-11-01: `tools/godot.sh test` → **40 tests, 0 failed** (matrices, the type triangle
    in play, numbers, terrain, leaders, command choice against a predictable enemy, endings,
    retreat odds, aftermath idempotence, AI personalities, player battles through the world, healing).
    30-day sim still 0 stuck. **Balance report: 15 scenarios × 10,000 battles**
    (`pipeline/out/reports/balance_report.txt`): mirror 49.4%; 60 v 30 100%; infantry > cavalry
    92.6%, cavalry > archers 99.9%, archers > infantry 66.2%; cavalry 60.5% on plains vs 5.6% in
    marsh; tryhard > newbie 78.1%; Hold vs a griefer 74.9% vs Flank 13.3% (reading the enemy pays).
    Battle screen screenshot reviewed.
  - Tuning history: baseline battles never routed and armies retreated while winning (2:1 battles
    lost 16%); fixed with retreat-only-when-outmatched, higher lethality, rout at 35%. Mirror matches
    favoured side A (56%) because ties went to A; fixed with a coin flip.
  - **Open design question for the user:** numbers are decisive. Outnumbered 40 v 50, even
    perfectly reading the enemy wins only ~12%, and pure cavalry beat pure archers ~100%. Tunable
    (`numbers_exponent`, `command_matchup` extremes, `max_rounds`) if you want skill to beat numbers more often.
  - **Phase 3 done.**

## Phase 4: Dialogue runtime
- [x] 4.1 DialogueDB (`scripts/autoload/dialogue_db.gd`): signature line first (35% when one fits),
  then archetype pool, then the "neutral" band; 15-minute line cooldown; `fill()` never leaves a brace
  (ctx values, else sensible per-faction places and per-occurrence amounts); `style()` applies each
  persona's typing (lowercase, typo swaps) to every line (the Phase 0 open question, answered).
- [x] 4.2 Persona memory (`scripts/dialogue/relations.gd`, owned by World): score -100..100 (start
  by archetype: griefers about -20, newbies about +15), beaten/beat/released/ransomed counts, allied
  flag. **Grudges hunt you:** an aggressive persona at ≤ -60 attacks you on the map.
- [x] 4.3 ChatDirector (`scripts/dialogue/chat_director.gd`): player battles → the lord reacts
  (`beat_by_player`, `_repeat` from the 3rd loss, `beat_player`, `player_fled_from_me`);
  streaks / renown / big defeats → 2 personas comment; raids, routs and robbed caravans → brags and
  complaints, throttled to at most one per 15 s. Chat runs on its own real-second clock (human pace
  at any game speed), with typing delays and a 12/min global rate limit.
- [x] 4.4 Timers: ambient chatter every 7–18 s, a scripted conversation every 70–140 s (places fixed
  per thread, amounts per line), unprompted whispers from the personas with the strongest feelings.
- [x] 4.5 ChatPanel: Global tab + one tab per whisperer (unread `*`), faction-coloured usernames that
  find the lord on the map when clicked.
- [x] 4.6 EncounterDialog: click a lord to meet them (Shift+click attacks). They greet you by how they
  feel; Threaten (may pay, may draw steel → battle), Offer gold, Propose alliance, Attack, Leave, each
  answered in their voice and remembered. A captured lord pleads in the battle aftermath.
  - Evidence 2026-11-01: `tools/godot.sh test` → **50 tests, 0 failed**. **2-hour soak**: 1,432
    messages (11.9/min), 143 whispers, 72 conversations, **0 unfilled placeholders, 0 lines repeated
    inside the cooldown**, player-battle reactions posted 100% of the time, raid reactions at 30%
    against 25% configured. Real-pace soak (world at 1×, 10 min): 12 msgs/min, 100 raid reactions throttled.
    Screenshots reviewed: the chat panel with threads and whisper tabs, the HelmDodger encounter
    ("They draw steel!") handing off into the battle screen.
  - Found and fixed: simultaneous reactions post in any order (test only); background brags exhausted
    the pool and repeated lines (now skipped instead); the first soak ran the world 120× slower than real
    1× play, which hid that raids would flood chat (now throttled and tested at real pace).
  - Tunable if chat feels busy: `data/config/chat.json` timers and `global_rate_limit`.
  - **Phase 4 done.**

## Phase 5: Factions, sieges, politics
- [x] 5.1 War/peace AI (`scripts/sim/politics.gd`, owned by World via a weak ref): fort owner,
  holder and garrison; villages follow their fort; every AI goal now uses the current owner. Daily
  diplomacy: war weariness (days, lost fiefs, routs) raises peace odds; bordering realms at peace for
  25+ days may declare war (max 2 wars each). Balance guard: forts already under siege don't count,
  and it is re-checked at the moment of assault.
- [x] 5.2 Sieges: lords with a high `besiege` weight camp at an enemy fort (allies join), then assault;
  the garrison plus any owner lords standing at the fort defend with walls (leader "garrison" ×1.8).
  A win changes the owner, gives the fort to the capturing lord, and rehomes the losers' lords.
- [x] 5.3 Player: J swears allegiance at a town, L leaves (members −20, called traitor), B besieges an
  enemy fort (assault on the battle screen); a fort you take is granted to you and pays daily income.
  Your realm's enemies now attack you on sight.
- [x] 5.4 ReputationScreen (P): your realm, wars, fiefs, renown and record; top 10 friends and enemies,
  each with the latest reason (`Relations.adjust_why`). Chat covers `war_declared`, `peace_made`,
  `my_faction_took_fief`, `player_took_my_fief`, `player_besieging_my_fief`, `player_joined_my_faction`,
  `player_left_my_faction`, `player_granted_fief` (politicians get jealous).
  - Evidence 2026-11-01: `tools/godot.sh test` → **59 tests, 0 failed**. **1-year run**
    (`tests/year_report.gd`, saved to `pipeline/out/reports/year_report.txt`): 22 wars declared, 25 peaces,
    48 fiefs changed hands, **no realm wiped out, smallest realm 6 forts at day 60, 0 stuck parties**.
    Screenshots reviewed: the reputation screen with reasons, the HUD feed "Wanderer takes Vardakar",
    a siege card ("UNDER SIEGE…") and the besieged fort's lord sallying out into a battle.
  - Tuning history: first pass wiped out the regency by day 30 (the guard was only checked when a siege
    started; assaults won 96/98); then zero sieges (too strong); now about 22 captures per 120 days.
  - **Catch-up added (user request, 2026-11-01)** (`sim.json politics.catch_up`; `Politics.share` =
    a realm's forts ÷ the average): war weariness grows faster when a combatant is overextended;
    a realm at ≥ 1.6× share draws war declarations 3× as often (coalitions); `resilience` =
    1/share, clamped 0.5–3×, scales garrison and village recruit regen and lord respawn size.
    Before vs after over one year (`year_report.txt` vs `year_report_catchup.txt`): final forts
    17/14/3/25/2/3 → 18/12/7/7/4/16 (spread 8.9 → 5.1); the lead changed hands several times
    (wardens peaked at 16 then fell to 6, ashlands 21 → 6, regency recovered 5 → 12); 74 captures
    instead of 48; still none wiped out and 0 stuck. `tools/godot.sh test` → **60 tests, 0 failed**.
  - The chat soak now measures the line cooldown at pick time (`msg.picked`): with a busier world,
    rate-limit delays between pick and post made two lines look early when they weren't.
  - **Phase 5 done.**

## Phase 6: Content scale-up and tuning
- [x] Phase 6 (2026-11-01)
  - 6.1 Content was already at full scale (0 coverage gaps). New pipeline rule
    `textcheck.assumes_gender` (pronouns, titles or nouns that gender `{player}`/`{rival}`, unless another
    referent such as "my horse" comes first) drops 12 lines; coverage still 976/976 and 0 signature
    gaps; the precise cross-check finds only 3 left, all inside scripted conversations (kept: dropping
    a line breaks the thread). Rebundled. 9 new pytest cases.
  - 6.1b The last two never-fired dialogue events are wired: **X raids a village**
    (`player_raided_my_village`, its lord −12) and **`fought_alongside_player`** (a nearby lord who
    wanted that enemy beaten thanks you, +3). Every one of the 34 events can now fire.
  - 6.2 **Automated playtest** `tests/playtest.gd` (20 min at real 1×: fights, joins, attacks lords,
    raids, besieges, leaves; transcript at `pipeline/out/reports/playtest_transcript.txt`).
    First run: 17.4 msgs/min, 5.8 whispers/min, 79 battles (58 lost) and 77 "big defeat" broadcasts.
    Tuning: broadcast cooldowns (big defeat 5 min, streak 2 min), a 24 h regroup after defeat
    (6 game hours were 6 real seconds), whisper share 0.35, slower ambient (15–30 s) and conversations
    (160–260 s), world reactions ≥ 30 s apart, letter-only typos at a lower rate, real loss numbers in
    defeat lines. Final: **~11 msgs/min (quiet 4–8, busy 12–17), ~1 whisper/min, 0 exact repeats,
    86 distinct speakers, 16 battles (7 won)**. Soak: 7.5/min over 2 h; real pace 8.4/min.
  - Known content quirk (not fixed): a few newbie `player_big_defeat` lines speak in the first person
    ("lost most of my army…"), since Haiku misread that event for that archetype.
  - Evidence: `tools/godot.sh test` → 60 tests, 0 failed; `pytest` → 117 passed.

## Phase G: Graphics overhaul and 3D campaign map (`docs/specs/graphics.md`)
Added 2026-11-01 after Phase 6, at the request of another session that drafted the spec with the
user (art direction recorded there as approved: stylised low-poly, CC0 assets). Started 2026-11-01.
Rules: each asset pack download needs the user's OK; every asset file goes in `game/assets/CREDITS.md`.
- [x] G1 Heights and roads exported from `tools/gen_map.py` into `terrain.json` (additive fields;
  settlement cells unchanged; update `tools/tests/test_gen_map.py`) + `Terrain3D` mesh builder
  - 2026-11-01: `terrain.json` gains `sea_level`, hex `heights` and `roads` (69 roads, 100 tracks,
    1,854 road cells). Format in `docs/specs/graphics.md` §4 "As built". Regenerated against a
    backup: `layout.json` identical and every old terrain field identical.
  - Mesh builder is `TerrainMesh` (`scripts/map3d/terrain_mesh.gd`, config `data/config/map3d.json`).
  - Evidence: `pytest` → 122 passed (6 new: heights shape/sea, heights follow terrain, roads connect
    over land with the diagonal rule, compact dump round-trips, committed files = regeneration).
    `tools/godot.sh test` → **66 tests, 0 failed** (6 new in `test_terrain_mesh.gd`):
    "TerrainMesh: 481x301 vertices, 288000 triangles, built in 188 ms"; all 164 settlement centre
    vertices above the sea and equal to `height_at`; unsmoothed cell centres equal the exported data.
    Preview render (`tests/preview_terrain3d.gd`) checked by eye: lit, front faces up, relief correct.
- [x] G2 Terrain shader, water, sky, fog (screenshots approved by the user)
  - 2026-11-01 built; **approved by the user 2026-11-01** (`docs/screenshots/g2/map3d_{far,mid,near}.png`).
    `Map3DView` (`scripts/map3d/map3d_view.gd`) = terrain (`terrain.gdshader`) + sea (`water.gdshader`)
    + sky, fog, sun; data textures in `MapTextures`; all colours/tunables in `data/config/map3d.json`.
    No downloaded assets: all detail is procedural (noise), so no asset pack was needed yet.
  - Evidence: `tests/preview_terrain3d.gd` → setup 222 ms; far/mid/near all 60 fps (vsync cap) at
    1600×900. `tools/godot.sh test` → 70 tests, 0 failed (4 new in `test_map3d_view.gd`); pytest 122 passed.
  - Fixed while iterating: sin()-based noise hash went blocky at map coordinates (now a sin-free hash);
    cell-staircase borders (now soft per-region masks); seabed shadow and a depth step drew a rectangle
    on the sea at the map edge; beaded roads (soft 3×3 stamps).
- [x] G3 Strategy camera + raycast picking (click-to-travel on the 3D map)
  - 2026-11-01: `campaign_map.gd` is now the shared controller; it draws through a view with one
    interface (`MapView2D` = the old sprite/camera/layers, `MapView3D` = Map3DView + `StrategyCamera`
    + picking + player flag, route ribbon, hover/selection rings, owner-coloured settlement pins as
    G5 placeholders). Choose with `--map=3d` or `use_3d_map` in `data/config/map3d.json` (**default
    still 2D** until settlements/parties exist in 3D, G5/G6). Camera keys: WASD/edges/middle-drag
    pan, wheel zoom toward the cursor, Q/E or right-drag rotate (not yet in the HUD help line: G7).
  - Picking = `TerrainMesh.raycast` on the exact rendered surface (sea counts as y = 0), stepping by
    gap / steepest slope so thin crests can't be skipped (a fixed 0.4 step missed one: village_04_03).
    Rays come from `StrategyCamera.screen_ray` (same maths as Camera3D, usable headless).
  - Evidence: `tools/godot.sh test` → **77 tests, 0 failed** (7 new in `test_strategy_camera.gd`:
    rays down/slanted/into the sky, screen→cell for every 9th settlement at 3 zooms, pixel round trip,
    clamp/pan/rotate directions, zoom curve + camera never underground, 2D↔3D zoom mapping).
    In a window: `screen_ray` vs `Camera3D.project_ray_*` mismatch 0.000000 over 240 rays; slowest
    pick 0.37 ms. `tools/godot.sh shot x.png --map=3d --click=1200,300` → "cell (146, 55) (hills),
    moving=true, destination (146, 55)" and the route in the shot ends at the clicked pixel;
    `--click=800,450` picks the start town Ondrac in both 2D and 3D. 2D regressions (`--siege`,
    `--encounter`, `--battle`, `--travel`) run clean; 3D `--travel` 193 fps, `--siege` 194 fps (vsync off).
- [x] G4 Scatter: forests, rocks, reeds, dunes, ash (60 fps at far zoom)
  - 2026-11-01: `Scatter` (`scripts/map3d/scatter.gd`) places 34,511 models (conifer, broadleaf,
    bush, shrub, rock, ash rock, reeds, dune mound, stump, dead tree) by terrain type × noise, seeded;
    off water, roads, steep slopes (trees) and settlements; pines frosted above the snow line.
    Models are procedural low-poly meshes (`ScatterMeshes`), so no asset download was needed.
    Drawn as 517 MultiMesh chunks (16×16 cells) with per-kind camera ranges (trees and dunes always;
    bushes/reeds/stumps ~70–90, rocks 120); trees cast shadows; gentle wind sway in `scatter.gdshader`.
    All tunables in `"scatter"` of `data/config/map3d.json`. Screenshots: `docs/screenshots/g4/`.
  - Evidence (vsync off, 1600×900, `tools/godot.sh shot x.png --map=3d --zoom=Z --frames=300`):
    far 0.2 → **145.5 fps**, mid 0.6 → 175.7, near 2.5 → 227.4. Stress with every range off (all
    34.5k models drawn at far zoom) → 137.8 fps. `tools/godot.sh test` → **82 tests, 0 failed**
    (5 new in `test_scatter.gd`: all kinds placed, built in 552 ms; none on water/roads/settlement
    clearings and all on the surface; kinds only on their terrain, >75% of forest cells wooded;
    deterministic; faces wound outward).
  - Fixed: the custom shader read sRGB vertex colours as linear (trees came out pale mint).
- [x] G5 3D settlements per culture, tinted by owner, siege effects, projected labels
  - 2026-11-01: `SettlementMeshes` builds town/castle/village models in code for six culture styles
    (canal, fen, ash, forest, regency, oasis; palettes in `"settlements"` of `map3d.json`), 2 variants
    each. `Settlements3D` places all 164 (seated on slopes: highest ground under the footprint, capped by
    the sunk walls), paints flags + keep roofs in the **current owner's** colour (vertex alpha 0 parts,
    `settlement.gdshader`), and adds siege camps (tents in the besieger's colour + soft smoke).
    `LabelOverlay` projects names and, when zoomed out, owner-coloured icons + siege rings with the 2D
    map's LOD rules. Placeholder pins removed. New automation: `--focus=<id>`, `--watch-siege`,
    `--capture-test`. Screenshots: `docs/screenshots/g5/` (one town per culture, castle + villages,
    siege, captured castle, mid, far).
  - Evidence: `tools/godot.sh test` → **86 tests, 0 failed** (4 new in `test_settlements_3d.gd`: 164
    placed and seated, one instance each; recolour on the next refresh, refresh ≤ 1 s; siege camps
    appear/clear; 6 cultures × 3 types × 2 variants build with owner parts inside their footprint).
    In a window: `--map=3d --capture-test` → "recoloured after 45 ms" (GPU buffer purple → red; the
    bound villages' flags follow); `--watch-siege` found an AI siege at game hour 108.7 and framed it.
    FPS (vsync off): far 0.2 → 66–82, mid 0.6 → 111, 2D `--travel` 98–109 in the same session (the
    machine ran ~2× slower than earlier today: 2D was 194 then); 3D/2D ratio ≈ 0.7, as before G5.
    pytest 122 passed; 2D `--siege` runs clean.
  - Fixed while iterating: labels sat on the models, the selection ring hid inside town walls,
    castles on steep hills were half buried, villages and castles were dwarfed by trees (scaled up),
    smoke puffs were hard squares.
  - Not done here: the realm-border glow can look heavy at mid zoom on steep coasts (G2 look; revisit
    in G9 tuning). The settlement card still names the founding realm ("castle of the Lauresse
    Regency") after a capture, as on the 2D map (HUD text, G7).
- [x] G6 3D parties (300 at 60 fps at 4×), hover and selection
  - 2026-11-01: `Parties3D` draws every active party from World each frame (one MultiMesh per kind,
    written as one packed buffer per kind): lords under a banner in their realm's colour, bandits under
    a dark red rag, caravans as a covered cart + mule with a realm pennant, the player a little larger in
    their realm's colour (red when free) on a gold ring. Models are procedural (`PartyMeshes`); they
    turn toward where they're heading and scale with camera distance (`"parties"` in `map3d.json`).
    Hover is screen-space on the banner (`MapView3D.nearest_on_screen`), with a ring and the name;
    lord names show from 2D-zoom 1.4 as on the 2D map. Placeholder player flag removed.
    New automation: `--parties=N` (tops up with caravans to N active parties, 4x, player kept out of
    battles), `--hover-party`, and an "AUTO profile" line (render CPU/GPU ms, draw calls) on every shot.
  - Evidence: `tools/godot.sh test` → **91 tests, 0 failed** (5 new in `test_parties_3d.gd`: one
    instance per active party per kind, inactive hidden, anchored on the ground; turning toward travel;
    scale limits; screen-space hover incl. behind-camera; realm-coloured flags, bandits not).
    `--map=3d --parties=300` (301 active: 120 lords, 180 caravans, 4x): 86.2 and 87.7 fps at mid zoom,
    81.9 at far; 2D in the same session 84.7 / 84.3 / 88.4. `--hover-party`: "pointing at
    lord_persona_098 -> hovered 'lord_persona_098' (card shown)" at 2D-zoom 0.6 and 0.25.
    pytest 122 passed; 2D `--siege` runs clean.
  - Profiling found the label overlay redrawing every frame (1.6 ms) and fixed it: now it redraws on
    camera/hover changes and 4×/s (29 redraws in 600 frames). Before that fix, 3D at 300 parties
    measured 55–64 fps against 73–80 in 2D. Party sync is still ~1.25 ms/frame (GDScript per party).
  - Known, not fixed here: the party card shows unfilled "{player}" in some persona quotes (also on
    the 2D map; HUD text, G7).
  - 2026-11-01, after G6: **the 3D map is now the default** (`use_3d_map: true`, the user's call);
    `--map=2d` (or the config) gives the flat map. Checked: default start shows the 3D view; `--map=2d`,
    `--battle`, `--encounter`, `--chat`, `--reputation` all run and their dialogs draw over the 3D map.
  - 2026-11-01, right after: **2D map removed** at the user's request ("kill 2d mode"). Deleted
    `MapView2D`, `MapCamera`, `SettlementLayer`, `PartiesLayer`, `PartyView` and `TerrainMap.build_image`
    (+ its palette); the label LOD constants moved to `LabelOverlay`; `campaign_map.gd` (now `extends
    Node`, scene root `Node`) always builds `MapView3D`; `use_3d_map` and `--map=` are gone; the zoom
    helpers are `rig_zoom_for_level` / `level_for_rig_zoom` (zoom level 0.2 far .. 3.0 near, as before).
    HUD help line now lists Q/E: rotate. Evidence: `tools/godot.sh test` → 91 tests, 0 failed; every
    automation scene runs (default, `--travel`, `--click` → cell (146, 55), `--battle`, `--encounter`,
    `--chat`, `--reputation`, `--siege`, `--hover-party` → card shown, `--capture-test` → recoloured
    after 113 ms, `--parties=300` → 71.3 fps at 4x).
- [x] G7 UI theme for every screen; all automation screenshots retaken and reviewed
  - 2026-11-01: `UiTheme` (`scripts/ui/ui_theme.gd`, config `data/config/ui.json`) builds the theme
    and merges it into Godot's default theme at startup (GameState._ready), so every Control gets it,
    including those under CanvasLayers (a root-window theme does not reach them: probed). Two looks:
    dark wood + bronze for HUD/cards/chat, parchment + ink for dialogs (`panel.theme =
    UiTheme.parchment()`). Fonts (user-approved download, SIL OFL 1.1, `assets/CREDITS.md`): Cinzel
    for titles, buttons, tabs and map place names; EB Garamond (+ italic) for body text, chat and
    lord names. Label variations HeaderLarge/Medium/Small, MutedLabel, NoticeLabel.
  - Redesigned: HUD top bar (date, speed, your company), titled settlement/party cards that refresh
    every second (owner, garrison, siege), "Realm news" panel, a controls bar, notices in a panel;
    see-through chat with bold realm-coloured names; encounter, reputation (rich rows with coloured
    scores) and battle (fits its content, Victory/Defeat verdict) on parchment.
  - Fixed on the way: unfilled "{player}" in persona quotes on cards (`Hud.fill_names`); stale
    settlement cards after captures/sieges; Cinzel rendered "1x" as "IX" (speed now in Garamond
    "Speed ×1"); battle panel gap (rows queued for deletion still counted in layout); stacked lord
    names over towns (lords at home get no floating name unless hovered; O(1) cell check).
    New automation flag `--battle-auto` (auto-resolves to show the aftermath).
  - Evidence: `tools/godot.sh test` → **96 tests, 0 failed** (5 new in `test_ui_theme.gd`: bundled
    fonts load and are credited with licences; the merge reaches a bare Label; parchment sub-theme
    values; WCAG contrast ≥ 4.5 for all 9 text/background pairs; {player} filled). pytest 122 passed.
    Screenshots retaken and reviewed, `docs/screenshots/g7/`: map, travel, near, far, hover (card
    shown), chat, encounter, reputation, battle, battle_end, siege.
- [ ] G8 3D battle diorama (presentation only; battle tests unchanged)
- [ ] G9 Quality presets, profiling report (the 2D-map fallback was dropped: 2D removed after G6)

## Phase 7: Polish and ship
- [ ] Phase 7

## Decision log
| Date | Decision | Why |
|---|---|---|
| 2026-11-01 | Engine: Godot 4 (GDScript) | Native builds, editor for map and UI, room to grow |
| 2026-11-01 | Scope: full continent (6 factions, ~164 settlements, ~120 personas) | User choice |
| 2026-11-01 | Pipeline first, in Python, calling `claude -p` with Haiku | Content contract drives later phases; no runtime LLM |
| 2026-11-01 | Dialogue = archetype pools + persona signature layer | Keeps generation combinations manageable while keeping individual voices |
| 2026-11-01 | CLI flags (claude 2.1.316): `-p --model haiku --output-format json --system-prompt ... --json-schema ... --max-budget-usd ... --safe-mode --tools "" --no-session-persistence`, prompt on stdin, cwd = empty temp dir | `--safe-mode` skips CLAUDE.md, plugins, hooks and MCP but keeps subscription auth. `--bare` rejected because it needs ANTHROPIC_API_KEY |
| 2026-11-01 | Every prompt ends with "respond with JSON matching this schema" + schema text (`llm.with_json_instruction`) | Without it Haiku answered in markdown. With `--tools ""` the envelope's `structured_output` stays empty, so the wrapper parses `result` and validates locally with jsonschema |
| 2026-11-01 | Python 3.14 in repo-local `.venv` | Installed interpreter; the spec's 3.11+ requirement is satisfied |
| 2026-11-01 | Chat uses text emoticons (`:)`, `xD`), not emoji; `chat_style.emoji` renamed to `emoticons` | Godot default fonts don't render emoji |
| 2026-11-01 | Content rating PG-13 (mild swearing ok; no slurs, sexual content or real-world politics, religion or people) | Griefer and memer need some bite without being hateful |
| 2026-11-01 | Factions deliberately avoid the standard genre set (no generic steppe/highland/empire/north/desert line-up) | Keeps the setting original |
| 2026-11-01 | ~~Slur filtering via an imported open-source list~~ **Dropped: no slur list.** Filtering relies on the prompt's content rating plus `blocklist.txt` | User decision; the content rating in every prompt already forbids slurs |
| 2026-11-01 | Settlement ids are positional (`town_03_02`), not name slugs | Names can be regenerated without breaking `layout.json` |
| 2026-11-01 | Banner colours hand-set in `world.toml`; the config check rejects similar primaries | Parallel jobs can't coordinate; v1 gave all six factions gold |
| 2026-11-01 | Troop names = flavour word + English role word | Players must tell unit types apart at a glance |
| 2026-11-01 | Stages may have a post step (`Stage.post`) that writes `out/validated/<stage>/` | Cross-job checks (uniqueness) can't happen inside parallel jobs |
| 2026-11-01 | CLI forces UTF-8 stdout/stderr | Windows console (cp1252) crashed on generated names like č |
| 2026-11-01 | Continent is named **Ormerath** (`world.toml` `continent.name`) | User's pick from the S0 candidates |
| 2026-11-01 | Each persona slot gets a unique seeded inspiration word for its username | Parallel calls otherwise converge (0.1: 4/4 "Thornwick") |
| 2026-11-01 | Backstory `{rival}` is replaced with the persona's first real rival in the post step | Grudges in bios match the rival graph the game uses |
| 2026-11-01 | `scale.pilot` limits only S2–S4; personas always run in full | Personas are cheap (~$0.15) and every later stage needs the full set |
| 2026-11-01 | Per-job JSON Schemas (`Job.schema_inline`) for pools | The CLI then enforces each event's exact cells and per-channel length |
| 2026-11-01 | "Ser" is a gender-neutral title in Ormerath; lines never assume the player's gender | The human player can be anyone |
| 2026-11-01 | A job exception never kills a run; temp-dir cleanup errors are ignored | The 0.6 pilot crashed on a Windows file lock |
| 2026-11-01 | Bundle lives in `game/data/generated/`, owned only by the pipeline, swapped in atomically after contract checks | The game never sees a half-written or invalid bundle; hand-made data is never overwritten |
| 2026-11-01 | Gendered-word lines are warnings, not drops | About 25/8,011 are flagged and most are false alarms ("my horse says he…") |
| 2026-11-01 | Tests are sandboxed from the real `pipeline/out` and `game/data` (`tests/conftest.py`) | A CLI test once ran `validate` on live data during a background run |
| 2026-11-01 | GDScript tests use a small in-house runner (`game/tests/run_tests.gd`, `TestCase`), not GUT | Avoids downloading an addon; enough for headless checks. Includes a test that every script parses |
| 2026-11-01 | The map is generated by `tools/gen_map.py` (seeded) into `game/data/world/`, outside `generated/` | Positions are hand-editable game data; names and lore stay in the pipeline bundle and are joined by settlement id |
| 2026-11-01 | Visual checks via automation flags (`-- --screenshot=… --zoom= --frames= --travel`): the game renders, prints FPS, saves a PNG and quits | Lets agents verify rendering and performance without a human |
| 2026-11-01 | Phase 2 battles use `AutoResolve` (strength × luck); 3.1 swaps in the real resolver with the same signature | AI conflict was needed before the battle system exists |
| 2026-11-01 | Starting wars are fixed in `data/config/sim.json`, following the lore: republic vs fen, republic vs salt league, regency vs ashlands, regency vs forest | Diplomacy is Phase 5 |
| 2026-11-01 | The player is never attacked in Phase 2 (`World.hostile` returns false) | Player battles are Phase 3 |
| 2026-11-01 | Food is deferred; gold, upkeep and morale drive lord behaviour | Kept the economy small; revisit if armies feel unconstrained |
| 2026-11-01 | World never connects to `Party.arrived`; arrival is detected in `_tick` | A bound callable on a party's own signal is a reference cycle that leaked every party |
| 2026-11-01 | The test runner treats a suite that fails to load as a failure and keeps going | A parse error once crashed the runner before `quit()` and Godot hung forever |
| 2026-11-01 | GDScript: declare types explicitly (`var x: T = …`) whenever the right side comes from an untyped call (a Dictionary value, a Node method, `reduce`) | `:=` on those is a parse error that broke whole scripts twice in Phase 2 |
| 2026-11-01 | The test runner loads every script before any test and stops if one fails to compile | A null `Battle.new()` turned `while not battle.over` into an infinite loop (hangs in Phases 2 and 3) |
| 2026-11-01 | Patch scripts must assert a unique match before replacing | A non-unique `replace` duplicated an automation block in Phase 3 |
| 2026-11-01 | Lords ignore the player unless the player attacks them; bandits always hunt the player | Hostility toward the player by relationship comes with Phase 4 personas |
| 2026-11-01 | Chat runs on real seconds of unpaused play, not game time | At 1× a game day is 24 s; game-time delays would make conversations unreadably fast |
| 2026-11-01 | Background chat skips rather than repeats a line on cooldown; reactions to the player may reuse one as a last resort | Repetition is what breaks the "real players" illusion; the player's own actions must always get a reaction |
| 2026-11-01 | Persona `chat_style` is applied at runtime to every line (lowercase, typo swaps) | Archetype-pool lines then read in each individual's voice (the Phase 0 open question) |
| 2026-11-01 | The player is called "Wanderer" in chat (`player.name`) | A neutral gamer tag until a naming screen exists (Phase 7) |
| 2026-11-01 | Politics lives in `Politics`, holding World by `WeakRef` | World owns it; a strong back-reference leaked the whole world on every new game/test |
| 2026-11-01 | Lords at a besieged fort defend it alongside the garrison | Without it, sieges ignored the realm's own armies and snowballed |
| 2026-11-01 | Catch-up politics: overextension weariness, coalitions against dominant realms, underdog resilience | User chose it: without it one realm swallowed the map over a year |
| 2026-11-01 | Chat pacing targets ~8–12 msgs/min and ~1 whisper/min, measured by the automated playtest | The first playtest was unreadable (17/min, ~6 whispers/min) |
| 2026-11-01 | After a defeat the player gets 24 game hours of safety | At 1× six game hours were six seconds; the bot lost 58 battles in 20 minutes |
| 2026-11-01 | Shell-written patches must not contain backslash escapes (`\\b`, `\\n`); write them with the editor or a script file | The shell collapsed escapes three times (f-strings, regex word boundaries) |
| 2026-11-01 | Heights are stored as one hex string per row (2 digits per cell), not number arrays | Matches `rows`/`regions`, keeps the file small and hand-diffable, and Godot decodes a row with `hex_decode()` |
| 2026-11-01 | Castles also get a road to their realm's nearest town (the spec named only village tracks and town links) | Otherwise castles without villages would sit off the road network |
| 2026-11-01 | The 3D mesh builder is `TerrainMesh`, not `Terrain3D` | `Terrain3D` is the class name of a popular Godot addon; avoids a clash if one is ever added |
| 2026-11-01 | Terrain smoothing is clamped so land cells stay ≥ +0.12 and water ≤ −0.12 world units | Blurring must never move the coastline or sink a coastal settlement |
| 2026-11-01 | G2 terrain detail is procedural shader noise, not texture packs; "triplanar on slopes" = triplanar noise for rock | Fits the flat-colour low-poly style, no downloads or licences, and no texture stretching on cliffs |
| 2026-11-01 | Faction borders come from two linear-filtered RGBA region masks (one channel per realm), blurred in the shader | Sampling region ids per cell gave a staircase; equal-mask lines are smooth and cost 10 texture reads |
| 2026-11-01 | Borders follow home regions for now, not current fief owners | Owner tinting belongs to settlements (G5); the 2D map also draws home regions |
| 2026-11-01 | ACES tonemap, low fog (0.0012) and ambient 0.4 | Filmic and denser fog washed the far view out |
| 2026-11-01 | G3 picking marches the TerrainMesh surface instead of a physics HeightMapShape3D raycast | Deterministic, testable headless, matches the drawn triangles exactly, 0.37 ms worst case; no physics bodies to keep in sync |
| 2026-11-01 | The 3D map stays opt-in (`--map=3d`, `use_3d_map: false`) until G6 | Settlements and other parties are not drawn in 3D yet; the 2D map stays the playable default |
| 2026-11-01 | Automation clicks (`--click=x,y`) set the view's `mouse_override`; the click itself is a real pushed InputEvent | `push_input` motion events don't move `Viewport.get_mouse_position()`, and warping the real cursor would disturb the user |
| 2026-11-01 | G4 scatter models are generated in code (`ScatterMeshes`), not a CC0 pack | Matches the flat low-poly style, needs no download approval or CREDITS entries, and stays tiny; a pack can replace a kind later by swapping its mesh |
| 2026-11-01 | Small scatter kinds have camera ranges; trees and dunes always draw | Forests and deserts must read from far zoom; pebbles and reeds are invisible there anyway (and even all-on runs at 138 fps) |
| 2026-11-01 | G5 settlement architecture follows the founding realm's culture; only flags and keep roofs follow the current owner | A captured fen town should still look like a fen town; the owner reads from the colour |
| 2026-11-01 | Settlement owner colours are kept in `Settlements3D` as well as the MultiMesh buffer | The headless dummy renderer returns black for MultiMesh reads; tests use the record, `--capture-test` checks the real buffer |
| 2026-11-01 | Compare FPS between sessions only as 3D/2D ratios | The same 2D run measured 194 and 98 fps on one day (GPU power state); absolute numbers are not comparable across sessions |
| 2026-11-01 | 3D party hover is screen-space on the banner, not the ground point under the pointer | Banners stand above the ground; at far zoom the ground behind a banner is a cell or more away |
| 2026-11-01 | Party models grow with camera distance (clamp(distance/16, 1.1, 4.5)) | Like the 2D map's fixed-pixel icons: parties must stay readable at every zoom |
| 2026-11-01 | 3D map is the default from G6 on; the 2D map stays as the `--map=2d` / config fallback | User decision once settlements and parties were drawn in 3D; G9 turns the fallback into a settings toggle |
| 2026-11-01 | **2D map removed**; the 3D map is the only campaign map (supersedes the fallback rows above and G9's 2D toggle) | User decision after G6 |
| 2026-11-01 | UI fonts: Cinzel + EB Garamond (OFL), downloaded with the user's approval | Medieval display serif for titles, a readable book serif for chat-heavy text; both free to bundle |
| 2026-11-01 | The UI theme is merged into Godot's default theme at startup, built from `ui.json` | A theme on the root window does not reach Controls under CanvasLayers; the merge does, and stays data-driven (no generated .tres to keep in sync) |
| 2026-11-01 | Dialogs are parchment with ink text; HUD and chat are dark wood | Dialogs read like documents and stand apart from the always-on HUD |
| 2026-11-01 | **Godot 4.7.2 stable** installed with winget (user-approved). No `godot` alias (non-admin install); use the full path: `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe` (console build, for `--headless` runs and tests) | Phase 1 needs an engine; the version is recorded so the project file and tests match |

## Notes for Phase 4 (dialogue runtime)
- Fill placeholders **per thread for places** (`{town}`, `{village}`, `{fief}`, factions), so one
  conversation always means the same place, but **per line for amounts** (`{gold}`, `{troop_count}`),
  or every bet in a thread is the same size (seen in conv_053).
- Godot's `String.format(dict)` fills `{name}` placeholders directly.

## Open questions
- Working title
