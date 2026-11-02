"""S0 world: faction identity, troop names, settlement names; plus continent name candidates.

Jobs run in parallel, so factions can't see each other's names. Each job therefore asks for
spare settlement names (REQUEST) and the post step picks what each faction needs, dropping
names that duplicate, nearly duplicate or contain blocklisted phrases. If a faction runs out of
usable names, rerun just that faction: `run world --only faction_0N --force`.

Settlement ids are positional (town_03_02 = faction_03's 2nd town), not name slugs, so names
can be regenerated without breaking the Godot layout that references ids.
"""
from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

from ..jobs import Job, _atomic_write
from . import PostResult

REQUEST = {"towns": 6, "castles": 9, "villages": 21}   # keep in sync with world_faction.schema.json minItems
KINDS = (("towns", "town"), ("castles", "castle"), ("villages", "village"))
_NAME_OK = re.compile(r"^[^\W\d_]+(?:[ '\-][^\W\d_]+)*$")  # letters (accents ok), single spaces/'/-


def jobs(cfg: dict) -> list[Job]:
    factions = cfg["world"]["factions"]
    out = [Job("world", "continent", "world_continent.md", schema="world_continent.schema.json",
               vars={"concepts": "\n".join(f"- {f['concept']}" for f in factions.values())})]
    for fid, f in factions.items():
        others = "\n".join(f"- {o['concept']} Naming: {o['naming_hint']}" for oid, o in factions.items() if oid != fid)
        out.append(Job("world", fid, "world_faction.md", schema="world_faction.schema.json", vars={
            "concept": f["concept"], "naming_hint": f["naming_hint"], "strengths": f["strengths"],
            "other_factions": others,
            "n_towns": str(REQUEST["towns"]), "n_castles": str(REQUEST["castles"]), "n_villages": str(REQUEST["villages"]),
        }))
    return out


def normalize(name: str) -> str:
    return re.sub(r"[^\w]|_", "", name.casefold())


def levenshtein(a: str, b: str) -> int:
    if abs(len(a) - len(b)) > 1:
        return 2  # callers only care about <= 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


class NameRegistry:
    """Continent-wide name uniqueness, first come first served."""

    def __init__(self, blocklist: list[str]):
        self.blocklist = blocklist
        self.taken: dict[str, str] = {}   # normalized -> original

    def problem(self, name: str) -> str | None:
        if not _NAME_OK.match(name):
            return "unexpected characters"
        n = normalize(name)
        if n in self.taken:
            return f"duplicate of {self.taken[n]!r}"
        if len(n) >= 5:
            for t, orig in self.taken.items():
                if len(t) >= 5 and levenshtein(n, t) <= 1:
                    return f"too similar to {orig!r}"
        low = name.casefold()
        for phrase in self.blocklist:
            if re.search(rf"(?<!\w){re.escape(phrase)}(?!\w)", low):
                return f"blocklisted {phrase!r}"
        return None

    def claim(self, name: str) -> str | None:
        p = self.problem(name)
        if p is None:
            self.taken[normalize(name)] = name
        return p


def post(cfg: dict, raw_dir: Path, out_dir: Path) -> PostResult:
    res = PostResult()
    factions_cfg = cfg["world"]["factions"]
    raw: dict[str, dict] = {}
    for jid in ["continent", *sorted(factions_cfg)]:
        path = raw_dir / "world" / f"{jid}.json"
        if not path.exists():
            res.errors.append(f"missing output for {jid}; run `python -m pipeline run world`")
            continue
        raw[jid] = json.loads(path.read_text(encoding="utf-8"))["data"]
    if res.errors:
        return res

    names = NameRegistry(cfg["blocklist"])
    factions_out, settlements_out = [], []

    for fid in sorted(factions_cfg):
        d = raw[fid]
        p = names.claim(d["name"])
        if p:
            res.errors.append(f"{fid}: faction name {d['name']!r} {p}; rerun with --only {fid} --force")
        factions_out.append({
            "id": fid, "name": d["name"], "adjective": d["adjective"], "ruler_title": d["ruler_title"],
            "lore": d["short_lore"], "colors": factions_cfg[fid]["colors"], "troop_names": d["troop_names"],
        })

    for fid in sorted(factions_cfg):
        d, num = raw[fid], fid.rsplit("_", 1)[-1]
        lore = d["short_lore"].casefold()
        for plural, kind in KINDS:
            need = factions_cfg[fid][plural]
            picked = []
            # Places the lore mentions go first, so the lore never names a settlement that got cut.
            for entry in sorted(d[plural], key=lambda e: e["name"].casefold() not in lore):
                if len(picked) == need:
                    break
                p = names.claim(entry["name"])
                if p:
                    res.warnings.append(f"{fid} {kind}: dropped {entry['name']!r} ({p})")
                else:
                    picked.append(entry)
            if len(picked) < need:
                res.errors.append(f"{fid}: only {len(picked)}/{need} usable {plural}; rerun with --only {fid} --force")
            for i, e in enumerate(picked, 1):
                settlements_out.append({"id": f"{kind}_{num}_{i:02d}", "faction": fid, "type": kind,
                                        "name": e["name"], "blurb": e["blurb"]})
        kept = {s["name"].casefold() for s in settlements_out if s["faction"] == fid}
        cut = [e["name"] for plural, _ in KINDS for e in d[plural]
               if e["name"].casefold() in lore and e["name"].casefold() not in kept]
        if cut:
            res.warnings.append(f"{fid}: lore mentions settlement(s) that were dropped: {', '.join(cut)}")
        prefixes = Counter(normalize(s["name"])[:3] for s in settlements_out if s["faction"] == fid)
        crowded = [f"{p!r}x{n}" for p, n in prefixes.items() if n > 3]
        if crowded:
            res.warnings.append(f"{fid}: many names share a start: {', '.join(crowded)}")

    world_dir = out_dir / "world"
    _atomic_write(world_dir / "continent_candidates.json", json.dumps(raw["continent"]["candidates"], indent=2, ensure_ascii=False))
    if res.errors:
        return res
    _atomic_write(world_dir / "factions.json", json.dumps(factions_out, indent=2, ensure_ascii=False))
    _atomic_write(world_dir / "settlements.json", json.dumps(settlements_out, indent=2, ensure_ascii=False))
    counts = Counter(s["type"] for s in settlements_out)
    res.summary.append(f"world: {len(factions_out)} factions, {counts['town']} towns, {counts['castle']} castles, "
                       f"{counts['village']} villages -> {world_dir}")
    return res
