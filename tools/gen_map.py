"""Generate the Ormerath continent: terrain grid, faction regions and settlement layout.

    .venv/Scripts/python tools/gen_map.py            # writes game/data/world/{terrain,layout}.json

Deterministic for a given SEED. Reads settlement ids and factions from the pipeline bundle
(game/data/generated/world/settlements.json) and only decides WHERE things are; names and lore stay
in the bundle. The output is hand-editable game data (it lives outside game/data/generated/).

Shape of the world, following each faction's concept (pipeline/config/world.toml):
  faction_01 Orlagua (canal republic)   east coast, plains with coastal marsh
  faction_02 Saaravenn (fen clans)      west lowlands, mostly marsh
  faction_03 Tsevaret (ashlands)        north-east highlands, ash, hills and mountains
  faction_04 Tesnovar (forest compact)  north-west, mostly forest
  faction_05 Lauresse (regency)         the central plains
  faction_06 Ighrast (salt league)      the southern desert

For the 3D map (Phase G) terrain.json also carries "heights" (one hex-encoded byte 0..255 per cell,
rows like "rows"), "sea_level" (land cells are above it, water below) and "roads" (cell paths
between settlements, A* over the movement costs). These are additive: the terrain rows, regions and
settlement cells do not depend on them.
"""
from __future__ import annotations

import heapq
import json
import math
import random
import re
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_SETTLEMENTS = ROOT / "game" / "data" / "generated" / "world" / "settlements.json"
OUT_DIR = ROOT / "game" / "data" / "world"

SEED = 1701
W, H = 240, 150
CELL_SIZE = 16          # pixels per cell in the game
LAND_SHARE = 0.60

# code -> (name, movement cost; 0 = impassable)
TERRAIN = {
    "~": ("water", 0.0), ".": ("plains", 1.0), "f": ("forest", 1.6), "h": ("hills", 1.8),
    "m": ("mountains", 4.0), "s": ("marsh", 2.0), "d": ("desert", 1.4), "a": ("ash", 1.5),
}
FACTION_SEEDS = {
    "faction_01": (0.80, 0.50), "faction_02": (0.17, 0.52), "faction_03": (0.68, 0.17),
    "faction_04": (0.33, 0.18), "faction_05": (0.47, 0.50), "faction_06": (0.52, 0.84),
}
MIN_DIST = {"town": 16, "castle": 9, "village": 5}     # cells, relaxed step by step if a quota can't fit

SEA_LEVEL = 64          # height units (0..255); land cells sit above it, water below
TOWN_LINKS = 2          # each town gets a road to its nearest N towns
TOWN_LINK_MAX = 60      # ... if they are at most this many cells apart
ROAD_REUSE = 0.6        # cost factor on cells that already carry a road, so roads merge into a network


# --- noise ----------------------------------------------------------------------

def _hash(ix: int, iy: int, seed: int) -> float:
    n = (ix * 374761393 + iy * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFFFF) / 0xFFFFFFFF


def _value_noise(x: float, y: float, seed: int) -> float:
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    sx, sy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = _hash(ix, iy, seed), _hash(ix + 1, iy, seed)
    c, d = _hash(ix, iy + 1, seed), _hash(ix + 1, iy + 1, seed)
    return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy


def fbm(x: float, y: float, seed: int, octaves: int = 4) -> float:
    total, amp, freq, norm = 0.0, 1.0, 1.0, 0.0
    for o in range(octaves):
        total += amp * _value_noise(x * freq, y * freq, seed + o * 101)
        norm += amp
        amp *= 0.5
        freq *= 2.0
    return total / norm


def _quantile(values: list[float], q: float) -> float:
    s = sorted(values)
    return s[min(len(s) - 1, int(q * len(s)))]


# --- terrain -----------------------------------------------------------------------

