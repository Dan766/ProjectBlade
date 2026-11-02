# Spec: Phase 0 - Content Pipeline

Offline Python tool that uses Claude Haiku (through the `claude` CLI) to generate all world text and
fake-player dialogue, then validates, dedupes and bundles it for Godot.

## 1. Goals and non-goals
- **Goals:** resumable, idempotent, parallel, cheap, auditable (every line traceable to its job and
  prompt version), human-reviewable.
- **Non-goals:** runtime generation, map geometry (placement is done in Godot; the pipeline only
  supplies names and lore by id).

## 2. Layout
```
pipeline/
  __main__.py          CLI entry: python -m pipeline <command>
  llm.py               claude CLI wrapper (single call, retries, cost capture)
  jobs.py              job model, hashing, resumable runner, thread pool
  stages/
    world.py           S0
    personas.py        S1
    pools.py           S2
    signatures.py      S3
    conversations.py   S4
  validate.py          schema + rule checks
  dedupe.py
  bundle.py
  report.py
  config/
    pipeline.toml      model, concurrency, budget cap, retries, scale knobs
    world.toml         factions seed: culture flavour, naming style hints, counts
    archetypes.toml    style bibles (hand-authored)
    events.toml        event taxonomy: channels, allowed placeholders, min variants
    blocklist.txt      banned words/phrases (strong profanity, real-world brands, AI-isms)
  prompts/             *.md templates, {{var}} substitution; each file carries a version header
  schemas/             JSON Schemas for every output (the data contracts)
  out/
    raw/<stage>/<job_id>.json        exact model output + meta (commit this)
    validated/<stage>/...            after validate + dedupe
    reports/                         coverage and cost reports
  tests/               pytest: parser, validator, dedupe, bundle, fake-LLM end-to-end run
```

## 3. CLI
```
python -m pipeline smoke                      # one tiny real call, prints parsed result + cost
python -m pipeline config                     # cross-check config/*.toml, print generation sizing
python -m pipeline run <stage> [--limit N] [--only ID] [--force] [--jobs 8] [--dry-run]
python -m pipeline validate [<stage>]
python -m pipeline dedupe
python -m pipeline bundle                     # writes game/data/...
python -m pipeline report                     # coverage gaps, counts, total cost
python -m pipeline sample <archetype|persona_id> [<event>] [-n 10]   # human review
python -m pipeline all                        # run every stage, then validate, dedupe, bundle, report
```
`--dry-run` renders prompts to `out/dryrun/` without calling the model (use it to review prompts).
Set the env var `PIPELINE_FAKE_LLM=1` to swap in a deterministic fake for tests.

## 4. LLM wrapper (`llm.py`)
- Locate the binary with `shutil.which("claude")` (on Windows this may resolve to `claude.cmd`).
- Invoke roughly: `claude -p --model haiku --output-format json`, with **the prompt on stdin**
  (Windows command-line length limit is about 32k characters).
- **Isolation:** run with `cwd` set to an empty temp dir so no project `CLAUDE.md` is loaded. Check
  `claude --help` for flags that disable tools and skip user settings, hooks and plugins, and use them
  if they exist. The developer's machine has plugins with hooks that would otherwise inject context.
  Record the flags you chose in the Decision Log.
- Parse the outer JSON (CLI envelope). Take the `result` text, strip a code fence if present, and
  `json.loads` it. Capture cost and usage fields from the envelope if present (verify field names).
- **Implemented in 0.1:** the flags are in `pipeline.toml` (`extra_args`). Every prompt gets a closing
  JSON instruction with the schema attached (`with_json_instruction`). The wrapper prefers
  `structured_output` when present, otherwise parses `result`, and always re-validates with
  jsonschema. Cost comes from `total_cost_usd`. See the Decision Log for why.
- On a parse or schema failure: retry up to `retries` times, appending the error to the prompt
  ("Your previous output failed: <error>. Return ONLY valid JSON."). Then mark the job failed.
- Respect `budget_usd` in `pipeline.toml`. Abort the run when the cumulative cost exceeds it.

## 5. Job model (`jobs.py`)
```
Job { stage, job_id, prompt_file, vars: dict, schema: str }
prompt_hash = sha256(prompt_file version + rendered prompt)
```
- Output goes to `out/raw/<stage>/<job_id>.json`:
  `{ "meta": {job_id, stage, prompt_file, prompt_hash, model, cost_usd, attempts, retry_errors, created_at}, "data": <parsed> }`
