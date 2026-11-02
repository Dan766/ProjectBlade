"""S4 conversations: scripted multi-speaker threads that play back in global chat.

Planning is seeded (pipeline.toml [conversations]) and happens before any call. Each thread gets
2-4 participants (about half built around a rival pair, so drama follows the rival graph, and
participants are picked least-used-first so every persona shows up), plus either an ambient topic
or a world-event trigger. Jobs carry `per_job` threads each; the job schema pins every thread's
speaker list to its participants' usernames.

Post step: drop lines with disallowed placeholders, stray braces or blocklisted phrases; a thread
left with < 3 lines, or where a participant never speaks, is an error naming the rerun.
Output: out/validated/conversations/conversations.json =
    [{"id", "trigger", "topic", "participants": [persona ids], "lines": [{"speaker", "text", "delay_s"}]}]
"""
from __future__ import annotations

import json
import random
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from .. import textcheck
from ..jobs import Job, _atomic_write
from . import PostResult
from .signatures import load_faction_names, load_personas

AMBIENT_PLACEHOLDERS = ("town", "village", "gold", "troop_count")
LINES_MIN, LINES_MAX = 3, 8


@dataclass(frozen=True)
class Thread:
    id: str
    trigger: str            # "ambient" or an event id
    topic: str
    participants: tuple[str, ...]   # persona ids


