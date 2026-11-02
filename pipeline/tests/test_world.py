import json
import string

import jsonschema
import pytest

from pipeline import config, fake_llm
from pipeline.jobs import Runner
from pipeline.stages import world

L = string.ascii_lowercase
SCHEMA = json.loads((config.SCHEMA_DIR / "world_faction.schema.json").read_text(encoding="utf-8"))


def name_for(f: int, i: int) -> str:
    """Distinct names whose pairwise edit distance is >= 2 (each digit appears twice)."""
    a, b = divmod(i, 26)
    return f"{L[f]}{L[a]}{L[b]}e{L[f]}{L[a]}{L[b]}".capitalize()


def faction_data(f: int) -> dict:
    counter = iter(range(1000))
    def places(n):
        return [{"name": name_for(f, next(counter)), "blurb": "Known for something memorable."} for _ in range(n)]
    return {
        "name": f"Realm {L[f].upper()}{L[f]}x", "adjective": "Realmish", "ruler_title": "Doge",
        "short_lore": "x" * 100,
        "troop_names": {k: ["Levy", "Guard", "Elite"] for k in ("infantry", "archers", "cavalry")},
        "towns": places(6), "castles": places(9), "villages": places(21),
    }


@pytest.fixture(scope="module")
def cfg():
    return config.load_all()


@pytest.fixture
def raw(tmp_path, cfg):
    data = {fid: faction_data(n) for n, fid in enumerate(sorted(cfg["world"]["factions"]))}
    data["continent"] = {"candidates": [{"name": f"Cand{c}", "feel": "Evokes something."} for c in "abcdef"]}

    def write():
        d = tmp_path / "raw" / "world"
        d.mkdir(parents=True, exist_ok=True)
        for jid, payload in data.items():
            (d / f"{jid}.json").write_text(json.dumps({"meta": {}, "data": payload}), encoding="utf-8")
        return tmp_path / "raw", tmp_path / "validated"
    return data, write


def test_crafted_names_are_valid_and_far_apart():
    jsonschema.validate(faction_data(0), SCHEMA)
    names = [world.normalize(name_for(f, i)) for f in range(6) for i in range(36)]
    assert len(set(names)) == len(names)
    assert world.levenshtein(names[0], names[1]) >= 2


def test_jobs_render_with_real_prompts(cfg, tmp_path):
    jobs = world.jobs(cfg)
    assert [j.job_id for j in jobs] == ["continent", *cfg["world"]["factions"]]
    runner = Runner(None, model="fake", raw_dir=tmp_path, log=lambda m: None)
    rendered = runner.render(jobs[1])
    assert "Venetian" in rendered.prompt and "exactly 21" in rendered.prompt
    assert "Venetian" not in rendered.prompt.split("other five factions")[1]


def test_fake_llm_satisfies_world_schemas():
    jsonschema.validate(fake_llm.generate(SCHEMA, "x"), SCHEMA)
    cont = json.loads((config.SCHEMA_DIR / "world_continent.schema.json").read_text(encoding="utf-8"))
    jsonschema.validate(fake_llm.generate(cont, "x"), cont)


def test_happy_path_writes_world_files(cfg, raw):
    _, write = raw
    raw_dir, out_dir = write()
    res = world.post(cfg, raw_dir, out_dir)
    assert res.errors == [] and res.warnings == []
    settlements = json.loads((out_dir / "world" / "settlements.json").read_text(encoding="utf-8"))
    factions = json.loads((out_dir / "world" / "factions.json").read_text(encoding="utf-8"))
    assert len(factions) == 6
    assert [sum(s["type"] == k for s in settlements) for k in ("town", "castle", "village")] == [24, 40, 100]
    assert settlements[0]["id"] == "town_01_01"
    assert len({s["id"] for s in settlements}) == 164
    assert (out_dir / "world" / "continent_candidates.json").exists()