- **Implemented in 0.3** (`pipeline/jobs.py`). Templates live in `prompts/*.md`. The first line must be
  `<!-- version: N -->`, and `{{var}}` is filled from `Job.vars` (non-strings are JSON-encoded).
  Single-brace `{player}` is left untouched. The hash covers version + rendered prompt + schema + model,
  so fake-LLM outputs are never treated as current for real runs. All prompts are rendered before the
  first call, so template mistakes cost nothing. Stages register in `pipeline/stages/__init__.py`
  (`STAGES`). `smoke` is a 3-job real stage (~$0.012) for end-to-end checks.
- Prompts must state the length limits in words (e.g. "under 140 characters"), not only in the schema.
  Long-winded archetypes (roleplayer, politician) are the most likely to overrun them.
- **Resumable:** skip a job if the file exists and `prompt_hash` matches. `--force` regenerates.
  Editing a prompt therefore regenerates only the affected jobs.
- Thread pool (`jobs` from config, default 8). Progress line: done/total, failures, running cost.
- Failures are written to `out/raw/<stage>/_failed.jsonl` and do not stop the run.

## 6. Stages

### S0 world - names and lore
Input: `world.toml` (6 factions, each with a culture flavour such as "river-trade republic" or
"steppe horse clans", a naming-style hint, and settlement counts).
Jobs: 1 per faction.
Output per faction: `name`, `adjective`, `ruler_title`, `short_lore` (≤ 400 characters), `colors` hint,
`troop_names` (3 types × 3 tiers), and settlement names for its share of towns, castles and villages,
each with a ≤ 120 character blurb.
Constraint: names unique continent-wide (validator checks) and not taken from known fiction (blocklist
plus the prompt instruction).

**Implemented in 0.4** (`stages/world.py`, prompts `world_faction.md` v2 + `world_continent.md`):
- 7 jobs: one per faction plus `continent`, which proposes 6 candidate continent names (the choice is a
  human decision, recorded in `world.toml` `continent.name`).
- Each faction job asks for spare settlement names (`REQUEST`: 6 towns / 9 castles / 21 villages). The
  post step (`run world` runs it automatically) picks each faction's quota and drops names that are
  duplicates, within 1 edit of a taken name, blocklisted, or contain digits or symbols. **Names the
  faction's lore mentions are picked first**, and it warns if the lore mentions a dropped one. If a
  faction runs short it errors with the exact rerun command.
- **Banner colours are hand-set** in `world.toml` (the config check rejects primaries that are too
  alike), not generated: parallel jobs all chose gold.
- **Troop names = flavour word + English role word** ("Kopnik Spearmen"). v1 produced bare foreign
  words that players couldn't read.
