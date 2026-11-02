# Spec: Phase G - Graphics overhaul and 3D campaign map

Status: **in progress** (drafted 2026-11-01; G1 done 2026-11-01). Runs after Phase 6 (done), before Phase 7
(ship polish). Listed as "Phase G" in `docs/PLAN.md` and `docs/PROGRESS.md` (G1-G9 unchecked).

G1 constraints: `tools/gen_map.py` is seeded (SEED 1701) and `tools/tests/test_gen_map.py` checks
determinism and that settlement cells match the bundle; adding heights/roads must keep both passing.
Write patch scripts to files rather than shell heredocs (the shell has mangled backslash escapes).

## 1. Goal
Replace the placeholder visuals (one-colour pixel cells, code-drawn shapes, default UI theme) with a
**stylised low-poly 3D campaign map** and a matching medieval UI, at 60 fps with the full simulation
running. The simulation, battles, chat and politics do not change.

## 2. Why this is contained
`World`, `Party`, `Politics` etc. are pure data in 2D world pixels; only `scripts/map/*` draws them.
The 3D map is a new presentation layer:
- sim position `(x, y)` px → 3D `(x / cell_size, height(x, y), y / cell_size)` (1 cell = 1 world unit)
- clicks: raycast from the camera onto the terrain → hit point → cell → the same `player_meet`,
  `player_attack`, `set_destination` calls the 2D map makes today
- HUD, chat panel, battle screen, encounter and reputation dialogs stay CanvasLayer UI (restyled in G6)
- ~~the 2D map stays available behind a setting/flag~~ **removed after G6 (user decision 2026-11-01)**;
  low-end machines are served by G9's "Low" preset instead

## 3. Art direction (**approved by the user 2026-11-01: stylised low-poly, CC0 assets**)
- **Stylised low-poly**, painterly flat colours, soft directional light, light fog toward the horizon:
  readable from far zoom, cheap to render, and achievable with free CC0 assets.
- Each realm reads at a glance: banner colours (already in `world.toml`), plus a per-culture
  architecture tint/variant (canal-city stone and red roofs, reed-and-timber fen huts, black-stone
  ashland keeps, timber forest halls, white regency castles, sand-brick oasis towns).
- Terrain types keep their identity: lush plains, dense conifer/deciduous forest, rocky hills,
  snow-capped mountains, reedy marsh with pools, dunes, dark ash fields with ember glints.

### Asset policy
- **CC0 / permissive only** (e.g. Kenney, Quaternius, Poly Pizza CC0 sets) or assets made for this
  project. Nothing from existing commercial games. Every file listed in `game/assets/CREDITS.md`
  (source, author, licence).
- Downloading asset packs needs the user's go-ahead per pack (agent rule).
- Option: author missing pieces (unique castles, banners) procedurally in Godot or with a 3D tool;
  AI-generated images only for UI textures, with the licence recorded.
- Fonts: OFL fonts (e.g. a display serif for titles, a readable serif for body text), bundled with licence.

## 4. Data contract change
`tools/gen_map.py` already computes elevation internally; export it:
- `terrain.json` gains `"heights"`: rows of elevation 0..255 per cell (additive field, bump nothing else),
  plus `"sea_level"`. Mountains/hills get real height, coasts slope into the sea.
- Optional `"roads"`: polylines between bound villages and their forts, and between nearby towns
  (A* over the existing cost grid), so the 3D map can draw roads. Sim may later use them for speed.
- Update `tools/tests/test_gen_map.py`; regenerating must keep settlement cells identical (seeded).

**As built (G1, 2026-11-01):**
- `"sea_level": 64`; `"heights"`: one string per row, 2 hex digits per cell (Godot: `String.hex_decode()`).
  Land cells are always > `sea_level`, water cells < it. Marsh is flat, hills +14..24, mountains +40..130.
- `"roads"`: `[{"a": id, "b": id, "kind": "road"|"track", "path": [x0, y0, x1, y1, ...]}]` in cells,
  8-neighbour steps with the game's no-corner-cutting rule. Roads: each town to its 2 nearest towns
  (≤ 60 cells), each castle to its realm's nearest town; tracks: each village to its `bound_to`.
  Cells already on a road cost ×0.6, so later paths merge into a network.
- Godot: `TerrainMap.heights / sea_level / roads / height_at()`; `TerrainMesh.build(terrain, cfg)`
  (`scripts/map3d/terrain_mesh.gd`, tunables in `data/config/map3d.json`, also `GameState.map3d_config`)
  gives `mesh`, `height_at(Vector2 xz)` (exact on the triangles), `cell_height`, `cell_to_3d`,
  `vertex_heights` (481×301 grid, 0.5 apart; usable for a `HeightMapShape3D` in G3).
  Splat weights: `COLOR` = water, plains, forest, hills; `CUSTOM0` (RGBA8) = mountains, marsh, desert, ash.
