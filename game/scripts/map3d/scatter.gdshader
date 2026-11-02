// Scatter models (Phase G4): vertex colour x per-instance tint, a gentle sway that grows with height.
// INSTANCE_CUSTOM = (tint r, g, b, sway phase 0..1), written by Scatter.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float sway = 0.035;

varying vec3 tint;

void vertex() {
	tint = INSTANCE_CUSTOM.rgb;
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float s = sin(TIME * 1.3 + wp.x * 0.7 + wp.z * 0.5 + INSTANCE_CUSTOM.a * 6.2832) * sway * max(VERTEX.y, 0.0);
	VERTEX.x += s;
	VERTEX.z += s * 0.6;
}

// Vertex colours and tints are sRGB (as authored); lighting needs linear.
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	ALBEDO = to_linear(COLOR.rgb * tint);
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
}