- **Settlement ids are positional** (`town_03_02` = faction_03's 2nd town), so names can be regenerated
  without breaking the Godot layout that refers to ids.
- Outputs: `out/validated/world/factions.json`, `settlements.json`, `continent_candidates.json`.

### S1 personas - the fake players
Input: archetype and faction distribution from `pipeline.toml`, faction names from S0.
Jobs: batches of 10 personas (~12 jobs).
Persona schema:
```json
{ "id": "persona_017", "username": "xX_saltmarsh_Xx", "archetype": "griefer",
  "faction": "faction_03", "chat_style": {"case": "lower", "typos": "frequent", "emoticons": "rare",
  "punctuation": "none", "verbosity": "short"},
  "traits": ["vindictive", "funny"], "backstory": "...", "catchphrases": ["..."],
  "ai_weights": {"raid": 0.8, "trade": 0.1, "flee_threshold": 0.3, "aggression": 0.9},
  "rivals": [] }
```
`rivals` are filled after generation by a deterministic post-step (seeded random within and across
factions), not by the model. `ai_weights` start from archetype defaults in `archetypes.toml`; the model
may adjust them within ±0.2 (the validator clamps).

**Implemented in 0.5** (`stages/personas.py`, prompt `personas.md` v2, schema `personas_batch.schema.json`):
- **Planning happens before any call and is seeded** (`pipeline.toml [personas] seed`). Archetype counts
  use largest-remainder rounding of the shares. Archetypes are dealt round-robin so each faction's mix
  is within ±1. Each slot gets a fixed id (`persona_001`..`120`, faction-major), a username style
  (roleplayers only get titled, fantasy or CamelCase styles) and a **unique inspiration word**. That
  word is what stops parallel jobs from all converging on the same username.
- 12 jobs (`faction_0N_bK`, 10 slots each). The prompt includes the faction lore, its real
  place names, and the guides for the archetypes in the batch.
- The model returns `ai_adjust` (each -0.2..0.2), not weights; the post step computes
  `ai_weights = clamp(default + adjust)`.
- Post step: every slot must come back with its own id. Username collisions get a digit suffix
  (warning). Blocklist hits are errors. Backstories may use only `{rival}`, which the post step
  **replaces with the username of the persona's first assigned rival**. Catchphrases may use `{player}`
  and `{rival}`. It warns when a catchphrase copies an archetype example (token Jaccard ≥ 0.6;
  `copies_example` should be reused by S2/S3 validation). Rivals: every persona gets 1 cross-faction
  rival and about half also get a same-faction rival; links are symmetric, capped at 3, deterministic.
- `personas` always runs at full scale; `scale.pilot` only limits S2–S4.
- Output: `out/validated/personas/personas.json` (fields as in the example above, plus final
  `ai_weights` and `rivals`).

### S2 archetype pools - the bulk of the dialogue
Jobs: 1 per (archetype × event). Each job returns every relationship band × channel allowed for that
event, with `min_variants` lines each. About 8 archetypes × ~30 events ≈ 240 jobs.
The prompt includes the archetype style bible, the event description, the allowed placeholders and
3 example lines.

**Implemented in 0.6** (`stages/pools.py`, prompt `pools.md` v2, shared checks in `pipeline/textcheck.py`):
- Job id `<archetype>__<event>`. Each job gets **its own JSON Schema** (`Job.schema_inline`), built from
  the event's cells: exact relationship and channel keys, `min_variants + SPARE(2)` lines per cell,
  and maxLength per channel. The prompt also spells out the JSON shape (`shape()`), because without
  it Haiku sometimes nested relationships wrongly.
- While `scale.pilot = true`, only `[pilot]` archetypes × events run.
- Post-step filter per cell (`filter_cell`): placeholder not allowed for the event, stray brace,
  blocklist, copies an archetype tone sample (Jaccard ≥ 0.6), near-duplicate within the cell
  (Jaccard ≥ 0.8). Fewer than `min_variants` left is an error that names the rerun command; the
  stage then writes nothing.
- Prompt rules learned in the pilot: never assume the player's gender ("ser" is neutral in this
  realm), and never copy the tone samples. Placeholder descriptions are written from the speaker's
  point of view (`{persona}` = YOUR OWN name, `{rival}` = never the human player).
- `python -m pipeline sample <archetype> [<event>] [-n N] [--seed S]` prints random lines per cell for review.
- Output: `out/validated/pools/<archetype>.json` = `{event: {relationship: {channel: [{id, text}]}}}`.

### S3 persona signatures - the individual voice
Jobs: 1 per persona (~120).
Output: 3–5 lines each for that persona's top ~10 events (chosen by archetype in `archetypes.toml`),
plus greetings, farewells, and 5 ambient lines in their exact chat style.
At runtime, signature lines win over pool lines with probability `signature_bias` (default 0.35).

**Implemented in 0.7** (`stages/signatures.py`, prompt `signatures.md`): one job per persona; events
= archetype `top_events` + `ambient_chatter`; 3–5 lines per event, **each line tagged with a
`channel` and `rel`** valid for the event (the per-persona schema enforces the enums). The post step
reuses the pools `filter_cell` (tone samples AND the persona's own catchphrases count as "examples"
not to copy), drops lines over the channel length, and requires ≥ 2 kept per event. Output
`out/validated/signatures/signatures.json` = `{persona_id: {username, signature: {event: [{id, channel, rel, text}]}}}`.
(The separate greetings/farewells/ambient lists from the original sketch were dropped; they are the
`encounter_*` and `ambient_chatter` events.)