- `tests/preview_terrain3d.gd` renders `Map3DView` from far/mid/near stand-in cameras to PNGs with FPS
  (see its header); reference shots in `docs/screenshots/g2/`.

**As built (G2, 2026-11-01, approved by the user):** `Map3DView.setup(terrain, faction_colors, cfg)` adds
Terrain, Sea, WorldEnvironment and Sun. Terrain shader: splat blend with per-channel noise (ragged
painted edges), per-type detail (meadow patches, dappled forest, dune ridges, marsh pools, clustered
ash embers), rock on slopes with triplanar noise, snow above `snow_line`, beaches, roads from
`MapTextures.road_image`, borders from `MapTextures.region_masks`. Water: depth from
`MapTextures.height_image`, shallow→deep colour, foam + shore bands, waves, rippled normals, no
received shadows. Sky: ProceduralSkyMaterial, exponential fog, ACES. All values in `map3d.json`.

**As built (G3, 2026-11-01):** the "shared controller" is `scripts/map/campaign_map.gd` itself; it
talks to the view (`MapView3D`; `MapView2D` existed until the 2D map was removed) through `pointer_world()` (sim px or null), `hover_radius()`,
`visible_types()`, `set_highlight()`, `party_near()`, `set_hovered_party()`, `focus()`,
`set_zoom_level()/zoom_level()` (zoom level 0.2 far .. 3.0 near), `set_edge_scroll()`, `mouse_override`.
`StrategyCamera` (`scripts/map3d/strategy_camera.gd`): pivot + yaw + zoom 0..1 (distance
6→190 exponential, pitch 34°→62°), eases toward its target, eye kept 1 unit above ground;
`screen_ray()` / `world_to_screen()`. Picking: `TerrainMesh.raycast()`. Config: "camera" in `map3d.json`.
Settlements show as owner-coloured pins until G5; the player's party is a flag with a route ribbon
drawn on top of the terrain until G6.

**As built (G4, 2026-11-01):** `Map3DView.setup(..., settlements)` adds a `Scatter` node when the
config has `"scatter"`. Models: `ScatterMeshes.build(kind)` (procedural, vertex-coloured, flat
shaded). Placement: `"scatter"."terrain"` lists `[kind, models per cell]` per terrain code, scaled by
FastNoiseLite (`noise_scale`, `noise_strength`); `keep_clear` radii per settlement type; road cells
skipped; trees skip slopes over `tree_max_slope`. Per kind: `range`, `shadow`, `scale`, `tints`,
`double_sided`, `align`. `Scatter.positions[kind]` keeps world positions (G5 can clear more space
around models if needed). G5 settlement models should follow the same approach (procedural per
culture) unless the user approves a CC0 pack.

**As built (G5, 2026-11-01):** `SettlementMeshes.build(kind, variant, palette, fields, dirt)`;
`Settlements3D.setup(ground, [{id, cell, type, culture}], faction_colors, cfg)` +
`refresh(owners, sieges)` (MapView3D calls it every `refresh_seconds` = 0.5 from `world.owner()` and
`state[id].siege.faction`); `info[id]` = {pos, type, top, radius} for labels, rings and later G6
placement. `LabelOverlay` (CanvasLayer 0, under the HUD) uses `SettlementLayer.SHOW_ICON_AT /
SHOW_LABEL_AT / ICON_PX / FONT_PX`; icons hide from zoom level `icon_hide_at` (1.2) inward, where models
are readable. Config: `"settlements"` in `map3d.json` (scale per type, variants, cultures, siege).

**As built (G6, 2026-11-01):** `Parties3D.setup(world, ground, cell_size, faction_colors, cfg)` +
`sync(scale, delta)` every frame from MapView3D; `shown` = [[Party, anchor]] for hover and names.
Instance data goes in as one `MultiMesh.buffer` per kind (16 floats: 3x4 row-major transform + custom
colour). `PartyMeshes.build(kind)`; tint parts use `settlement.gdshader`. Hover:
`MapView3D.party_near()` ignores the ground point and picks the projected banner within 16 px.
`LabelOverlay` redraws only on camera/hover change or every 0.25 s.

## 5. Milestones

