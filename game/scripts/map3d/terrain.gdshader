// Campaign map terrain (Phase G2). Stylised: flat painted colours per terrain type, blended from
// the TerrainMesh splat weights with noisy edges, procedural detail per type, rock on slopes
// (triplanar noise), snow on peaks, sand on beaches, roads, and soft painted faction borders.
// Colours and tunables come from res://data/config/map3d.json via Map3DView.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 terrain_colors[8];        // linear; order ~ . f h m s d a (TerrainMesh.SPLAT_ORDER)
uniform vec3 faction_colors[8];        // linear; by region index, 0 = sea
uniform vec3 rock_color : source_color;
uniform vec3 snow_color : source_color;
uniform vec3 sand_color : source_color;
uniform vec3 road_color : source_color;
uniform vec3 pool_color : source_color;
uniform vec3 ember_color : source_color;
uniform sampler2D region_a : filter_linear, repeat_disable;   // MapTextures.region_masks: regions 1..4
uniform sampler2D region_b : filter_linear, repeat_disable;   // regions 5..8
uniform sampler2D road_tex : filter_linear, repeat_disable;
uniform vec2 map_size = vec2(240.0, 150.0);
uniform float blend_sharpness = 3.0;
uniform float slope_rock = 0.42;
uniform float snow_line = 6.5;
uniform float beach_height = 0.35;
uniform float border_width = 0.12;     // mask difference that still counts as on the line
uniform float border_soft = 0.7;       // cells: blur radius of the region masks (rounds the corners)
uniform float border_strength = 0.85;
uniform float border_glow = 0.35;      // tint toward the realm colour just inside each border
uniform float region_tint = 0.07;
uniform float ember_amount = 1.0;

varying vec4 w1;
varying vec3 world_pos;
varying vec3 world_normal;

// Hash without sin(): stays stable at large map coordinates (sin-based hashes went blocky).
float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), u.x),
		mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.0, 9.0);
		a *= 0.5;
	}
	return s / 0.9375;
}

// Region mask blurred over 5 taps, so the equal-membership line between realms is rounded.
vec4 soft_mask(sampler2D tex, vec2 cell_pos) {
	vec2 o = vec2(border_soft, -border_soft);
	return (texture(tex, cell_pos / map_size) * 2.0
		+ texture(tex, (cell_pos + o.xx) / map_size) + texture(tex, (cell_pos + o.yy) / map_size)
		+ texture(tex, (cell_pos + o.xy) / map_size) + texture(tex, (cell_pos + o.yx) / map_size)) / 6.0;
}

