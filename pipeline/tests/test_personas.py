import copy
import json
from collections import Counter

import jsonschema
import pytest

from pipeline import config, fake_llm
from pipeline.jobs import Runner
from pipeline.stages import personas as P

SCHEMA = json.loads((config.SCHEMA_DIR / "personas_batch.schema.json").read_text(encoding="utf-8"))
STYLE = {"case": "lower", "typos": "rare", "emoticons": "none", "punctuation": "minimal", "verbosity": "short"}


@pytest.fixture(scope="module")
def real_cfg():
    return config.load_all()


@pytest.fixture
def cfg(real_cfg):
    return copy.deepcopy(real_cfg)


@pytest.fixture
def world_dir(tmp_path, monkeypatch, real_cfg):
    d = tmp_path / "validated"
    (d / "world").mkdir(parents=True)
    factions = [{"id": fid, "name": f"Realm {fid}", "adjective": "Realmish", "lore": "Old feuds."}
                for fid in sorted(real_cfg["world"]["factions"])]
    (d / "world" / "factions.json").write_text(json.dumps(factions), encoding="utf-8")
    settlements = [{"id": "town_01_01", "faction": "faction_01", "type": "town", "name": "Calvenza", "blurb": "x"},
                   {"id": "town_02_01", "faction": "faction_02", "type": "town", "name": "Heeluma", "blurb": "x"}]
    (d / "world" / "settlements.json").write_text(json.dumps(settlements), encoding="utf-8")
    monkeypatch.setattr(P, "VALIDATED_DIR", d)
    return d


def raw_batches(cfg, tmp_path, edit=None):
    """Write a valid raw output for every batch; `edit(jid, personas)` may tamper first."""
    d = tmp_path / "raw" / "personas"
    d.mkdir(parents=True, exist_ok=True)
    for jid, batch in P.batches(cfg).items():
        people = [{"id": s.id, "username": f"user_{s.inspiration}", "chat_style": dict(STYLE),
                   "traits": ["sly", "loud"], "backstory": "Has played since the first war and never lets it go.",
                   "catchphrases": ["gg {player}", "again??"],
                   "ai_adjust": {k: 0.1 for k in cfg["archetypes"]["griefer"]["ai_weights"]}} for s in batch]
        if edit:
            edit(jid, people)
        (d / f"{jid}.json").write_text(json.dumps({"meta": {}, "data": {"personas": people}}), encoding="utf-8")
    return tmp_path / "raw", tmp_path / "validated"


# --- planning ------------------------------------------------------------------

def test_archetype_counts_sum_and_round():
    counts = P.archetype_counts({"a": 0.13, "b": 0.14, "c": 0.73}, 120)
    assert sum(counts.values()) == 120 and counts == {"a": 16, "b": 17, "c": 87}


def test_plan_matches_config_distribution(real_cfg):
    slots = P.plan_slots(real_cfg)
    assert len(slots) == 120 and len({s.id for s in slots}) == 120
    want = P.archetype_counts({a: v["share"] for a, v in real_cfg["archetypes"].items()}, 120)
    assert Counter(s.archetype for s in slots) == Counter(want)
    assert set(Counter(s.faction for s in slots).values()) == {20}
    for a in want:   # each archetype spread evenly: per-faction counts differ by at most 1
        per = Counter(s.faction for s in slots if s.archetype == a)
        assert max(per.values()) - min(per.get(f, 0) for f in real_cfg["world"]["factions"]) <= 1, a
    assert len({s.inspiration for s in slots}) == 120
    assert all(s.username_style in P.ROLEPLAY_STYLES for s in slots if s.archetype == "roleplayer")


def test_plan_is_deterministic_and_seeded(cfg):
    a = P.plan_slots(cfg)
    assert a == P.plan_slots(cfg)
    cfg["pipeline"]["personas"]["seed"] += 1
    assert [s.inspiration for s in a] != [s.inspiration for s in P.plan_slots(cfg)]


def test_inspiration_words_are_unique():
    assert len(P.INSPIRATION_WORDS) == len(set(P.INSPIRATION_WORDS)) >= 120


def test_batches(real_cfg):
    b = P.batches(real_cfg)
    assert len(b) == 12 and all(len(v) == 10 for v in b.values())
    assert all(len({s.faction for s in v}) == 1 for v in b.values())


def test_schema_matches_config(real_cfg):
    keys = set(next(iter(real_cfg["archetypes"].values()))["ai_weights"])
    assert set(SCHEMA["$defs"]["persona"]["properties"]["ai_adjust"]["properties"]) == keys
    assert SCHEMA["properties"]["personas"]["minItems"] == real_cfg["pipeline"]["personas"]["batch_size"]
    jsonschema.validate(fake_llm.generate(SCHEMA, "x"), SCHEMA)


# --- jobs ----------------------------------------------------------------------

def test_jobs_need_world(cfg, tmp_path, monkeypatch):
    monkeypatch.setattr(P, "VALIDATED_DIR", tmp_path / "nothing")
    with pytest.raises(ValueError, match="run world"):
        P.jobs(cfg)


def test_jobs_render(cfg, world_dir, tmp_path):
    jobs = P.jobs(cfg)
    assert len(jobs) == 12
    r = Runner(None, model="fake", raw_dir=tmp_path / "raw", log=lambda m: None).render(jobs[0])
    assert "Ormerath" in r.prompt and "Realm faction_01" in r.prompt
    assert "you may mention: Calvenza" in r.prompt and "Heeluma" not in r.prompt
    assert r.prompt.count("inspiration word:") == 10
    first = P.batches(cfg)["faction_01_b1"][0]
    assert f'id {first.id}: type' in r.prompt and f'"{first.inspiration}"' in r.prompt


# --- post ----------------------------------------------------------------------