def plan_threads(cfg: dict, personas: list[dict]) -> list[Thread]:
    c = cfg["pipeline"]["conversations"]
    rng = random.Random(c["seed"])
    by_id = {p["id"]: p for p in personas}
    used: Counter = Counter({p["id"]: 0 for p in personas})
    threads = []
    for i in range(c["threads"]):
        size = rng.choice((2, 2, 3, 3, 4))
        low = min(used.values())
        first = rng.choice(sorted(pid for pid, n in used.items() if n == low))
        group = [first]
        if rng.random() < 0.5 and by_id[first]["rivals"]:
            group.append(rng.choice(by_id[first]["rivals"]))
        same = [q for q in personas if q["faction"] == by_id[first]["faction"] and q["id"] not in group]
        others = [q for q in personas if q["id"] not in group]
        while len(group) < size:
            pick_from = same if same and rng.random() < 0.5 else others
            pick_from = sorted((q for q in pick_from if q["id"] not in group), key=lambda q: (used[q["id"]], q["id"]))
            q = rng.choice(pick_from[: max(5, len(pick_from) // 4)])
            group.append(q["id"])
        for pid in group:
            used[pid] += 1
        if rng.random() < c["event_share"]:
            trigger = rng.choice(c["event_triggers"])
            topic = cfg["events"]["events"][trigger]["desc"]
        else:
            trigger, topic = "ambient", rng.choice(c["topics"])
        threads.append(Thread(f"conv_{i + 1:03d}", trigger, topic, tuple(group)))
    return threads


def allowed_placeholders(cfg: dict, t: Thread) -> list[str]:
    extra = cfg["events"]["events"][t.trigger]["placeholders"] if t.trigger != "ambient" else []
    # {persona}/{my_faction} are ambiguous with several speakers; speakers name their own faction directly.
    return sorted((set(AMBIENT_PLACEHOLDERS) | set(extra)) - {"persona", "my_faction"})


def batches(cfg: dict, threads: list[Thread]) -> dict[str, list[Thread]]:
    n = cfg["pipeline"]["conversations"]["per_job"]
    return {f"conv_b{k // n + 1:02d}": threads[k:k + n] for k in range(0, len(threads), n)}


def _card(p: dict, cfg: dict, factions: dict[str, str]) -> str:
    s = p["chat_style"]
    style = f"{s['case']} case, {s['typos']} typos, {s['emoticons']} emoticons, {s['punctuation']} punctuation, {s['verbosity']}"
    return (f"  - {p['username']}: {cfg['archetypes'][p['archetype']]['label']} of {factions[p['faction']]}; "
            f"{', '.join(p['traits'])}; types: {style}; says things like '{p['catchphrases'][0]}'")


def schema_for(batch: list[Thread], names: dict[str, str]) -> dict:
    props = {}
    for t in batch:
        props[t.id] = {"type": "array", "minItems": LINES_MIN, "maxItems": LINES_MAX, "items": {
            "type": "object",
            "properties": {
                "speaker": {"enum": [names[pid] for pid in t.participants]},
                "text": {"type": "string", "minLength": 1, "maxLength": 140},
                "delay_s": {"type": "integer", "minimum": 0, "maximum": 60},
            },
            "required": ["speaker", "text", "delay_s"], "additionalProperties": False}}
    return {"type": "object", "properties": props, "required": [t.id for t in batch], "additionalProperties": False}


def jobs(cfg: dict) -> list[Job]:
    personas, factions = load_personas(), load_faction_names()
    by_id = {p["id"]: p for p in personas}
    names = {p["id"]: p["username"] for p in personas}
    ph = cfg["events"]["placeholders"]
    out = []
    for jid, batch in batches(cfg, plan_threads(cfg, personas)).items():
        blocks = []
        for t in batch:
            rivals = [f"{names[a]} and {names[b]} are rivals" for i, a in enumerate(t.participants)
                      for b in t.participants[i + 1:] if b in by_id[a]["rivals"]]
            what = (f"Reacting to news, told from {names[t.participants[0]]}'s point of view: {t.topic} "
                    f"The others react to it." if t.trigger != "ambient" else f"Topic: {t.topic}")
            blocks.append(
                f"{t.id}. {what}\n  Participants:\n" + "\n".join(_card(by_id[pid], cfg, factions) for pid in t.participants)
                + (f"\n  Note: {'; '.join(rivals)}." if rivals else "")
                + "\n  Placeholders allowed: " + ", ".join(f"{{{x}}} ({ph[x]})" for x in allowed_placeholders(cfg, t)))
        out.append(Job("conversations", jid, "conversations.md", schema_inline=schema_for(batch, names), vars={
            "continent": cfg["world"]["continent"]["name"] or "the continent",
            "count": str(len(batch)), "threads": "\n\n".join(blocks),
            "rating": cfg["pipeline"]["content"]["rating"],
        }))
    return out


def post(cfg: dict, raw_dir: Path, out_dir: Path) -> PostResult:
    res = PostResult()
    personas = load_personas(out_dir)
    ids_by_name = {p["username"]: p["id"] for p in personas}
    plan = batches(cfg, plan_threads(cfg, personas))
    out, dropped_total = [], 0
    for jid, batch in plan.items():
        path = raw_dir / "conversations" / f"{jid}.json"
        if not path.exists():
            res.errors.append(f"missing output for {jid}; run `python -m pipeline run conversations`")
            continue
        data = json.loads(path.read_text(encoding="utf-8"))["data"]
        for t in batch:
            # {player} is accepted in every thread even when the prompt didn't offer it: the server
            # gossiping about the human player is a feature, and dropping a line mid-conversation
            # breaks the thread (0.7 run: 23 such lines left 3 threads too short).
            allowed = set(allowed_placeholders(cfg, t)) | {"player"}
            lines = []
            for ln in data[t.id]:
                text = ln["text"].strip()
                bad = textcheck.placeholders(text) - allowed
                hit = textcheck.blocklist_hit(text, cfg["blocklist"])
                if bad or hit or textcheck.stray_brace(text):
                    dropped_total += 1
                    res.warnings.append(f"{jid} {t.id}: dropped {text!r} ({sorted(bad) or hit or 'stray brace'})")
                    continue
                lines.append({"speaker": ids_by_name[ln["speaker"]], "text": text, "delay_s": ln["delay_s"]})
            if lines:
                lines[0]["delay_s"] = 0
            silent = [pid for pid in t.participants if pid not in {x["speaker"] for x in lines}]
            if len(lines) < LINES_MIN or silent:
                why = f"{len(lines)} lines" if len(lines) < LINES_MIN else f"silent participant(s) {silent}"
                res.errors.append(f"{jid} {t.id}: {why}; rerun with --only {jid} --force")
            out.append({"id": t.id, "trigger": t.trigger, "topic": t.topic,
                        "participants": list(t.participants), "lines": lines})
    if res.errors:
        return res
    _atomic_write(out_dir / "conversations" / "conversations.json", json.dumps(out, indent=2, ensure_ascii=False))
    triggers = Counter(t["trigger"] == "ambient" for t in out)
    res.summary.append(f"conversations: {len(out)} threads ({triggers[True]} ambient, {triggers[False]} event), "
                       f"{sum(len(t['lines']) for t in out)} lines, {dropped_total} dropped -> {out_dir / 'conversations'}")
    return res
