// Settlement models and siege tents (Phase G5). Vertex colour alpha 0 marks owner-coloured parts
// (flags, keep roofs, tents): their rgb is a shade that multiplies INSTANCE_CUSTOM.rgb, the current
// owner's banner colour (sRGB). Everything else keeps its own vertex colour.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

varying vec3 owner;

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	owner = INSTANCE_CUSTOM.rgb;
}

void fragment() {
	vec3 c = COLOR.a < 0.5 ? owner * COLOR.rgb : COLOR.rgb;
	ALBEDO = to_linear(c);
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
}
