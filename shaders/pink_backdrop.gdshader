shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 pink_color : source_color = vec4(0.973, 0.773, 0.800, 1.0);
uniform vec4 cream_color : source_color = vec4(1.0, 0.941, 0.906, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.55, 0.29, 0.32, 1.0);
uniform float board_radius = 1.5;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Screen-space softboxes stay broad and stable as the camera retracts.
	vec2 uv = SCREEN_UV;
	vec2 softbox = (uv - vec2(0.46, 0.23)) / vec2(0.56, 0.55);
	float glow = exp(-dot(softbox, softbox) * 1.6);
	vec2 lower_light = (uv - vec2(0.22, 0.88)) / vec2(0.75, 0.38);
	float sheen = exp(-dot(lower_light, lower_light) * 2.0);
	vec3 color = mix(pink_color.rgb, cream_color.rgb, glow * 0.88);
	color = mix(color, cream_color.rgb, sheen * 0.28);
	// A world-space contact shadow anchors the base without realtime reflection
	// or a transparent shadow mesh; its boundary has no hard alpha cutoff.
	vec2 shadow_pos = (world_position.xz - vec2(0.06, 0.10) * board_radius) / board_radius;
	float distance_from_base = length(shadow_pos);
	float contact = 1.0 - smoothstep(0.87, 1.22, distance_from_base);
	float broad = exp(-dot(shadow_pos, shadow_pos) * 1.7);
	color = mix(color, shadow_color.rgb, contact * 0.22 + broad * 0.08);
	ALBEDO = color;
}