def test_post_happy_path(cfg, tmp_path):
    res = P.post(cfg, *raw_batches(cfg, tmp_path))
    assert res.errors == []
    people = json.loads((tmp_path / "validated" / "personas" / "personas.json").read_text(encoding="utf-8"))
    assert len(people) == 120
    by_id = {p["id"]: p for p in people}
    g = next(p for p in people if p["archetype"] == "griefer")
    assert g["ai_weights"]["raid"] == 1.0                       # 0.9 + 0.1 = 1.0
    assert g["ai_weights"]["trade"] == pytest.approx(0.15)      # 0.05 + 0.1
    for p in people:
        assert 1 <= len(p["rivals"]) <= 3
        assert any(by_id[r]["faction"] != p["faction"] for r in p["rivals"])
        for r in p["rivals"]:
            assert p["id"] in by_id[r]["rivals"]
    assert sum(any(by_id[r]["faction"] == p["faction"] for r in p["rivals"]) for p in people) > 20


def test_weights_clamped(cfg, tmp_path):
    def edit(jid, people):
        for p in people:
            p["ai_adjust"]["raid"] = 0.2
    P.post(cfg, *raw_batches(cfg, tmp_path, edit))
    people = json.loads((tmp_path / "validated" / "personas" / "personas.json").read_text(encoding="utf-8"))
    assert max(p["ai_weights"]["raid"] for p in people) == 1.0


def test_username_collision_gets_a_digit(cfg, tmp_path):
    def edit(jid, people):
        if jid == "faction_02_b1":
            people[0]["username"] = "Same_Name"
        if jid == "faction_03_b1":
            people[0]["username"] = "same_name"
    res = P.post(cfg, *raw_batches(cfg, tmp_path, edit))
    assert res.errors == []
    assert any("renamed 'same_name2'" in w for w in res.warnings)


def test_wrong_id_missing_job_and_blocklist_are_errors(cfg, tmp_path):
    def edit(jid, people):
        if jid == "faction_01_b2":
            people[0]["id"] = "persona_999"
        if jid == "faction_04_b1":
            people[1]["catchphrases"][0] = "see u on discord"
    raw_dir, out_dir = raw_batches(cfg, tmp_path, edit)
    res = P.post(cfg, raw_dir, out_dir)
    assert any("faction_01_b2: returned id 'persona_999'" in e for e in res.errors)
    (raw_dir / "personas" / "faction_01_b2.json").unlink()
    raw_batches(cfg, tmp_path, lambda j, p: p[1]["catchphrases"].__setitem__(0, "see u on discord") if j == "faction_04_b1" else None)
    (raw_dir / "personas" / "faction_06_b2.json").unlink()
    res = P.post(cfg, raw_dir, out_dir)
    assert res.errors == ["missing output for faction_06_b2; run `python -m pipeline run personas`"]
    raw_batches(cfg, tmp_path, lambda j, p: p[1]["catchphrases"].__setitem__(0, "see u on discord") if j == "faction_04_b1" else None)
    res = P.post(cfg, raw_dir, out_dir)
    assert any("blocklisted 'discord'" in e and "--only faction_04_b1" in e for e in res.errors)
    assert not (out_dir / "personas" / "personas.json").exists()


def test_rivals_deterministic(cfg, tmp_path):
    raw_dir, out_dir = raw_batches(cfg, tmp_path)
    P.post(cfg, raw_dir, out_dir)
    first = (out_dir / "personas" / "personas.json").read_text(encoding="utf-8")
    P.post(cfg, raw_dir, out_dir)
    assert (out_dir / "personas" / "personas.json").read_text(encoding="utf-8") == first


def test_rival_placeholder_in_backstory_becomes_a_real_rival(cfg, tmp_path):
    def edit(jid, people):
        if jid == "faction_01_b1":
            people[0]["backstory"] = "Has never forgiven {rival} for the ambush at the old ford."
    raw_dir, out_dir = raw_batches(cfg, tmp_path, edit)
    assert P.post(cfg, raw_dir, out_dir).errors == []
    people = {p["id"]: p for p in json.loads((out_dir / "personas" / "personas.json").read_text(encoding="utf-8"))}
    first = people["persona_001"]
    assert first["backstory"] == f"Has never forgiven {people[first['rivals'][0]]['username']} for the ambush at the old ford."


def test_other_placeholders_are_errors(cfg, tmp_path):
    def edit(jid, people):
        if jid == "faction_02_b2":
            people[0]["backstory"] = "Once sold {player} a horse near {village}, still brags about it."
            people[1]["catchphrases"][0] = "see u at {fief}"
    res = P.post(cfg, *raw_batches(cfg, tmp_path, edit))
    assert any("backstory uses placeholder(s) ['player', 'village']" in e and "faction_02_b2" in e for e in res.errors)
    assert any("uses ['fief']" in e for e in res.errors)


def test_copied_example_warns_and_emoticons_are_not_capitals(cfg, tmp_path):
    slot = P.batches(cfg)["faction_01_b1"][0]
    copied = cfg["archetypes"][slot.archetype]["examples"]["global"][0].lower() + " xD"

    def edit(jid, people):
        if jid == "faction_01_b1":
            people[0]["catchphrases"] = [copied, "skill issue :P"]
    res = P.post(cfg, *raw_batches(cfg, tmp_path, edit))
    assert any(f"{slot.id}: catchphrase {copied!r} copies example" in w for w in res.warnings), res.warnings
    assert not any(f"{slot.id}: chat_style.case" in w for w in res.warnings)


def test_copies_example():
    assert P.copies_example("lol {player} ran from 12 looters xD", ["lol {player} ran from 12 looters"])
    assert not P.copies_example("gg ez, rematch at dawn", ["lol {player} ran from 12 looters"])
