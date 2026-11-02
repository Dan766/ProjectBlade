"""S2 archetype pools: the bulk of the dialogue.

One job per (archetype, event). Each job returns every (relationship, channel) cell the event
allows (events.toml), with min_variants[frequency] + SPARE lines per cell. The job's JSON Schema
is built per event, so the CLI's structured output enforces the exact cells and per-channel
length limits.

While pipeline.toml scale.pilot is true, only [pilot] archetypes x events run (milestone 0.6).

The post step drops lines that use placeholders the event doesn't allow, contain stray braces or
blocklisted phrases, copy the archetype's tone samples, or near-duplicate another line in the same
cell; then requires min_variants per cell and writes out/validated/pools/<archetype>.json:
    {event: {relationship: {channel: [{"id", "text"}]}}}
"""
from __future__ import annotations

import json
from pathlib import Path

from .. import textcheck
from ..config import event_bands
from ..jobs import Job, _atomic_write
from . import PostResult

SPARE = 2              # extra lines requested per cell, so filtering rarely leaves a cell short
NEAR_DUP = 0.8         # token Jaccard at which two lines in one cell count as the same line


def selection(cfg: dict) -> tuple[list[str], list[str]]:
    if cfg["pipeline"]["scale"]["pilot"]:
        return list(cfg["pipeline"]["pilot"]["archetypes"]), list(cfg["pipeline"]["pilot"]["events"])
    return sorted(cfg["archetypes"]), sorted(cfg["events"]["events"])


def cells(ev: dict) -> list[tuple[str, str]]:
    return [(rel, ch) for rel in event_bands(ev) for ch in ev["channels"]]


def wanted(cfg: dict, ev: dict) -> int:
    return cfg["pipeline"]["scale"]["min_variants"][ev["frequency"]]


def shape(ev: dict) -> str:
    """The exact JSON layout as text, e.g. {"hostile": {"global": ["...", ...]}, ...}. Without it Haiku
    sometimes nested relationships inside each other (0.6 pilot v1: 2 of 12 jobs needed 3-4 attempts)."""
    rels: dict[str, list[str]] = {}
    for rel, ch in cells(ev):
        rels.setdefault(rel, []).append(ch)
    inner = lambda chs: ", ".join(f'"{ch}": ["...", "..."]' for ch in chs)
    return "{" + ", ".join(f'"{rel}": {{{inner(chs)}}}' for rel, chs in rels.items()) + "}"


def schema_for(cfg: dict, ev: dict) -> dict:
    n = wanted(cfg, ev) + SPARE
    max_len = cfg["pipeline"]["content"]["max_len"]
    rels: dict[str, dict] = {}
    for rel, ch in cells(ev):
        node = rels.setdefault(rel, {"type": "object", "properties": {}, "required": [], "additionalProperties": False})
        node["properties"][ch] = {"type": "array", "minItems": n, "maxItems": n + 2,
                                  "items": {"type": "string", "minLength": 2, "maxLength": max_len[ch]}}
        node["required"].append(ch)
    return {"type": "object", "properties": rels, "required": list(rels), "additionalProperties": False}


def jobs(cfg: dict) -> list[Job]:
    archetypes, events = selection(cfg)
    ph_desc = cfg["events"]["placeholders"]
    out = []
    for aid in archetypes:
        a = cfg["archetypes"][aid]
        for eid in events:
            ev = cfg["events"]["events"][eid]
            n = wanted(cfg, ev) + SPARE
            examples = "\n".join(f"  [{ch}] {line}" for ch in ev["channels"] for line in a["examples"][ch])
            out.append(Job("pools", f"{aid}__{eid}", "pools.md", schema_inline=schema_for(cfg, ev), vars={
                "continent": cfg["world"]["continent"]["name"] or "the continent",
                "label": a["label"], "tone": " ".join(a["tone"].split()),
                "do": "; ".join(a["do"]), "dont": "; ".join(a["dont"]),
                "chat_style": a["chat_style"], "examples": examples,
                "event_desc": ev["desc"], "count": str(n),
                "cells": "\n".join(f"- {rel} / {ch}: {n} lines" for rel, ch in cells(ev)),
                "shape": shape(ev),
                "placeholders": "; ".join(f"{{{p}}} = {ph_desc[p]}" for p in ev["placeholders"]) or "(none)",
                "rating": cfg["pipeline"]["content"]["rating"],
            }))
    return out


def filter_cell(lines: list[str], *, allowed: set[str], examples: list[str], blocklist: list[str]) -> tuple[list[str], list[str]]:
    """Return (kept lines, reasons for dropped ones)."""
    kept, dropped = [], []
    for line in (ln.strip() for ln in lines):
        bad = textcheck.placeholders(line) - allowed
        if bad:
            dropped.append(f"placeholder {sorted(bad)}: {line!r}")
        elif textcheck.stray_brace(line):
            dropped.append(f"stray brace: {line!r}")
        elif hit := textcheck.blocklist_hit(line, blocklist):
            dropped.append(f"blocklisted {hit!r}: {line!r}")
        elif textcheck.assumes_gender(line):
            dropped.append(f"assumes the gender of the player or a rival: {line!r}")
        elif ex := textcheck.copies_example(line, examples):
            dropped.append(f"copies example {ex!r}: {line!r}")
        elif dup := next((k for k in kept if textcheck.jaccard(line, k) >= NEAR_DUP
                          or textcheck.normalize(line) == textcheck.normalize(k)), None):
            dropped.append(f"near-duplicate of {dup!r}: {line!r}")
        else:
            kept.append(line)
    return kept, dropped


def post(cfg: dict, raw_dir: Path, out_dir: Path) -> PostResult:
    res = PostResult()
    archetypes, events = selection(cfg)
    total_kept = total_dropped = 0
    pools: dict[str, dict] = {}
    for aid in archetypes:
        a = cfg["archetypes"][aid]
        examples = [e for lines in a["examples"].values() for e in lines]
        pools[aid] = {}
        for eid in events:
            jid = f"{aid}__{eid}"
            path = raw_dir / "pools" / f"{jid}.json"
            if not path.exists():
                res.errors.append(f"missing output for {jid}; run `python -m pipeline run pools`")
                continue
            data = json.loads(path.read_text(encoding="utf-8"))["data"]
            ev = cfg["events"]["events"][eid]
            need = wanted(cfg, ev)
            for rel, ch in cells(ev):
                kept, dropped = filter_cell(data[rel][ch], allowed=set(ev["placeholders"]),
                                            examples=examples, blocklist=cfg["blocklist"])
                total_kept += len(kept)
                total_dropped += len(dropped)
                for d in dropped:
                    res.warnings.append(f"{jid} {rel}/{ch}: dropped {d}")
                if len(kept) < need:
                    res.errors.append(f"{jid} {rel}/{ch}: only {len(kept)}/{need} usable lines; "
                                      f"rerun with --only {jid} --force")
                pools[aid].setdefault(eid, {}).setdefault(rel, {})[ch] = [
                    {"id": f"arch.{aid}.{eid}.{rel}.{ch}.{i:02d}", "text": t} for i, t in enumerate(kept, 1)]
    if res.errors:
        return res
    for aid, pool in pools.items():
        _atomic_write(out_dir / "pools" / f"{aid}.json", json.dumps(pool, indent=2, ensure_ascii=False))
    mode = "PILOT" if cfg["pipeline"]["scale"]["pilot"] else "full"
    res.summary.append(f"pools ({mode}): {len(archetypes)} archetype(s) x {len(events)} event(s): "
                       f"{total_kept} lines kept, {total_dropped} dropped -> {out_dir / 'pools'}")
    return res
