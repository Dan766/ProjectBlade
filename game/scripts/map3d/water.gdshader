// Campaign map sea (Phase G2): a plane at y = 0. Depth comes from the terrain heights texture,
// so shallows are light and see-through, deep water dark; foam and slow bands along the shore,
// gentle waves in the vertices and rippled normals.
shader_type spatial;
// shadows_disabled: the seabed sits just below the plane and its far-cascade shadow bled onto the
// water as a rectangle the size of the map.
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, shadows_disabled;

uniform vec3 shallow_color : source_color;
uniform vec3 deep_color : source_color;
uniform vec3 foam_color : source_color;
uniform sampler2D height_tex : filter_linear, repeat_disable;   // world y per cell (RF)
uniform vec2 map_size = vec2(240.0, 150.0);
uniform float wave_height = 0.05;
uniform float foam_width = 0.35;
uniform float deep_depth = 2.5;
uniform float ripple = 0.25;

varying vec3 wp;

float hash2(vec2 p) {                                // sin-free, stable at large coordinates
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

float waves(vec2 p, float t) {
	return vnoise(p * 0.7 + vec2(t * 0.15, t * 0.05)) * 0.6 + vnoise(p * 1.9 - vec2(t * 0.1, t * 0.22)) * 0.4;
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += (sin(wp.x * 0.8 + TIME * 0.9) + sin(wp.z * 1.1 - TIME * 0.7)) * 0.5 * wave_height;
}

void fragment() {
	vec2 uv = wp.xz / map_size;
	// Beyond the map the edge height carries on and deepens gradually (no hard step at the edge).
	vec2 outside = max(max(-wp.xz, wp.xz - map_size), vec2(0.0));
	float ground = texture(height_tex, clamp(uv, vec2(0.0), vec2(1.0))).r - length(outside) * 0.15;
	float depth = max(-ground, 0.0);

	float e = 0.12;
	float h0 = waves(wp.xz, TIME);
	float hx = waves(wp.xz + vec2(e, 0.0), TIME);
	float hz = waves(wp.xz + vec2(0.0, e), TIME);
	vec3 n = normalize(vec3(-(hx - h0) / e * ripple, 1.0, -(hz - h0) / e * ripple));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float edge = 1.0 - smoothstep(0.0, foam_width, depth);
	float foam = edge * smoothstep(0.25, 0.55, vnoise(wp.xz * 3.0 + TIME * 0.3));
	float bands = smoothstep(0.75, 1.0, sin(depth * 12.0 - TIME * 1.4))
		* (1.0 - smoothstep(0.0, foam_width * 3.0, depth));
	foam = clamp(max(foam, bands * 0.55) + edge * 0.25, 0.0, 1.0);

	vec3 col = mix(shallow_color, deep_color, smoothstep(0.0, deep_depth, depth));
	ALBEDO = mix(col, foam_color, foam);
	// Opaque once deep, so open sea past the map edge (no seabed behind it) looks the same as inside.
	ALPHA = clamp(mix(0.55, 1.0, smoothstep(0.0, deep_depth * 0.8, depth)) + foam, 0.0, 1.0);
	ROUGHNESS = mix(0.06, 0.7, foam);
	SPECULAR = 0.5;
}
