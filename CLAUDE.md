# Project Marches (working title)

A single-player medieval sandbox on a **full-continent campaign map**, built in **Godot 4 (GDScript)**.
The world is populated by ~120 simulated "real players" (lords/mercenaries with usernames, chat styles,
grudges). Their chat, whispers and encounter dialogue are **pre-generated offline** by Claude Haiku via the
`claude` CLI. The game makes **zero LLM calls at runtime**; it selects pre-written lines from game state.

Original setting only: own continent, factions, names. Do not reuse names, lore or assets from any
existing game.

## Read order for any agent
1. `docs/PROGRESS.md` - what is done, what is next, decision log. **Start here.**
2. `docs/PLAN.md` - phases, architecture, acceptance criteria.
3. The spec for the phase you are working on (e.g. `docs/specs/pipeline.md` for Phase 0).

## Repo layout (target)
```
CLAUDE.md
docs/        PLAN.md, PROGRESS.md, specs/
pipeline/    Python 3.11+ offline content generator (Phase 0)
game/        Godot 4 project (Phase 1+); game/data/ is written by the pipeline bundler
```

## Tools on this machine
- Pipeline: `.venv/Scripts/python -m pipeline <command>` (setup: `python -m venv .venv`, then
  `.venv/Scripts/python -m pip install -r pipeline/requirements.txt`). Tests: `.venv/Scripts/python -m pytest -q`.
- Godot 4.7.2 (no PATH alias): `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe`
  Use `tools/godot.sh import` (after adding `class_name` scripts), `tools/godot.sh test` (headless
  GDScript tests; fails on any SCRIPT ERROR), `tools/godot.sh shot <png> [--zoom=0.22] [--travel]`
  (opens a window briefly, prints FPS, saves a screenshot you can read back to check visuals).
  The campaign map is 3D only (the 2D map was removed after G6). `--click=x,y` simulates a left click at a pixel;
  `--focus=<settlement id>` centres the camera, `--watch-siege` runs at 4x until an AI siege and frames
  it, `--capture-test` (3D) times how fast a captured castle is recoloured, `--parties=300`
  stress-tests at 4x, `--hover-party` checks the hover card, `--battle-auto` shows the battle aftermath. Every shot prints an "AUTO profile"
  line (render CPU/GPU ms, draw calls). FPS varies ~2x between sessions on this machine: compare
  only against a baseline run (e.g. a plain `shot` at the same zoom) made in the same session.
  3D map look at far/mid/near: `<godot> --path game --windowed --resolution 1600x900 -s
  res://tests/preview_terrain3d.gd -- --out=<dir>`.
- Map: `.venv/Scripts/python tools/gen_map.py` regenerates `game/data/world/{terrain,layout}.json`.
- Reports (headless, `<godot> --headless --path game -s res://tests/<script>.gd -- [args]`):
  `balance_report.gd` (battles), `year_report.gd` (politics over a year), `bench_sim.gd` (sim speed),
  `playtest.gd` (20-minute bot session; chat metrics and transcript in `pipeline/out/reports/`).

## Rules for agents
- Work on **one milestone at a time**: the first unchecked item in `docs/PROGRESS.md`.
- A milestone is done only when its **acceptance criteria** are met and you have run the check
  (command output, test result, or sample printed). No evidence = not done.
- When you finish or stop, update `docs/PROGRESS.md`: tick items, add notes, and log any decision
  in the Decision Log with the date.
- **Data contracts are shared** between `pipeline/` and `game/`. Changing a schema means updating
  `pipeline/schemas/`, `docs/specs/pipeline.md` (Data contracts section) and the Godot loader together.
- Never call an LLM from game code. Content generation lives only in `pipeline/`.
- Prefer data-driven design: tunables in JSON/TOML, not hard-coded constants.
- Verify CLI flags before relying on them (`claude --help`, `godot --help`); do not guess.