def make_land() -> list[list[bool]]:
    score = [[0.0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            d = ((x / W - 0.5) / 0.48) ** 2 + ((y / H - 0.5) / 0.46) ** 2
            score[y][x] = fbm(x / 28, y / 28, SEED) * 0.9 + (1 - min(d, 1.5)) * 1.0
    cut = _quantile([v for row in score for v in row], 1 - LAND_SHARE)
    land = [[score[y][x] > cut for x in range(W)] for y in range(H)]
    for x in range(W):                       # the map edge is always sea
        land[0][x] = land[H - 1][x] = False
    for y in range(H):
        land[y][0] = land[y][W - 1] = False
    return keep_largest_island(land)


def keep_largest_island(land: list[list[bool]]) -> list[list[bool]]:
    seen = [[False] * W for _ in range(H)]
    best: list[tuple[int, int]] = []
    for sy in range(H):
        for sx in range(W):
            if land[sy][sx] and not seen[sy][sx]:
                comp, q = [], deque([(sx, sy)])
                seen[sy][sx] = True
                while q:
                    x, y = q.popleft()
                    comp.append((x, y))
                    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                        if 0 <= nx < W and 0 <= ny < H and land[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True
                            q.append((nx, ny))
                if len(comp) > len(best):
                    best = comp
    out = [[False] * W for _ in range(H)]
    for x, y in best:
        out[y][x] = True
    return out


def make_regions(land: list[list[bool]]) -> list[list[str | None]]:
    fids = sorted(FACTION_SEEDS)
    regions: list[list[str | None]] = [[None] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if not land[y][x]:
                continue
            # warp the lookup point with noise so borders wiggle instead of being straight Voronoi lines
            wx = x / W + (fbm(x / 22, y / 22, SEED + 7) - 0.5) * 0.16
            wy = y / H + (fbm(x / 22, y / 22, SEED + 13) - 0.5) * 0.16
            regions[y][x] = min(fids, key=lambda f: (wx - FACTION_SEEDS[f][0]) ** 2 * 1.4 + (wy - FACTION_SEEDS[f][1]) ** 2)
    return regions


def near_water(land, x, y, r=2) -> bool:
    return any(not land[ny][nx] for ny in range(max(0, y - r), min(H, y + r + 1))
               for nx in range(max(0, x - r), min(W, x + r + 1)))


def make_elevation() -> list[list[float]]:
    return [[fbm(x / 18, y / 18, SEED + 31) for x in range(W)] for y in range(H)]


def make_terrain(land, regions, elev=None) -> list[list[str]]:
    elev = elev or make_elevation()
    land_elev = [elev[y][x] for y in range(H) for x in range(W) if land[y][x]]
    hill_cut, mount_cut = _quantile(land_elev, 0.80), _quantile(land_elev, 0.93)
    grid = [["~"] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if not land[y][x]:
                continue
            f = regions[y][x]
            e = elev[y][x] + (0.08 if f == "faction_03" else 0.0)
            v = fbm(x / 9, y / 9, SEED + 57)                # patchiness of the secondary terrain
            if e > mount_cut:
                t = "m"
            elif e > hill_cut:
                t = "h"
            elif f == "faction_01":
                t = "s" if near_water(land, x, y) and v > 0.45 else ("f" if v > 0.68 else ".")
            elif f == "faction_02":
                t = "s" if v > 0.32 else ("f" if v < 0.2 else ".")
            elif f == "faction_03":
                t = "a" if v > 0.42 else ("h" if v > 0.3 else ".")
            elif f == "faction_04":
                t = "f" if v > 0.3 else "."
            elif f == "faction_05":
                t = "f" if v > 0.66 else ("h" if v < 0.22 else ".")
            else:
                t = "d" if v > 0.25 else "."               # oases and scrub among the dunes
            grid[y][x] = t
    return grid


# --- settlements --------------------------------------------------------------------

def place_settlements(grid, regions, settlements: list[dict]) -> list[dict]:
    rng = random.Random(SEED)
    placed: list[dict] = []
    by_faction: dict[str, list[tuple[int, int]]] = {}
    for y in range(H):
        for x in range(W):
            f = regions[y][x]
            if f and grid[y][x] not in ("~", "m"):
                by_faction.setdefault(f, []).append((x, y))

    def border_margin(x, y, f) -> int:
        for r in range(1, 6):
            for ny in range(max(0, y - r), min(H, y + r + 1)):
                for nx in range(max(0, x - r), min(W, x + r + 1)):
                    if regions[ny][nx] not in (f, None):
                        return r
        return 6

    for kind in ("town", "castle", "village"):
        for s in (s for s in settlements if s["type"] == kind):
            cands = by_faction[s["faction"]][:]
            rng.shuffle(cands)
            need = MIN_DIST[kind]
            spot = None
            while spot is None:
                for x, y in cands:
                    if kind == "town" and border_margin(x, y, s["faction"]) < 4 and need > 8:
                        continue                    # towns sit inside their realm, not on the border
                    if all((x - p["x"]) ** 2 + (y - p["y"]) ** 2 >= max(need, MIN_DIST[p["type"]] // 2) ** 2 for p in placed):
                        spot = (x, y)
                        break
                if spot is None:
                    need -= 1
                    if need < 2:
                        raise RuntimeError(f"no room for {s['id']}")
            placed.append({"id": s["id"], "type": kind, "faction": s["faction"], "x": spot[0], "y": spot[1]})

    for p in placed:                                  # villages feed the nearest town/castle of their realm
        if p["type"] == "village":
            lords = [q for q in placed if q["faction"] == p["faction"] and q["type"] != "village"]
            p["bound_to"] = min(lords, key=lambda q: (q["x"] - p["x"]) ** 2 + (q["y"] - p["y"]) ** 2)["id"]
    return placed


def reachable_from(grid, start: tuple[int, int]) -> set[tuple[int, int]]:
    seen, q = {start}, deque([start])
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < W and 0 <= ny < H and grid[ny][nx] != "~" and (nx, ny) not in seen:
                seen.add((nx, ny))
                q.append((nx, ny))
    return seen


# --- 3D map data: heights and roads --------------------------------------------------

def distance_to(mask: list[list[bool]]) -> list[list[int]]:
    """Steps (8-neighbour) from each cell to the nearest cell where mask is True."""
    dist = [[-1] * W for _ in range(H)]
    q = deque()
    for y in range(H):
        for x in range(W):
            if mask[y][x]:
                dist[y][x] = 0
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < W and 0 <= ny < H and dist[ny][nx] < 0:
                    dist[ny][nx] = dist[y][x] + 1
                    q.append((nx, ny))
    return dist


def make_heights(land, grid, elev) -> list[list[int]]:
    """Elevation 0..255 per cell. Coasts slope into the sea, marsh stays flat, hills and mountains rise."""
    to_water = distance_to([[not v for v in row] for row in land])
    to_land = distance_to(land)
    land_elev = [elev[y][x] for y in range(H) for x in range(W) if land[y][x]]
    lo, hi = min(land_elev), max(land_elev)
    mount_cut = _quantile(land_elev, 0.93)
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            t = grid[y][x]
            if t == "~":
                h = SEA_LEVEL - 6 - min(to_land[y][x] - 1, 8) * 5
            else:
                coast = min(to_water[y][x], 8) / 8
                e = (elev[y][x] - lo) / (hi - lo)
                ridge = fbm(x / 5, y / 5, SEED + 77)
                h = SEA_LEVEL + 2 + coast * 10 + e * 18
                if t == "s":
                    h = SEA_LEVEL + 2 + coast * 3                       # wetlands lie flat
                elif t == "h":
                    h += 14 + ridge * 10
                elif t == "m":
                    h += 40 + ridge * 50 + max(0.0, elev[y][x] - mount_cut) / (hi - mount_cut) * 40
                elif t == "d":
                    h += fbm(x / 3, y / 3, SEED + 91) * 5                # dunes
                elif t in ("a", "f"):
                    h += 3
                h = max(h, SEA_LEVEL + 2)
            out[y][x] = max(0, min(255, round(h)))
    return out


def find_road(grid, start, goal, on_road: set) -> list[tuple[int, int]]:
    """Cheapest cell path by movement cost, with the same diagonal rule as the game's AStarGrid2D
    (no corner cutting past water). Cells already on a road cost less, so roads share stretches."""
    def cost(x, y) -> float:
        c = TERRAIN[grid[y][x]][1]
        return c * ROAD_REUSE if (x, y) in on_road else c

    def h(x, y) -> float:
        dx, dy = abs(x - goal[0]), abs(y - goal[1])
        return (max(dx, dy) + (math.sqrt(2) - 1) * min(dx, dy)) * TERRAIN["."][1] * ROAD_REUSE

    best = {start: 0.0}
    came: dict = {}
    frontier = [(h(*start), 0.0, start)]
    while frontier:
        _, g, cur = heapq.heappop(frontier)
        if cur == goal:
            path = [cur]
            while cur in came:
                cur = came[cur]
                path.append(cur)
            return path[::-1]
        if g > best[cur]:
            continue
        x, y = cur
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if (dx == dy == 0) or not (0 <= nx < W and 0 <= ny < H) or grid[ny][nx] == "~":
                    continue
                if dx and dy and (grid[y][nx] == "~" or grid[ny][x] == "~"):
                    continue
                ng = g + cost(nx, ny) * (math.sqrt(2) if dx and dy else 1.0)
                if ng < best.get((nx, ny), math.inf):
                    best[(nx, ny)] = ng
                    came[(nx, ny)] = cur
                    heapq.heappush(frontier, (ng + h(nx, ny), ng, (nx, ny)))
    return []


def make_roads(grid, placed: list[dict]) -> list[dict]:
    """Main roads between nearby towns and from each castle to its realm's nearest town, then tracks
    from every village to the fort it is bound to. Built in that order so tracks join the roads."""
    by_id = {p["id"]: p for p in placed}

    def d2(a, b) -> int:
        return (a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2

    pairs: list[tuple[str, str, str]] = []
    towns = [p for p in placed if p["type"] == "town"]
    seen = set()
    for a in towns:
        for b in sorted((t for t in towns if t is not a), key=lambda t: (d2(a, t), t["id"]))[:TOWN_LINKS]:
            key = tuple(sorted((a["id"], b["id"])))
            if key not in seen and d2(a, b) <= TOWN_LINK_MAX ** 2:
                seen.add(key)
                pairs.append((key[0], key[1], "road"))
    for c in (p for p in placed if p["type"] == "castle"):
        own = [t for t in towns if t["faction"] == c["faction"]]
        pairs.append((c["id"], min(own, key=lambda t: (d2(c, t), t["id"]))["id"], "road"))
    for v in (p for p in placed if p["type"] == "village"):
        pairs.append((v["id"], v["bound_to"], "track"))

    on_road: set = set()
    roads = []
    for a, b, kind in pairs:
        pa, pb = by_id[a], by_id[b]
        path = find_road(grid, (pa["x"], pa["y"]), (pb["x"], pb["y"]), on_road)
        if not path:
            continue                                # different landmass; every settlement is on one, so rare
        on_road.update(path)
        roads.append({"a": a, "b": b, "kind": kind, "path": [v for cell in path for v in cell]})
    return roads


def dump_terrain(terrain: dict) -> str:
    """indent=1 like before, but each list of numbers (a road path) stays on one line."""
    text = json.dumps(terrain, indent=1)
    return re.sub(r"\[\s*(-?\d+(?:,\s*-?\d+)*)\s*\]", lambda m: "[" + re.sub(r"\s+", "", m.group(1)) + "]", text)


def generate(settlements: list[dict]) -> tuple[dict, dict]:
    land = make_land()
    regions = make_regions(land)
    elev = make_elevation()
    grid = make_terrain(land, regions, elev)
    placed = place_settlements(grid, regions, settlements)
    heights = make_heights(land, grid, elev)
    fids = sorted(FACTION_SEEDS)
    terrain = {
        "seed": SEED, "width": W, "height": H, "cell_size": CELL_SIZE,
        "legend": {code: {"name": n, "cost": c} for code, (n, c) in TERRAIN.items()},
        "rows": ["".join(row) for row in grid],
        "region_legend": {str(i + 1): f for i, f in enumerate(fids)},
        "regions": ["".join("0" if r is None else str(fids.index(r) + 1) for r in row) for row in regions],
        "sea_level": SEA_LEVEL,
        "heights": ["".join(f"{h:02x}" for h in row) for row in heights],
        "roads": make_roads(grid, placed),
    }
    layout = {"seed": SEED, "settlements": [
        {k: p[k] for k in ("id", "x", "y")} | ({"bound_to": p["bound_to"]} if "bound_to" in p else {}) for p in placed]}
    return terrain, layout


def main() -> None:
    settlements = json.loads(BUNDLE_SETTLEMENTS.read_text(encoding="utf-8"))
    terrain, layout = generate(settlements)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "terrain.json").write_text(dump_terrain(terrain), encoding="utf-8")
    (OUT_DIR / "layout.json").write_text(json.dumps(layout, indent=1), encoding="utf-8")
    counts = {}
    for row in terrain["rows"]:
        for ch in row:
            counts[ch] = counts.get(ch, 0) + 1
    total = W * H
    print("terrain share:", ", ".join(f"{TERRAIN[c][0]} {n / total:.0%}" for c, n in sorted(counts.items(), key=lambda kv: -kv[1])))
    print(f"settlements placed: {len(layout['settlements'])} -> {OUT_DIR}")
    kinds = [r["kind"] for r in terrain["roads"]]
    print(f"roads: {kinds.count('road')} roads, {kinds.count('track')} tracks, "
          f"{len({(r['path'][i], r['path'][i + 1]) for r in terrain['roads'] for i in range(0, len(r['path']), 2)})} road cells")


if __name__ == "__main__":
    main()