### S4 conversations - scripted server drama
Jobs: about 60, each returning 5 threads. Inputs: 2–4 personas (cards included), a topic seed
(trade dispute, accusation of cheating, recruitment drive, faction politics, a newbie asking for help),
and their relationships.
Thread schema: `{ id, participants[], trigger: "ambient"|<event>, lines: [{speaker, text, delay_s}] }`
Up to 8 lines. Placeholders allowed.

**Implemented in 0.7** (`stages/conversations.py`, prompt `conversations.md`, `pipeline.toml [conversations]`):
seeded plan of 300 threads in 60 jobs of 5. Each thread has 2–4 participants, picked least-used-first
so everyone appears; about half are built around a rival pair, and same-faction partners are
favoured. About 30% react to a world event (`event_triggers`), told from the first participant's
point of view; the rest use an ambient `topics` entry. The job schema pins each thread's `speaker`
enum to its participants' usernames. Placeholders: town/village/gold/troop_count plus the trigger
event's, **minus `{persona}` and `{my_faction}`** (ambiguous with several speakers; they name their
faction directly). The post step maps usernames to persona ids, sets the first delay to 0, drops bad
lines, and errors on threads with < 3 lines or a silent participant.
Output `out/validated/conversations/conversations.json`.

## 7. Event taxonomy (`events.toml`)
**`config/events.toml` is the source of truth** (34 events as of 0.2). Each event lists its channels,
relationship bands (or `["any"]`), placeholders and frequency (common/normal/rare → min variants).
The table below is an overview.

Relationship bands: `hostile` (< -30), `neutral`, `friendly` (> 30).
Channels: `global`, `whisper`, `face`. Each event lists its allowed channels and placeholders.

| Group | Events |
|---|---|
| Combat | `beat_by_player`, `beat_by_player_repeat` (3+), `beat_player`, `player_fled_from_me`, `captured_by_player`, `released_by_player`, `fought_alongside_player` |
| Territory | `player_besieging_my_fief`, `player_took_my_fief`, `player_raided_my_village`, `my_faction_took_fief` |
| Diplomacy | `war_declared`, `peace_made`, `player_joined_my_faction`, `player_left_my_faction` (betrayal), `player_granted_fief` |
| Fame | `player_win_streak`, `player_big_defeat`, `player_renown_up` |
| Encounter (face) | `encounter_greeting`, `encounter_threatened`, `encounter_trade_offer`, `encounter_alliance_yes`, `encounter_alliance_no`, `encounter_farewell` |
| Whisper openers | `whisper_challenge`, `whisper_alliance_offer`, `whisper_beg_help`, `whisper_taunt` |
| Ambient (global) | `ambient_chatter`, `ambient_trade`, `ambient_lfg`, `ambient_complaint`, `ambient_brag` |

Placeholder whitelist: `{player}` `{persona}` `{town}` `{castle}` `{village}` `{fief}` `{faction}`
`{my_faction}` `{enemy_faction}` `{rival}` `{troop_count}` `{gold}`.

## 8. Archetypes (`archetypes.toml`, hand-authored)
`griefer`, `trader`, `roleplayer`, `tryhard`, `newbie`, `memer`, `veteran_mentor`, `politician`.
Each has: a style bible (tone, vocabulary, do and don't lists), default `chat_style`, default
`ai_weights`, `top_events` for signatures, and 3 golden example lines per channel.
**These files are where the game's personality is decided. A human should review them before S2.**

## 9. Validation rules (`validate.py`)
1. Output matches its JSON Schema.
2. Text length: global and whisper ≤ 140 characters, face ≤ 220, lore and blurbs within their limits.
3. Placeholders are a subset of the event's allowed list. No stray `{` or `}`.
4. Blocklist: strong profanity, real-world brands and games, AI-isms ("as an AI",
   "I cannot"), and meta-talk about being generated.
5. Unique ids, usernames and settlement names. Persona `faction` and `archetype` must exist.
6. Light style checks: a persona marked `case: lower` must have lowercase signature lines (warning,
   not error).
Output: errors (the line is dropped) and warnings (kept), written to `out/reports/validation.json`.

## 10. Dedupe (`dedupe.py`)
Within each pool cell: normalise (lowercase, strip punctuation and placeholders), drop exact
duplicates, then drop near-duplicates with token Jaccard ≥ 0.8. Across archetypes, only report
duplicates, don't drop them.

**Implemented in 0.8** (`pipeline/validate.py`, `pipeline/report.py`):
- `validate` re-runs every stage's post step in order (world → personas → pools → signatures →
  conversations). A stage with errors marks later stages as skipped. Then cross-stage checks run:
  errors for unknown persona ids in signatures/conversations; warnings for lines pairing
  `{player}`/`{rival}` with a gendered word, pool lines naming a real persona, and lines shared
  across archetype pools. Writes `out/reports/validation.json`.
