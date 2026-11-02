"""S1 personas: the ~120 simulated players.

Planning is deterministic (pipeline.toml [personas] seed) and happens before any model call:
  - archetype counts come from archetypes.toml shares (largest-remainder rounding)
  - archetypes are dealt round-robin so every faction gets a similar mix
  - each slot gets a fixed id, a username style and a UNIQUE inspiration word; the word is what
    stops parallel jobs from converging on the same names (0.1 smoke: 4/4 usernames "Thornwick...")
The model fills in username, chat style, traits, backstory, catchphrases and small ai_adjust tweaks.

The post step checks every slot came back, fixes username collisions the way real servers do
(append a digit), computes final ai_weights (archetype default + adjust, clamped 0..1) and assigns
symmetric rivals deterministically.
"""
from __future__ import annotations

import json
import random
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from .. import config, textcheck
from ..textcheck import copies_example  # noqa: F401  (re-exported for tests)
from ..jobs import Job, _atomic_write
from . import PostResult
from .world import levenshtein

VALIDATED_DIR = config.OUT_DIR / "validated"

USERNAME_STYLES = {
    "tag_number": "a gamer tag: a word or two followed by a few digits",
    "xx_wrap": "wrapped gamer style with xX_ ... _Xx or similar decoration",
    "lower_compound": "two words run together, all lowercase",
    "camel": "two words in CamelCase",
    "underscored": "words joined with underscores",
    "short_word": "one short word, maybe deliberately misspelled",
    "pun": "a pun or joke name",
    "caps_tag": "a short ALL-CAPS tag, possibly with a digit",
    "titled": "a noble-sounding name with a title, written without spaces",
    "fantasy_name": "an invented fantasy personal name, maybe with an epithet",
}
ROLEPLAY_STYLES = ("titled", "fantasy_name", "camel")

INSPIRATION_WORDS = """
ash badger barley beacon bramble brine cinder clover cobble comet copper crow dagger dawn dusk ember
falcon fern flint frost gale glimmer goat gravel gull hammer harrow hawk hazel heron hollow honey hound
ivy jackal juniper kestrel kettle lantern lark lichen lynx mallet maple marrow mead mire moss moth mule
nettle oak onion otter owl pebble pike pine plum quill raven reed rook rust saffron sage salt sparrow
spindle stag stoat storm tallow thistle tide toad turnip vale vole walnut wasp weasel whisker willow wolf
wren yarrow anvil barrel biscuit boulder bucket candle cheese chisel cloak cork crumb drum fiddle goblet
helm hinge horn lute mitten nail pickle pot rope saddle sock spoon stool tankard thimble torch wagon
whistle bean beetle bog boar carp cricket duck eel ferret frog gnat hare hen lamb magpie mole newt
pigeon puffin ram slug snail squid swan trout acorn bell bracken button cabbage chalk dune fig glove
gourd grub hay ink jam kelp leek mint mud nut oat parsnip pumpkin radish rye scythe sledge soot sprout
""".split()


@dataclass(frozen=True)
class Slot:
    id: str
    faction: str
    archetype: str
    username_style: str
    inspiration: str


def archetype_counts(shares: dict[str, float], n: int) -> dict[str, int]:
    """Largest-remainder rounding so counts sum exactly to n (ties broken by name)."""
    raw = {a: s * n for a, s in shares.items()}
    counts = {a: int(v) for a, v in raw.items()}
    for a in sorted(raw, key=lambda a: (-(raw[a] - counts[a]), a))[: n - sum(counts.values())]:
        counts[a] += 1
    return counts


def plan_slots(cfg: dict) -> list[Slot]:
    n = cfg["pipeline"]["scale"]["personas"]
    rng = random.Random(cfg["pipeline"]["personas"]["seed"])
    factions = sorted(cfg["world"]["factions"])
    counts = archetype_counts({a: v["share"] for a, v in cfg["archetypes"].items()}, n)
    pool = [a for a in sorted(counts) for _ in range(counts[a])]
    per_faction: dict[str, list[str]] = {f: [] for f in factions}
    offset = 0
    for a in sorted(counts):          # deal each archetype round-robin, continuing where the last stopped
        for _ in range(counts[a]):
            per_faction[factions[offset % len(factions)]].append(a)
            offset += 1
    assert sum(len(v) for v in per_faction.values()) == len(pool)
    if len(INSPIRATION_WORDS) < n or len(set(INSPIRATION_WORDS)) != len(INSPIRATION_WORDS):
        raise ValueError("INSPIRATION_WORDS needs at least one unique word per persona")
    words = rng.sample(INSPIRATION_WORDS, n)
    slots, k = [], 0
    for f in factions:
        archs = per_faction[f]
        rng.shuffle(archs)
        for a in archs:
            styles = ROLEPLAY_STYLES if a == "roleplayer" else tuple(USERNAME_STYLES)
            slots.append(Slot(f"persona_{k + 1:03d}", f, a, rng.choice(styles), words[k]))
            k += 1
    return slots


