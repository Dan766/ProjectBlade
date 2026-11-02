"""S3 persona signatures: a personal layer of lines on top of the archetype pools.

One job per persona (120). For each of the archetype's top_events, plus ambient_chatter, the persona
gets 3-5 lines, each tagged with a channel and relationship band valid for that event. At runtime
a matching signature line wins over a pool line with probability `signature_bias` (Phase 4).

Post step: same filters as pools (placeholders, braces, blocklist, copying archetype tone samples,
near-duplicates) plus per-channel length; a persona-event with fewer than KEEP_MIN usable lines is an
error naming the rerun. Output: out/validated/signatures/signatures.json =
    {persona_id: {"username", "signature": {event: [{"id", "channel", "rel", "text"}]}}}
"""
from __future__ import annotations

import json
from pathlib import Path

from .. import config, textcheck
from ..config import event_bands
from ..jobs import Job, _atomic_write
from . import PostResult
from .pools import NEAR_DUP, filter_cell

VALIDATED_DIR = config.OUT_DIR / "validated"
EXTRA_EVENTS = ("ambient_chatter",)
LINES_MIN, LINES_MAX = 3, 5
KEEP_MIN = 2


def load_personas(validated_dir: Path | None = None) -> list[dict]:
    path = (validated_dir or VALIDATED_DIR) / "personas" / "personas.json"
    if not path.exists():
        raise ValueError("signatures need personas first: run `python -m pipeline run personas`")
    return json.loads(path.read_text(encoding="utf-8"))


def load_faction_names(validated_dir: Path | None = None) -> dict[str, str]:
    path = (validated_dir or VALIDATED_DIR) / "world" / "factions.json"
    if not path.exists():
        raise ValueError("signatures need the world stage first: run `python -m pipeline run world`")
    return {f["id"]: f["name"] for f in json.loads(path.read_text(encoding="utf-8"))}


def sig_events(cfg: dict, persona: dict) -> list[str]:
    top = list(cfg["archetypes"][persona["archetype"]]["top_events"])
    return top + [e for e in EXTRA_EVENTS if e not in top]


def schema_for(cfg: dict, events: list[str]) -> dict:
    props = {}
    for eid in events:
        ev = cfg["events"]["events"][eid]
        props[eid] = {"type": "array", "minItems": LINES_MIN, "maxItems": LINES_MAX, "items": {
            "type": "object",
            "properties": {
                "channel": {"enum": list(ev["channels"])},
                "rel": {"enum": list(event_bands(ev))},
                "text": {"type": "string", "minLength": 2, "maxLength": 220},
            },
            "required": ["channel", "rel", "text"], "additionalProperties": False}}
    return {"type": "object", "properties": props, "required": list(events), "additionalProperties": False}


def jobs(cfg: dict) -> list[Job]:
    personas, factions = load_personas(), load_faction_names()
    ph = cfg["events"]["placeholders"]
    out = []
    for p in personas:
        a = cfg["archetypes"][p["archetype"]]
        events = sig_events(cfg, p)
        ev_lines = []
        for eid in events:
            ev = cfg["events"]["events"][eid]
            phs = ", ".join(f"{{{x}}} ({ph[x]})" for x in ev["placeholders"]) or "none"
            ev_lines.append(f"- {eid}: {ev['desc']}\n  channels: {', '.join(ev['channels'])}; "
                            f"relationships: {', '.join(event_bands(ev))}; placeholders: {phs}")
        out.append(Job("signatures", p["id"], "signatures.md", schema_inline=schema_for(cfg, events), vars={
            "continent": cfg["world"]["continent"]["name"] or "the continent",
            "username": p["username"], "faction": factions[p["faction"]],
            "label": a["label"], "tone": " ".join(a["tone"].split()),
            "do": "; ".join(a["do"]), "dont": "; ".join(a["dont"]),
            "traits": ", ".join(p["traits"]), "backstory": p["backstory"],
            "catchphrases": " | ".join(p["catchphrases"]), "chat_style": p["chat_style"],
            "events": "\n".join(ev_lines), "rating": cfg["pipeline"]["content"]["rating"],
        }))
    return out


