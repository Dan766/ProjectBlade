import json
from collections import Counter
from pathlib import Path

import pytest

import tools.gen_map as G

FIDS = sorted(G.FACTION_SEEDS)


def fake_settlements():
    """Same quotas as world.toml: 4 towns, 6-7 castles, 16-17 villages per faction."""
    out = []
    for n, f in enumerate(FIDS, 1):
        castles, villages = (7, 17) if n <= 4 else (6, 16)
        for kind, count in (("town", 4), ("castle", castles), ("village", villages)):
            out += [{"id": f"{kind}_{n:02d}_{i:02d}", "faction": f, "type": kind} for i in range(1, count + 1)]
    return out


@pytest.fixture(scope="module")
def world():
    return G.generate(fake_settlements())


def test_shape_and_legend(world):
    terrain, _ = world
    assert len(terrain["rows"]) == G.H and all(len(r) == G.W for r in terrain["rows"])
    assert len(terrain["regions"]) == G.H and set("".join(terrain["regions"])) <= set("0123456")
    assert set("".join(terrain["rows"])) <= set(G.TERRAIN)
    land = sum(ch != "~" for row in terrain["rows"] for ch in row) / (G.W * G.H)
    assert 0.45 < land <= G.LAND_SHARE + 0.01
    for y, row in enumerate(terrain["rows"]):      # water <-> region 0, land <-> a faction
        for x, ch in enumerate(row):
            assert (ch == "~") == (terrain["regions"][y][x] == "0")


def test_every_faction_has_its_signature_terrain(world):
    terrain, _ = world
    share = {f: Counter() for f in FIDS}
    for y, row in enumerate(terrain["rows"]):
        for x, ch in enumerate(row):
            r = terrain["regions"][y][x]
            if r != "0":
                share[terrain["region_legend"][r]][ch] += 1
    top = {f: c.most_common(1)[0][0] for f, c in share.items()}
    assert top["faction_02"] == "s" and top["faction_04"] == "f" and top["faction_06"] == "d"
    assert share["faction_03"]["a"] + share["faction_03"]["h"] + share["faction_03"]["m"] > sum(share["faction_03"].values()) / 2


def test_settlements_placed_sensibly(world):
    terrain, layout = world
    s = layout["settlements"]
    assert len(s) == len(fake_settlements()) == 164 and len({x["id"] for x in s}) == 164
    fac = {x["id"]: x["faction"] for x in fake_settlements()}
    for p in s:
        cell = terrain["rows"][p["y"]][p["x"]]
        assert cell not in ("~", "m"), p
        assert terrain["region_legend"][terrain["regions"][p["y"]][p["x"]]] == fac[p["id"]], p
    towns = [p for p in s if p["id"].startswith("town")]
    for i, a in enumerate(towns):
        for b in towns[i + 1:]:
            assert (a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2 >= 8 ** 2
    for p in s:
        if p["id"].startswith("village"):
            lord = next(q for q in s if q["id"] == p["bound_to"])
            assert not lord["id"].startswith("village") and fac[lord["id"]] == fac[p["id"]]


def test_every_settlement_reachable_by_land(world):
    terrain, layout = world
    grid = [list(r) for r in terrain["rows"]]
    first = layout["settlements"][0]
    seen = G.reachable_from(grid, (first["x"], first["y"]))
    assert all((p["x"], p["y"]) in seen for p in layout["settlements"])


def test_deterministic(world):
    assert G.generate(fake_settlements()) == world


def _heights(terrain) -> list[bytes]:
    return [bytes.fromhex(row) for row in terrain["heights"]]


def test_heights_shape_and_sea_level(world):
    terrain, layout = world
    hs, sea = _heights(terrain), terrain["sea_level"]
    assert len(hs) == G.H and all(len(r) == G.W for r in hs)
    for y, row in enumerate(terrain["rows"]):
        for x, ch in enumerate(row):
            assert (hs[y][x] > sea) == (ch != "~"), (x, y, ch, hs[y][x])
    for p in layout["settlements"]:
        assert hs[p["y"]][p["x"]] > sea, p


def test_heights_follow_terrain(world):
    terrain, _ = world
    hs = _heights(terrain)
    by = {}
    for y, row in enumerate(terrain["rows"]):
        for x, ch in enumerate(row):
            by.setdefault(ch, []).append(hs[y][x])
    mean = {k: sum(v) / len(v) for k, v in by.items()}
    assert mean["m"] > mean["h"] > mean["."] > mean["s"] > mean["~"]
    assert max(by["s"]) - min(by["s"]) < 10            # marsh is flat


def test_roads_connect_settlements_over_land(world):
    terrain, layout = world
    rows = terrain["rows"]
    pos = {p["id"]: (p["x"], p["y"]) for p in layout["settlements"]}
    linked = set()
    for r in terrain["roads"]:
        cells = list(zip(r["path"][::2], r["path"][1::2]))
        assert cells[0] == pos[r["a"]] and cells[-1] == pos[r["b"]], r["a"]
        for (x0, y0), (x1, y1) in zip(cells, cells[1:]):
            assert max(abs(x1 - x0), abs(y1 - y0)) == 1
            if x0 != x1 and y0 != y1:                     # no corner cutting past water (game rule)
                assert rows[y0][x1] != "~" and rows[y1][x0] != "~"
        assert all(rows[y][x] != "~" for x, y in cells)
        linked.add((r["a"], r["b"]))
    for p in layout["settlements"]:
        if "bound_to" in p:
            assert (p["id"], p["bound_to"]) in linked, p["id"]
    castles = {p["id"] for p in layout["settlements"] if p["id"].startswith("castle")}
    assert castles <= {a for a, _ in linked}
    assert sum(r["kind"] == "road" and r["a"].startswith("town") for r in terrain["roads"]) >= 24


def test_compact_dump_round_trips(world):
    terrain, _ = world
    text = G.dump_terrain(terrain)
    assert json.loads(text) == terrain
    assert not any(line.strip().rstrip(",").isdigit() for line in text.splitlines())   # paths stay on one line


def test_committed_terrain_is_current():
    """Regenerating from the current bundle reproduces the checked-in terrain and layout."""
    root = Path(G.ROOT)
    bundle = root / "game" / "data" / "generated" / "world" / "settlements.json"
    world_dir = root / "game" / "data" / "world"
    if not (bundle.exists() and (world_dir / "terrain.json").exists()):
        pytest.skip("bundle or terrain not generated yet")
    terrain, layout = G.generate(json.loads(bundle.read_text(encoding="utf-8")))
    assert json.loads((world_dir / "terrain.json").read_text(encoding="utf-8")) == terrain
    assert json.loads((world_dir / "layout.json").read_text(encoding="utf-8")) == layout


def test_committed_files_match_bundle():
    """The checked-in layout covers exactly the settlements in the current pipeline bundle."""
    root = Path(G.ROOT)
    bundle = root / "game" / "data" / "generated" / "world" / "settlements.json"
    layout = root / "game" / "data" / "world" / "layout.json"
    if not (bundle.exists() and layout.exists()):
        pytest.skip("bundle or layout not generated yet")
    ids = {s["id"] for s in json.loads(bundle.read_text(encoding="utf-8"))}
    assert ids == {s["id"] for s in json.loads(layout.read_text(encoding="utf-8"))["settlements"]}