- Dedupe is done where the data lives: within a cell (pools), against tone samples and catchphrases,
  and **signature vs the archetype pool** (signature lines near-duplicating a pool line, Jaccard ≥ 0.8,
  are dropped). `dedupe` only reports cross-archetype sharing, which is allowed.
- `report` covers the FULL taxonomy whatever `scale.pilot` says: pool cells at `min_variants`,
  signature gaps, counts, total cost from raw meta, and failed jobs that still have no output.
  It exits 1 on any gap.
- `sample` takes an archetype id, a persona id or username (signature lines), or `conversations`.
- No slur list (user decision): the prompts' content rating forbids slurs.
  Open questions).

## 11. Bundle - data contract with Godot (`bundle.py`)
**As implemented in 0.9 (supersedes the sketch below):** the bundle goes to `game/data/generated/`,
a directory the pipeline owns completely, so hand-authored game data elsewhere in `game/data/` is
never touched. It is built in `generated.tmp`, checked against `schemas/bundle_*.schema.json` plus
cross-references and file hashes, and only then swapped in; on failure the live bundle is unchanged
and `generated.tmp` is left for inspection. `bundle` refuses to run unless `validate` passes. Extra
file: `events.json` (taxonomy + placeholders + relationship bands) for the game's EventBus and
DialogueDB. Persona dialogue files are `{username, signature: {event: [{id, channel, rel, text}]}}`.
Placeholders stay `{name}`, the exact syntax Godot's `String.format(dict)` fills.
`all` = run every stage (resumable) → report → bundle.

```
game/data/
  manifest.json            { version, generated_at, counts, prompt_hashes_digest }
  world/factions.json      [ {id, name, adjective, lore, troop_names, colors} ]
  world/settlements.json   [ {id, faction, type, name, blurb} ]      # positions come from layout.json
  personas.json            [ persona objects, see S1 ]
  dialogue/archetypes/<archetype>.json
      { "<event>": { "<relationship>": { "<channel>": [ {id, text, weight} ] } } }
  dialogue/personas/<persona_id>.json
      { "signature": { "<event>": [ {id, text} ] }, "greetings": [], "farewells": [], "ambient": [] }
  dialogue/conversations.json  [ thread objects, see S4 ]
```
Line ids are stable: `<scope>.<event>.<rel>.<channel>.<n>`. The bundler writes atomically (temp dir,
then rename) and fails if `validate` has unresolved errors.

## 12. Milestones (Phase 0)
| # | Milestone | Acceptance |
|---|---|---|
| 0.1 | Scaffolding, `llm.py`, `smoke` command, fake LLM, pytest setup | `smoke` prints parsed JSON and cost; `pytest` passes |
| 0.2 | Config files: `pipeline.toml`, `world.toml`, `archetypes.toml`, `events.toml`, blocklist | Loads without error; **human approves archetypes** |
| 0.3 | Job runner: hashing, resume, threads, budget cap, failure log | Fake-LLM test: rerun skips everything; a prompt edit reruns only affected jobs |
| 0.4 | S0 world | 6 factions plus all settlement names; uniqueness validated |
| 0.5 | S1 personas + rivals post-step | 120 valid personas, distribution matches config |
| 0.6 | S2 pools **pilot**: 2 archetypes × 6 events | `sample` reviewed by a human; prompt tuned; then run all |
| 0.7 | S3 signatures, S4 conversations | Valid outputs for all personas; 300 threads |
| 0.8 | Validate, dedupe, report, sample | `report` shows 0 cells under `min_variants` |
| 0.9 | Bundle into `game/data/` + contract tests | Bundle schema tests pass; `all` runs end-to-end from clean |

## 13. Budget and scale knobs (`pipeline.toml`)
`model = "haiku"`, `jobs = 8`, `retries = 3`, `budget_usd`, `personas = 120`,
`min_variants = 6`, `pilot = true|false`. Start with `pilot = true` (small counts) and scale once the
output quality is approved.