void vertex() {
	w1 = CUSTOM0;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 p = world_pos.xz;
	float n1 = fbm(p * 0.35);
	float n2 = vnoise(p * 3.1);

	// Splat blend with a noise factor per channel, so type edges are ragged painted patches.
	float w[8] = float[8](COLOR.r, COLOR.g, COLOR.b, COLOR.a, w1.r, w1.g, w1.b, w1.a);
	float total = 0.0;
	for (int i = 0; i < 8; i++) {
		w[i] = pow(w[i] * (0.5 + vnoise(p * 1.2 + float(i) * 17.3)), blend_sharpness);
		total += w[i];
	}
	vec3 col = vec3(0.0);
	for (int i = 0; i < 8; i++) {
		w[i] /= max(total, 1e-5);
		col += terrain_colors[i] * w[i];
	}
	float w_water = w[0], w_plains = w[1], w_forest = w[2], w_hills = w[3];
	float w_mount = w[4], w_marsh = w[5], w_desert = w[6], w_ash = w[7];

	col *= 0.9 + 0.2 * n1;
	col *= mix(1.0, 0.86 + 0.24 * fbm(p * 0.9) + 0.06 * vnoise(p * 9.0), w_plains);   // meadow patches
	col *= mix(1.0, 0.7 + 0.55 * vnoise(p * 5.5), w_forest);                       // dappled canopy
	col *= mix(1.0, 0.9 + 0.14 * sin(p.x * 2.2 + p.y * 0.9 + n1 * 7.0), w_desert); // dune ridges
	float pool = smoothstep(0.6, 0.66, vnoise(p * 1.7 + 40.0)) * w_marsh;           // marsh pools
	col = mix(col, pool_color, pool * 0.85);

	// Beaches just above the sea; the seabed under the water plane gets darker with depth.
	float beach = (1.0 - smoothstep(beach_height * 0.5, beach_height, world_pos.y + (n2 - 0.5) * 0.1))
		* (1.0 - w_marsh) * step(0.0, world_pos.y);
	col = mix(col, sand_color, beach * 0.8);
	col = mix(col, sand_color * 0.45, smoothstep(0.0, -3.0, world_pos.y));

	// Rock on steep slopes, textured with triplanar noise so cliffs don't stretch.
	vec3 bw = pow(abs(world_normal), vec3(4.0));
	bw /= bw.x + bw.y + bw.z;
	float tri = fbm(world_pos.zy * 1.3) * bw.x + fbm(world_pos.xz * 1.3) * bw.y + fbm(world_pos.xy * 1.3) * bw.z;
	float slope = 1.0 - world_normal.y;
	float rock = smoothstep(slope_rock, slope_rock + 0.18, slope + (n1 - 0.5) * 0.25) * step(0.0, world_pos.y);
	col = mix(col, rock_color * (0.75 + 0.5 * tri), rock);

	float snow = smoothstep(snow_line - 0.5, snow_line + 0.5, world_pos.y + (n1 - 0.5) * 2.5)
		* (1.0 - smoothstep(0.55, 0.8, slope));
	col = mix(col, snow_color * (0.92 + 0.08 * n2), snow);

	// Roads, with a little wobble so the 4-texels-per-cell lines read as hand drawn.
	vec2 wob = (vec2(vnoise(p * 0.9), vnoise(p * 0.9 + 31.0)) - 0.5) * 0.35;
	float road = smoothstep(0.3, 0.6, texture(road_tex, (p + wob * 0.4) / map_size).r);
	col = mix(col, road_color * (0.85 + 0.3 * n2), road * 0.85 * (1.0 - snow) * step(0.0, world_pos.y));

	// Faction borders: the strongest and second-strongest soft region masks at a noise-warped point;
	// where they are nearly equal we are on the line between two realms (not the coast: m2 > 0).
	vec2 q = p + (vec2(fbm(p * 0.5), fbm(p * 0.5 + 57.0)) - 0.5) * 0.9;
	vec4 ma = soft_mask(region_a, q);
	vec4 mb = soft_mask(region_b, q);
	float m[8] = float[8](0.0, ma.r, ma.g, ma.b, ma.a, mb.r, mb.g, mb.b);
	int i1 = 0;
	float m1 = 0.0;
	float m2 = 0.0;
	for (int i = 1; i < 8; i++) {
		if (m[i] > m1) {
			m2 = m1;
			m1 = m[i];
			i1 = i;
		} else if (m[i] > m2) {
			m2 = m[i];
		}
	}
	if (i1 > 0 && world_pos.y > 0.0) {
		vec3 fc = faction_colors[i1];
		float line = (1.0 - smoothstep(border_width * 0.5, border_width, m1 - m2)) * smoothstep(0.1, 0.25, m2);
		float glow = smoothstep(0.0, 0.45, m2) * border_glow;
		col = mix(col, fc, region_tint + glow);
		col = mix(col, mix(fc, vec3(0.02), 0.3), line * border_strength);
	}

	// Ember glints in the ash fields, in clusters.
	float ember = smoothstep(0.9, 0.96, vnoise(p * 4.5)) * smoothstep(0.45, 0.7, vnoise(p * 0.6 + 11.0))
		* w_ash * step(0.0, world_pos.y) * (0.55 + 0.45 * sin(TIME * 1.7 + n1 * 30.0));
	EMISSION = ember_color * ember * ember_amount * 2.5;
	col = mix(col, col * 0.6, w_ash * (1.0 - n2) * 0.4);

	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.35, pool);
	SPECULAR = mix(0.15, 0.5, pool);
}