def post(cfg: dict, raw_dir: Path, out_dir: Path) -> PostResult:
    res = PostResult()
    personas = load_personas(out_dir)
    max_len = cfg["pipeline"]["content"]["max_len"]
    pool_lines: dict[str, dict[str, list[str]]] = {}     # archetype -> event -> texts (if pools are validated)
    for aid in {p["archetype"] for p in personas}:
        f = out_dir / "pools" / f"{aid}.json"
        if f.exists():
            pool = json.loads(f.read_text(encoding="utf-8"))
            pool_lines[aid] = {eid: [x["text"] for r in rels.values() for ls in r.values() for x in ls]
                               for eid, rels in pool.items()}
    result: dict[str, dict] = {}
    kept_total = dropped_total = 0
    for p in personas:
        path = raw_dir / "signatures" / f"{p['id']}.json"
        if not path.exists():
            res.errors.append(f"missing output for {p['id']}; run `python -m pipeline run signatures`")
            continue
        data = json.loads(path.read_text(encoding="utf-8"))["data"]
        a = cfg["archetypes"][p["archetype"]]
        examples = [e for lines in a["examples"].values() for e in lines] + p["catchphrases"]
        sig: dict[str, list] = {}
        for eid in sig_events(cfg, p):
            ev = cfg["events"]["events"][eid]
            entries = []
            for e in data[eid]:
                if len(e["text"].strip()) > max_len[e["channel"]]:
                    res.warnings.append(f"{p['id']} {eid}: dropped too long for {e['channel']}: {e['text']!r}")
                    dropped_total += 1
                else:
                    entries.append(e)
            kept, dropped = filter_cell([e["text"] for e in entries], allowed=set(ev["placeholders"]),
                                        examples=examples, blocklist=cfg["blocklist"])
            # A signature line that near-duplicates the shared archetype pool adds nothing personal.
            pool_texts = pool_lines.get(p["archetype"], {}).get(eid, [])
            for t in list(kept):
                same = next((x for x in pool_texts if textcheck.jaccard(t, x) >= NEAR_DUP), None)
                if same:
                    kept.remove(t)
                    dropped.append(f"duplicates pool line {same!r}: {t!r}")
            dropped_total += len(dropped)
            res.warnings.extend(f"{p['id']} {eid}: dropped {d}" for d in dropped)
            by_text = {e["text"].strip(): e for e in entries}
            sig[eid] = [{"id": f"sig.{p['id']}.{eid}.{i:02d}", "channel": by_text[t]["channel"],
                         "rel": by_text[t]["rel"], "text": t} for i, t in enumerate(kept, 1)]
            kept_total += len(kept)
            if len(kept) < KEEP_MIN:
                res.errors.append(f"{p['id']} {eid}: only {len(kept)}/{KEEP_MIN} usable lines; "
                                  f"rerun with --only {p['id']} --force")
        if p["chat_style"]["case"] == "lower":
            loud = [x["text"] for lines in sig.values() for x in lines
                    if (t := textcheck.EMOTICON.sub("", textcheck.PLACEHOLDER.sub("", x["text"]))) != t.lower()]
            if len(loud) > 3:
                res.warnings.append(f"{p['id']}: types in lowercase but {len(loud)} signature lines use capitals")
        result[p["id"]] = {"username": p["username"], "signature": sig}
    if res.errors:
        return res
    _atomic_write(out_dir / "signatures" / "signatures.json", json.dumps(result, indent=2, ensure_ascii=False))
    res.summary.append(f"signatures: {len(result)} personas, {kept_total} lines kept, {dropped_total} dropped "
                       f"-> {out_dir / 'signatures'}")
    return res
