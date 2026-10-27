shader_type spatial;
render_mode unshaded;

uniform sampler2D wood_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 wood_tint : source_color = vec4(1.0, 0.91, 0.76, 1.0);
varying float face_light;

void vertex() {
	vec3 world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	// Broad studio illumination: pale top, gently darker bevel and side.
	face_light = mix(0.70, 1.0, smoothstep(-0.15, 0.85, world_normal.y));
}

void fragment() {
	vec3 wood = texture(wood_texture, UV).rgb;
	vec3 pale_wood = mix(wood, wood_tint.rgb, 0.68);
	ALBEDO = pale_wood * face_light;
}
