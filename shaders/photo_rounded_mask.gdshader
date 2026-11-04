shader_type canvas_item;
uniform vec2 preview_size = vec2(494.0, 623.0);
uniform float corner_radius : hint_range(0.0, 100.0) = 32.0;
void fragment() {
	// In canvas_item fragment(), COLOR already includes the texture sample.
	// Preserve RGB and modulate only alpha for the rounded mask.
	vec4 photo = COLOR;
	vec2 half_size = max(preview_size * 0.5, vec2(1.0));
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 q = abs((UV - vec2(0.5)) * preview_size) - half_size + vec2(radius);
	float edge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float feather = max(fwidth(edge), 0.5);
	photo.a *= 1.0 - smoothstep(-feather, feather, edge);
	COLOR = photo;
}