def test_cross_faction_duplicate_uses_a_spare(cfg, raw):
    data, write = raw
    data["faction_02"]["towns"][0]["name"] = data["faction_01"]["towns"][0]["name"]
    res = world.post(cfg, *write())
    assert res.errors == []
    assert any("duplicate of" in w and "faction_02 town" in w for w in res.warnings)


def test_near_duplicate_and_blocklist_and_bad_chars_dropped(cfg, raw):
    data, write = raw
    first = data["faction_01"]["villages"][0]["name"]
    data["faction_03"]["villages"][0]["name"] = first[:-1] + ("z" if first[-1] != "z" else "y")
    data["faction_03"]["villages"][1]["name"] = "Discord Keep"
    data["faction_03"]["villages"][2]["name"] = "Fort 42"
    res = world.post(cfg, *write())
    assert res.errors == []
    joined = " ".join(res.warnings)
    assert "too similar" in joined and "blocklisted 'discord'" in joined and "unexpected characters" in joined


def test_running_out_of_names_is_an_error_naming_the_rerun(cfg, raw, tmp_path):
    data, write = raw
    for e in data["faction_04"]["castles"][:4]:   # 9 offered, 7 needed: 4 bad leaves 5
        e["name"] = data["faction_01"]["towns"][0]["name"]
    res = world.post(cfg, *write())
    assert any("faction_04: only 5/7 usable castles; rerun with --only faction_04 --force" in e for e in res.errors)
    assert not (tmp_path / "validated" / "world" / "factions.json").exists()


def test_missing_output_is_an_error(cfg, raw):
    _, write = raw
    raw_dir, out_dir = write()
    (raw_dir / "world" / "faction_05.json").unlink()
    res = world.post(cfg, raw_dir, out_dir)
    assert res.errors == ["missing output for faction_05; run `python -m pipeline run world`"]


def test_ids_are_positional_not_name_based(cfg, raw):
    data, write = raw
    raw_dir, out_dir = write()
    world.post(cfg, raw_dir, out_dir)
    before = [s["id"] for s in json.loads((out_dir / "world" / "settlements.json").read_text(encoding="utf-8"))]
    data["faction_01"]["towns"][0]["name"] = "Brandnewname"
    write()
    world.post(cfg, raw_dir, out_dir)
    after = json.loads((out_dir / "world" / "settlements.json").read_text(encoding="utf-8"))
    assert [s["id"] for s in after] == before and after[0]["name"] == "Brandnewname"


def test_colors_come_from_config(cfg, raw):
    _, write = raw
    raw_dir, out_dir = write()
    world.post(cfg, raw_dir, out_dir)
    factions = json.loads((out_dir / "world" / "factions.json").read_text(encoding="utf-8"))
    assert factions[0]["colors"] == cfg["world"]["factions"]["faction_01"]["colors"]


def test_lore_mentioned_spare_is_kept(cfg, raw):
    data, write = raw
    spare = data["faction_01"]["towns"][5]["name"]      # 6 offered, 4 needed: index 5 is a spare
    data["faction_01"]["short_lore"] = f"Old feuds in {spare} keep the council quarrelling. " + "x" * 60
    raw_dir, out_dir = write()
    res = world.post(cfg, raw_dir, out_dir)
    assert res.errors == [] and res.warnings == []
    towns = [s["name"] for s in json.loads((out_dir / "world" / "settlements.json").read_text(encoding="utf-8"))
             if s["faction"] == "faction_01" and s["type"] == "town"]
    assert spare in towns and len(towns) == 4


def test_lore_mention_of_dropped_name_warns(cfg, raw):
    data, write = raw
    dup = data["faction_01"]["towns"][0]["name"]
    data["faction_02"]["towns"][0]["name"] = dup                     # will be dropped as duplicate
    data["faction_02"]["short_lore"] = f"The clans covet {dup} above all else. " + "x" * 60
    res = world.post(cfg, *write())
    assert any("faction_02: lore mentions settlement(s) that were dropped" in w for w in res.warnings)