def _archetype_guide(aid: str, a: dict) -> str:
    ex = a["examples"]
    return (f"- {a['label']} ({aid}): {' '.join(a['tone'].split())}\n"
            f"  Do: {'; '.join(a['do'])}. Don't: {'; '.join(a['dont'])}.\n"
            f"  Default chat_style: {json.dumps(a['chat_style'])}\n"
            f"  Sample lines: {' | '.join(ex['global'][:2] + ex['whisper'][:1])}")


def load_world(validated_dir: Path | None = None) -> tuple[dict[str, dict], list[dict]]:
    d = (validated_dir or VALIDATED_DIR) / "world"
    if not (d / "factions.json").exists() or not (d / "settlements.json").exists():
        raise ValueError("personas need the world stage first: run `python -m pipeline run world`")
    factions = {f["id"]: f for f in json.loads((d / "factions.json").read_text(encoding="utf-8"))}
    return factions, json.loads((d / "settlements.json").read_text(encoding="utf-8"))


_PLACEHOLDER = textcheck.PLACEHOLDER
_EMOTICON = textcheck.EMOTICON


def batches(cfg: dict) -> dict[str, list[Slot]]:
    """job_id -> its slots, e.g. 'faction_01_b1' -> 10 slots. Shared by jobs() and post()."""
    size = cfg["pipeline"]["personas"]["batch_size"]
    slots = plan_slots(cfg)
    out: dict[str, list[Slot]] = {}
    for fid in sorted(cfg["world"]["factions"]):
        mine = [s for s in slots if s.faction == fid]
        if len(mine) % size:
            raise ValueError(f"{fid} has {len(mine)} personas, not a multiple of batch_size {size}")
        for b in range(len(mine) // size):
            out[f"{fid}_b{b + 1}"] = mine[b * size:(b + 1) * size]
    return out


def jobs(cfg: dict) -> list[Job]:
    factions, settlements = load_world()
    out = []
    for jid, batch in batches(cfg).items():
        f = factions[batch[0].faction]
        archs = sorted({s.archetype for s in batch})
        places = ", ".join(s["name"] for s in settlements if s["faction"] == f["id"])
        out.append(Job("personas", jid, "personas.md", schema="personas_batch.schema.json", vars={
            "count": str(len(batch)), "continent": cfg["world"]["continent"]["name"] or "the continent",
            "faction_name": f["name"], "faction_adjective": f["adjective"], "faction_lore": f["lore"],
            "places": places,
            "archetype_guides": "\n".join(_archetype_guide(a, cfg["archetypes"][a]) for a in archs),
            "slots": "\n".join(
                f"{i}. id {s.id}: type {cfg['archetypes'][s.archetype]['label']}; "
                f"username style: {USERNAME_STYLES[s.username_style]}; inspiration word: \"{s.inspiration}\""
                for i, s in enumerate(batch, 1)),
        }))
    return out


def _unique_username(name: str, taken: set[str]) -> str:
    if name.casefold() not in taken:
        return name
    for n in range(2, 100):
        candidate = f"{name[:20 - len(str(n))]}{n}"
        if candidate.casefold() not in taken:
            return candidate
    raise ValueError(f"cannot make {name!r} unique")


def assign_rivals(personas: list[dict], seed: int) -> None:
    """Every persona gets 1 cross-faction rival, about half also get a same-faction rival.
    Symmetric (A rivals B => B rivals A), at most 3 each, deterministic for a seed."""
    rng = random.Random(seed * 7919 + 1)
    by_id = {p["id"]: p for p in personas}
    for p in personas:
        p["rivals"] = []

    def link(a: dict, b: dict) -> bool:
        if a is b or b["id"] in a["rivals"] or len(a["rivals"]) >= 3 or len(b["rivals"]) >= 3:
            return False
        a["rivals"].append(b["id"])
        b["rivals"].append(a["id"])
        return True

    order = sorted(by_id)
    rng.shuffle(order)
    for pid in order:
        p = by_id[pid]
        if not any(by_id[r]["faction"] != p["faction"] for r in p["rivals"]):
            others = [q for q in personas if q["faction"] != p["faction"] and len(q["rivals"]) < 3]
            rng.shuffle(others)
            next((q for q in others if link(p, q)), None)
        if rng.random() < 0.5 and not any(by_id[r]["faction"] == p["faction"] for r in p["rivals"]):
            same = [q for q in personas if q["faction"] == p["faction"] and q is not p and len(q["rivals"]) < 3]
            rng.shuffle(same)
            next((q for q in same if link(p, q)), None)
    for p in personas:
        p["rivals"].sort()


def post(cfg: dict, raw_dir: Path, out_dir: Path) -> PostResult:
    res = PostResult()
    plan = batches(cfg)
    slots = {s.id: s for batch in plan.values() for s in batch}
    got: dict[str, dict] = {}
    for jid in plan:
        path = raw_dir / "personas" / f"{jid}.json"
        if not path.exists():
            res.errors.append(f"missing output for {jid}; run `python -m pipeline run personas`")
            continue
        for p in json.loads(path.read_text(encoding="utf-8"))["data"]["personas"]:
            if p["id"] not in {s.id for s in plan[jid]}:
                res.errors.append(f"{jid}: returned id {p['id']!r} that isn't in its batch; rerun with --only {jid} --force")
            elif p["id"] in got:
                res.errors.append(f"{jid}: returned {p['id']} twice; rerun with --only {jid} --force")
            else:
                got[p["id"]] = {**p, "_job": jid}
    missing = sorted(set(slots) - set(got))
    if missing and not res.errors:
        res.errors.append(f"slots never returned: {', '.join(missing)}")
    if res.errors:
        return res

    blocklist = cfg["blocklist"]
    taken: set[str] = set()
    personas = []
    for pid in sorted(slots):
        s, p = slots[pid], got[pid]
        name = _unique_username(p["username"], taken)
        if name != p["username"]:
            res.warnings.append(f"{pid}: username {p['username']!r} taken, renamed {name!r}")
        taken.add(name.casefold())
        for text in [name, p["backstory"], *p["catchphrases"]]:
            hit = textcheck.blocklist_hit(text, blocklist)
            if hit:
                res.errors.append(f"{pid}: blocklisted {hit!r} in {text!r}; rerun with --only {p['_job']} --force")
        stray = sorted(set(_PLACEHOLDER.findall(p["backstory"])) - {"rival"})
        if stray:
            res.errors.append(f"{pid}: backstory uses placeholder(s) {stray}; rerun with --only {p['_job']} --force")
        for line in p["catchphrases"]:
            bad = sorted(set(_PLACEHOLDER.findall(line)) - {"player", "rival"})
            if bad:
                res.errors.append(f"{pid}: catchphrase {line!r} uses {bad}; rerun with --only {p['_job']} --force")
        arch = cfg["archetypes"][s.archetype]
        examples = [e for lines in arch["examples"].values() for e in lines]
        for line in p["catchphrases"]:
            ex = copies_example(line, examples)
            if ex:
                res.warnings.append(f"{pid}: catchphrase {line!r} copies example {ex!r}")
        defaults = arch["ai_weights"]
        weights = {k: round(min(1.0, max(0.0, v + p["ai_adjust"].get(k, 0.0))), 3) for k, v in defaults.items()}
        typed = _EMOTICON.sub("", _PLACEHOLDER.sub("", " ".join(p["catchphrases"])))
        if p["chat_style"]["case"] == "lower" and typed != typed.lower():
            res.warnings.append(f"{pid}: chat_style.case is lower but catchphrases use capitals")
        personas.append({
            "id": pid, "username": name, "archetype": s.archetype, "faction": s.faction,
            "chat_style": p["chat_style"], "traits": p["traits"], "backstory": p["backstory"],
            "catchphrases": p["catchphrases"], "ai_weights": weights,
        })

    names = sorted(p["username"].casefold() for p in personas)
    for a, b in zip(names, names[1:]):
        if len(a) >= 5 and levenshtein(a, b) <= 1:
            res.warnings.append(f"usernames {a!r} and {b!r} are nearly identical")
    crowded = [f"{k!r}x{v}" for k, v in Counter(n[:4] for n in names).items() if v > 3]
    if crowded:
        res.warnings.append(f"many usernames share a start: {', '.join(crowded)}")

    assign_rivals(personas, cfg["pipeline"]["personas"]["seed"])
    # {rival} in a backstory becomes the username of that persona's first assigned rival, so the
    # grudge it describes is with a real player on the server.
    by_id = {p["id"]: p for p in personas}
    for p in personas:
        p["backstory"] = p["backstory"].replace("{rival}", by_id[p["rivals"][0]]["username"])
    if res.errors:
        return res
    _atomic_write(out_dir / "personas" / "personas.json", json.dumps(personas, indent=2, ensure_ascii=False))
    by_arch = Counter(p["archetype"] for p in personas)
    by_fac = Counter(p["faction"] for p in personas)
    res.summary.append(f"personas: {len(personas)} -> {out_dir / 'personas'}")
    res.summary.append("  by archetype: " + ", ".join(f"{a} {by_arch[a]}" for a in sorted(by_arch)))
    res.summary.append("  by faction: " + ", ".join(f"{f} {by_fac[f]}" for f in sorted(by_fac)))
    return res
