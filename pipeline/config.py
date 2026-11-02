"""Loads pipeline/config/*.toml and cross-checks them (`python -m pipeline config`)."""
from __future__ import annotations

import re
import tomllib
from pathlib import Path

PIPELINE_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PIPELINE_DIR / "config"
OUT_DIR = PIPELINE_DIR / "out"
SCHEMA_DIR = PIPELINE_DIR / "schemas"

CHANNELS = ("global", "whisper", "face")
BANDS = ("hostile", "neutral", "friendly")
FREQUENCIES = ("common", "normal", "rare")
CHAT_STYLE = {
    "case": ("lower", "sentence", "mixed"),
    "typos": ("none", "rare", "frequent"),
    "emoticons": ("none", "rare", "frequent"),
    "punctuation": ("none", "minimal", "proper", "chaotic"),
    "verbosity": ("short", "medium", "long"),
}
PLACEHOLDER_RE = re.compile(r"\{(\w+)\}")


def load(name: str = "pipeline", config_dir: Path = CONFIG_DIR) -> dict:
    with open(config_dir / f"{name}.toml", "rb") as f:
        return tomllib.load(f)


def load_blocklist(config_dir: Path = CONFIG_DIR) -> list[str]:
    lines = (config_dir / "blocklist.txt").read_text(encoding="utf-8").splitlines()
    return [ln.strip().lower() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


def load_all(config_dir: Path = CONFIG_DIR) -> dict:
    return {
        "pipeline": load("pipeline", config_dir),
        "world": load("world", config_dir),
        "archetypes": load("archetypes", config_dir),
        "events": load("events", config_dir),
        "blocklist": load_blocklist(config_dir),
    }


def event_bands(ev: dict) -> list[str]:
    return ev.get("relationships", list(BANDS))


def check(cfg: dict) -> list[str]:
    """Return a list of human-readable problems; empty means the configs are consistent."""
    errs: list[str] = []
    pipe, world, archs = cfg["pipeline"], cfg["world"], cfg["archetypes"]
    events = cfg["events"].get("events", {})
    placeholders = set(cfg["events"].get("placeholders", {}))
    max_len = pipe.get("content", {}).get("max_len", {})

    # world: per-faction settlement counts sum to continent totals
    factions = world.get("factions", {})
    if len(factions) < 2:
        errs.append("world: need at least 2 factions")
    for kind in ("towns", "castles", "villages"):
        total = sum(f.get(kind, 0) for f in factions.values())
        if total != world["continent"][kind]:
            errs.append(f"world: faction {kind} sum to {total}, continent says {world['continent'][kind]}")
    hexes = []
    for fid, f in factions.items():
        for key in ("concept", "naming_hint", "strengths"):
            if not f.get(key):
                errs.append(f"world: {fid} missing {key}")
        for slot in ("primary", "secondary"):
            c = f.get("colors", {}).get(slot, "")
            if not re.fullmatch(r"#[0-9a-fA-F]{6}", c):
                errs.append(f"world: {fid} colors.{slot} must be #rrggbb, got {c!r}")
            else:
                hexes.append((f"{fid}.{slot}", c))
    primaries = [(k, c) for k, c in hexes if k.endswith("primary")]
    for i, (ka, a) in enumerate(primaries):
        for kb, b in primaries[i + 1:]:
            if _color_distance(a, b) < 60:
                errs.append(f"world: banner colours {ka} {a} and {kb} {b} are too alike")
    personas = pipe["scale"]["personas"]
    if factions and personas % len(factions):
        errs.append(f"pipeline: {personas} personas don't split evenly across {len(factions)} factions")

    # events
    min_variants = pipe["scale"]["min_variants"]
    for eid, ev in events.items():
        where = f"events.{eid}"
        if not ev.get("desc"):
            errs.append(f"{where}: missing desc")
        for ch in ev.get("channels", []):
            if ch not in CHANNELS:
                errs.append(f"{where}: unknown channel {ch!r}")
        if not ev.get("channels"):
            errs.append(f"{where}: no channels")
        bands = event_bands(ev)
        if bands != ["any"] and any(b not in BANDS for b in bands):
            errs.append(f"{where}: bad relationships {bands}")
        for ph in ev.get("placeholders", []):
            if ph not in placeholders:
                errs.append(f"{where}: placeholder {ph!r} not in [placeholders]")
        if ev.get("frequency") not in FREQUENCIES:
            errs.append(f"{where}: frequency must be one of {FREQUENCIES}")
        elif ev["frequency"] not in min_variants:
            errs.append(f"{where}: no scale.min_variants for {ev['frequency']!r}")

    # archetypes
    shares = sum(a.get("share", 0) for a in archs.values())
    if abs(shares - 1.0) > 1e-6:
        errs.append(f"archetypes: shares sum to {shares:.3f}, expected 1.0")
    weight_keys = None
    for aid, a in archs.items():
        where = f"archetypes.{aid}"
        for key in ("label", "tone", "do", "dont", "top_events", "chat_style", "ai_weights", "examples"):
            if key not in a:
                errs.append(f"{where}: missing {key}")
        for ev in a.get("top_events", []):
            if ev not in events:
                errs.append(f"{where}: top_event {ev!r} not in events.toml")
        if len(set(a.get("top_events", []))) != len(a.get("top_events", [])):
            errs.append(f"{where}: duplicate top_events")
        for key, allowed in CHAT_STYLE.items():
            if a.get("chat_style", {}).get(key) not in allowed:
                errs.append(f"{where}.chat_style.{key}: must be one of {allowed}")
        weights = a.get("ai_weights", {})
        if weight_keys is None:
            weight_keys = set(weights)
        elif set(weights) != weight_keys:
            errs.append(f"{where}.ai_weights: keys differ from other archetypes")
        for k, v in weights.items():
            if not 0.0 <= v <= 1.0:
                errs.append(f"{where}.ai_weights.{k}: {v} outside 0..1")
        for ch, lines in a.get("examples", {}).items():
            if ch not in CHANNELS:
                errs.append(f"{where}.examples: unknown channel {ch!r}")
                continue
            for line in lines:
                for ph in PLACEHOLDER_RE.findall(line):
                    if ph not in placeholders:
                        errs.append(f"{where}.examples.{ch}: unknown placeholder {{{ph}}} in {line!r}")
                if PLACEHOLDER_RE.sub("", line).count("{") or PLACEHOLDER_RE.sub("", line).count("}"):
                    errs.append(f"{where}.examples.{ch}: stray brace in {line!r}")
                if ch in max_len and len(line) > max_len[ch]:
                    errs.append(f"{where}.examples.{ch}: {len(line)} chars > {max_len[ch]}: {line!r}")
                low = line.lower()
                for phrase in cfg["blocklist"]:
                    if re.search(rf"(?<!\w){re.escape(phrase)}(?!\w)", low):
                        errs.append(f"{where}.examples.{ch}: blocklisted {phrase!r} in {line!r}")

    # pilot subset must exist
    pilot = pipe.get("pilot", {})
    for aid in pilot.get("archetypes", []):
        if aid not in archs:
            errs.append(f"pilot: unknown archetype {aid!r}")
    for eid in pilot.get("events", []):
        if eid not in events:
            errs.append(f"pilot: unknown event {eid!r}")
    return errs


def _color_distance(a: str, b: str) -> float:
    ra, ga, ba = (int(a[i:i + 2], 16) for i in (1, 3, 5))
    rb, gb, bb = (int(b[i:i + 2], 16) for i in (1, 3, 5))
    return ((ra - rb) ** 2 + (ga - gb) ** 2 + (ba - bb) ** 2) ** 0.5


def summary(cfg: dict) -> dict:
    """Counts that size the generation work (S2 is one job per archetype x event)."""
    events = cfg["events"]["events"]
    mv = cfg["pipeline"]["scale"]["min_variants"]
    cells_per_arch = sum(len(event_bands(e)) * len(e["channels"]) for e in events.values())
    lines_per_arch = sum(len(event_bands(e)) * len(e["channels"]) * mv[e["frequency"]] for e in events.values())
    n_arch = len(cfg["archetypes"])
    return {
        "factions": len(cfg["world"]["factions"]),
        "settlements": sum(cfg["world"]["continent"][k] for k in ("towns", "castles", "villages")),
        "personas": cfg["pipeline"]["scale"]["personas"],
        "archetypes": n_arch,
        "events": len(events),
        "pool_cells": cells_per_arch * n_arch,
        "pool_lines_min": lines_per_arch * n_arch,
        "s2_jobs": len(events) * n_arch,
        "blocklist_phrases": len(cfg["blocklist"]),
    }
