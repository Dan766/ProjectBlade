"""`python -m pipeline bundle`: the data contract with Godot.

Copies validated outputs into game/data/generated/, a directory the pipeline owns completely
(hand-authored game data such as layout.json or config/*.json lives elsewhere under game/data/
and is never touched). The whole directory is built in a temp dir and swapped in, so the game
never sees a half-written bundle. Refuses to run unless `validate` passes.

Layout (BUNDLE_VERSION 1):
  manifest.json                        {bundle_version, generated_at, continent, counts, files{path: sha256}}
  events.json                          taxonomy the game's EventBus and DialogueDB share
  world/factions.json, world/settlements.json
  personas.json
  dialogue/archetypes/<archetype>.json {event: {rel: {channel: [{id, text}]}}}
  dialogue/personas/<persona_id>.json  {username, signature: {event: [{id, channel, rel, text}]}}
  dialogue/conversations.json          [{id, trigger, topic, participants, lines: [{speaker, text, delay_s}]}]

Placeholders stay as {name}; Godot's String.format(dict) fills exactly that syntax.
"""
from __future__ import annotations

import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import jsonschema

from . import config

BUNDLE_VERSION = 1
GAME_DATA_DIR = config.PIPELINE_DIR.parent / "game" / "data"


def _load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def _dump(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def events_contract(cfg: dict) -> dict:
    ev = cfg["events"]
    return {
        "relationship_bands": ev["relationship_bands"],
        "placeholders": sorted(ev["placeholders"]),
        "events": {eid: {"group": e["group"], "channels": e["channels"],
                         "relationships": config.event_bands(e), "placeholders": e["placeholders"]}
                   for eid, e in sorted(ev["events"].items())},
    }


def build(cfg: dict, validated: Path, dest: Path) -> dict:
    """Write the bundle to `dest` (which must not exist). Returns the manifest."""
    _dump(dest / "events.json", events_contract(cfg))
    _dump(dest / "world" / "factions.json", _load(validated / "world" / "factions.json"))
    _dump(dest / "world" / "settlements.json", _load(validated / "world" / "settlements.json"))
    personas = _load(validated / "personas" / "personas.json")
    _dump(dest / "personas.json", personas)
    pool_lines = 0
    for aid in sorted(cfg["archetypes"]):
        pool = _load(validated / "pools" / f"{aid}.json")
        pool_lines += sum(len(ls) for r in pool.values() for c in r.values() for ls in c.values())
        _dump(dest / "dialogue" / "archetypes" / f"{aid}.json", pool)
    sig = _load(validated / "signatures" / "signatures.json")
    for pid, s in sig.items():
        _dump(dest / "dialogue" / "personas" / f"{pid}.json", s)
    convs = _load(validated / "conversations" / "conversations.json")
    _dump(dest / "dialogue" / "conversations.json", convs)

    files = {p.relative_to(dest).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(dest.rglob("*.json"))}
    manifest = {
        "bundle_version": BUNDLE_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "continent": cfg["world"]["continent"]["name"],
        "counts": {"factions": len(_load(dest / "world" / "factions.json")),
                   "settlements": len(_load(dest / "world" / "settlements.json")),
                   "personas": len(personas), "archetypes": len(cfg["archetypes"]),
                   "events": len(cfg["events"]["events"]), "pool_lines": pool_lines,
                   "signature_lines": sum(len(ls) for s in sig.values() for ls in s["signature"].values()),
                   "conversations": len(convs)},
        "files": files,
    }
    _dump(dest / "manifest.json", manifest)
    return manifest


def check(dest: Path, cfg: dict) -> list[str]:
    """Contract checks on a built bundle: schemas, cross references, file hashes."""
    errs: list[str] = []
    schemas = {n: _load(config.SCHEMA_DIR / f"bundle_{n}.schema.json")
               for n in ("manifest", "persona", "archetype_dialogue", "persona_dialogue", "conversation")}

    def v(name, data, where) -> bool:
        try:
            jsonschema.validate(data, schemas[name])
            return True
        except jsonschema.ValidationError as e:
            errs.append(f"{where}: {e.message} at {'/'.join(map(str, e.absolute_path))}")
            return False

    manifest = _load(dest / "manifest.json")
    v("manifest", manifest, "manifest.json")
    for rel, digest in manifest["files"].items():
        p = dest / rel
        if not p.exists() or hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            errs.append(f"{rel}: missing or hash mismatch")
    personas = _load(dest / "personas.json")
    ids = {p["id"] for p in personas}
    factions = {f["id"] for f in _load(dest / "world" / "factions.json")}
    for p in personas:
        if not v("persona", p, f"personas.json {p.get('id')}") and "faction" not in p:
            continue
        if p["faction"] not in factions:
            errs.append(f"persona {p['id']}: unknown faction {p['faction']}")
        if not (dest / "dialogue" / "personas" / f"{p['id']}.json").exists():
            errs.append(f"persona {p['id']}: no dialogue/personas file")
    events = _load(dest / "events.json")["events"]
    for aid in cfg["archetypes"]:
        pool = _load(dest / "dialogue" / "archetypes" / f"{aid}.json")
        v("archetype_dialogue", pool, f"dialogue/archetypes/{aid}.json")
        missing = sorted(set(events) - set(pool))
        if missing:
            errs.append(f"dialogue/archetypes/{aid}.json: no lines for events {missing[:5]}")
    for f in sorted((dest / "dialogue" / "personas").glob("*.json")):
        v("persona_dialogue", _load(f), f"dialogue/personas/{f.name}")
    for t in _load(dest / "dialogue" / "conversations.json"):
        if not v("conversation", t, f"conversations {t.get('id')}"):
            continue                    # malformed: cross references can't be read
        if set(t["participants"]) - ids or {ln["speaker"] for ln in t["lines"]} - set(t["participants"]):
            errs.append(f"conversation {t['id']}: participant/speaker not a known persona in the thread")
    return errs


def bundle(cfg: dict, validated: Path, game_data: Path = GAME_DATA_DIR) -> tuple[dict, list[str]]:
    """Build into a temp dir next to the target, check it, then swap it in."""
    target = game_data / "generated"
    tmp = game_data / "generated.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    manifest = build(cfg, validated, tmp)
    errs = check(tmp, cfg)
    if errs:
        return manifest, errs           # leave tmp for inspection; the live bundle is untouched
    old = game_data / "generated.old"
    if old.exists():
        shutil.rmtree(old)
    if target.exists():
        target.rename(old)
    tmp.rename(target)
    if old.exists():
        shutil.rmtree(old)
    return manifest, []
