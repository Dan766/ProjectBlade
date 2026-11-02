class_name PartyMeshes
extends RefCounted
## Low-poly party models built in code (Phase G6), facing -z, ground at y = 0, about 0.55 tall:
##   lord     three soldiers under a big banner in the realm's colour
##   player   the same, a little larger (the flag shows the player's realm, or red when free)
##   bandit   ragged figures under a dark red rag on a crooked pole
##   caravan  a covered cart and a mule, with a small pennant in the realm's colour
## Parts coloured SettlementMeshes.TINT take the per-instance colour in settlement.gdshader.

const STEEL := Color("#6d7178")
const SKIN := Color("#d2b48c")
const CLOTH := Color("#5a4a3a")
const POLE := Color("#2a2420")
const RAG := Color("#6e1a1a")
const WOOD := Color("#7a5a3a")
const CANVAS := Color("#e6dcc0")
const MULE := Color("#7b6a58")


static func build(kind: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var b := SettlementMeshes.new()             # reuse its box/gable helpers
	b.st = st
	b.wall = WOOD
	match kind:
		"lord", "player":
			for p in [Vector3(-0.07, 0, 0.03), Vector3(0.07, 0, 0.03), Vector3(0, 0, -0.06)]:
				_soldier(st, p, STEEL)
			ScatterMeshes._prism(st, Vector3(0.0, 0, 0.0), 0.012, 0.01, 0.55, 4, POLE)
			b._box(Vector3(0.15, 0.33, 0), Vector3(0.3, 0.2, 0.012), 0.0, SettlementMeshes.TINT, 0.0)
			ScatterMeshes._blob(st, Vector3(0, 0.56, 0), Vector3(0.025, 0.025, 0.025), Color("#d8c27a"), 2)
		"bandit":
			for p in [Vector3(-0.08, 0, 0.02), Vector3(0.06, 0, 0.05), Vector3(0.01, 0, -0.07)]:
				_soldier(st, p, CLOTH)
			ScatterMeshes._prism_tilted(st, Vector3(0, 0, 0), Vector3(0.05, 0.4, 0.0), 0.01, POLE)
			b._box(Vector3(0.13, 0.27, 0), Vector3(0.16, 0.1, 0.012), 0.12, RAG, 0.0)
		"caravan":
			b._box(Vector3(0, 0.05, 0.04), Vector3(0.14, 0.07, 0.24), 0.0, WOOD, 0.0)
			b._gable(Vector3(0, 0.12, 0.04), 0.14, 0.22, 0.08, PI * 0.5, CANVAS)
			for w in [Vector3(-0.08, 0, -0.04), Vector3(0.08, 0, -0.04), Vector3(-0.08, 0, 0.12), Vector3(0.08, 0, 0.12)]:
				b._box(w, Vector3(0.015, 0.06, 0.06), 0.0, POLE, 0.0)
			b._box(Vector3(0, 0.06, -0.17), Vector3(0.06, 0.07, 0.14), 0.0, MULE, 0.0)
			b._box(Vector3(0, 0.1, -0.26), Vector3(0.04, 0.05, 0.06), 0.0, MULE.darkened(0.1), 0.0)
			for leg in [Vector3(-0.02, 0, -0.12), Vector3(0.02, 0, -0.12), Vector3(-0.02, 0, -0.22), Vector3(0.02, 0, -0.22)]:
				b._box(leg, Vector3(0.012, 0.06, 0.012), 0.0, MULE.darkened(0.2), 0.0)
			ScatterMeshes._prism(st, Vector3(0.06, 0.12, 0.14), 0.007, 0.006, 0.22, 4, POLE)
			b._box(Vector3(0.11, 0.27, 0.14), Vector3(0.1, 0.06, 0.01), 0.0, SettlementMeshes.TINT, 0.0)
		_:
			push_error("PartyMeshes: unknown kind " + kind)
	st.generate_normals()
	return st.commit()


static func _soldier(st: SurfaceTool, at: Vector3, body: Color) -> void:
	ScatterMeshes._cone(st, at, 0.045, 0.15, 5, body)
	ScatterMeshes._blob(st, at + Vector3(0, 0.16, 0), Vector3(0.03, 0.03, 0.03), SKIN, 1)