| # | Milestone | Acceptance (evidence: test output + screenshots read back) |
|---|---|---|
| G1 | Heightmap + roads exported by gen_map; Godot `Terrain3D` builder: ArrayMesh from heights (1 cell = 1 unit, smoothed, ~2 verts/cell), per-vertex terrain weights | Mesh builds headless in < 2 s; height at every settlement cell is land; test compares mesh height to data |
| G2 | Terrain shader: splat-blend 8 terrain types (triplanar on slopes), faction borders as a soft painted line, water plane shader (shoreline foam, gentle waves), sky + fog + sun | Screenshot at far / mid / near zoom approved by user |
| G3 | Strategy camera: tilted perspective, zoom (height + pitch curve), pan WASD/edges/drag, rotate (Q/E or right-drag), clamp to map; raycast picking → cell | Click-to-travel works on 3D map; picking test (known screen ray → expected cell) |
| G4 | Scatter: forests, rocks, reeds, dunes, ash via MultiMesh, density by terrain + noise, culled by distance | 60 fps with all scatter at far zoom (`--shot --zoom` FPS line) |
| G5 | Settlements in 3D: town/castle/village models per culture, tinted by current owner, siege effect (camp tents + smoke) on besieged forts; labels as projected 2D overlay with existing LOD rules | All 164 placed on terrain; ownership change recolours within 1 s; screenshot |
| G6 | Parties in 3D: lord banners in faction colours (MultiMesh or pooled instances), bandit/caravan models, player party with route line on terrain; hover/selection rings | 300 parties at 60 fps at 4x speed; hover card works |
| G7 | UI overhaul: Godot Theme (fonts, parchment/wood panels, styled buttons, tabs, scrollbars), redesigned HUD, chat panel, settlement/party cards, encounter, reputation | All screens restyled; every existing automation screenshot re-taken and reviewed |
| G8 | Battle presentation: 3D diorama (two formations of soldier blocks on a terrain patch from the battle's terrain type) that advance/hold/flank/charge per round, casualties removed; existing numbers panel kept | Each command visibly animates; battle tests unchanged and passing |
| G9 | Settings + performance: quality presets (scatter density, shadows, MSAA), profiling pass (2D fallback dropped: map removed after G6) | 60 fps "High" on this machine; "Low" playable on integrated GPU estimate; frame-time report saved |

Order rationale: G1–G3 make the 3D map playable (the 2D map can retire after G6); G7 can run in
parallel with G4–G6 (separate files: theme/UI vs map); G8 last (largest, least blocking).

## 6. Architecture sketch
```
scenes/campaign_3d.tscn     -> scripts/map3d/campaign_map_3d.gd   (replaces campaign_map.gd as main scene)
scripts/map3d/terrain_mesh.gd      ArrayMesh from TerrainMap + heights
scripts/map3d/terrain.gdshader     splat + borders
scripts/map3d/water.gdshader
scripts/map3d/scatter.gd           MultiMeshInstance3D per scatter kind
scripts/map3d/settlements_3d.gd    model per settlement, owner tint, siege fx
scripts/map3d/parties_3d.gd        pooled party visuals synced from World each frame
scripts/map3d/strategy_camera.gd   Camera3D rig (pivot, zoom curve, rotate)
scripts/map3d/label_overlay.gd     2D labels via camera.unproject_position (LOD rules in LabelOverlay, zoom-level units)
ui/theme/marches.theme             Theme resource; fonts in ui/fonts/
assets/models/..., assets/textures/..., assets/CREDITS.md
```
Shared logic stays where it is: `TerrainMap` (costs, A*), `World`, `Party`, `Battle`, HUD logic.
The input handling in `campaign_map.gd` (click to meet/attack/travel, keys J/L/B/X/R/P) moves into a
shared controller used by both the 2D and 3D maps, so behaviour stays identical.

## 7. Risks
| Risk | Mitigation |
|---|---|
| Asset style mismatch across packs | Pick one primary CC0 pack family; recolour via shared palette material |
| Performance with 300 parties + thousands of trees | MultiMesh everywhere, distance culling, LOD meshes, profile per milestone |
| Labels unreadable in 3D | Screen-space overlay labels (crisp text), not Label3D; keep 2D LOD rules |
| Picking accuracy on slopes | Raycast against the terrain collision mesh, not a flat plane |
| Scope creep in the battle diorama | G8 is presentation only; resolver and numbers unchanged |
| Asset licences | CREDITS.md mandatory per file; CC0/OFL only unless the user approves otherwise |

**As built (G7, 2026-11-01):** `UiTheme.apply(cfg)` (called from `GameState._ready`, config
`data/config/ui.json`) merges the wood theme into `ThemeDB.get_default_theme()`; dialogs set
`panel.theme = UiTheme.parchment()`. Helpers: `UiTheme.label(text, variation)`, `UiTheme.color(name)`,
`UiTheme.font("body"|"bold"|"italic"|"display")`, `UiTheme.dim_rect(view)`. Fonts in `game/ui/fonts/`
with their OFL texts; credits in `game/assets/CREDITS.md`. Map labels: Cinzel for places, Garamond
bold for lords. Reference shots: `docs/screenshots/g7/`.
