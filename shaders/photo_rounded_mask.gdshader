shader_type canvas_item;
uniform vec2 preview_size = vec2(494.0, 623.0);
uniform float corner_radius : hint_range(0.0, 100.0) = 32.0;
void fragment() {
	// Center-crop only the preview UVs. The encoded JPEG keeps the full frame.
	vec2 source_size = vec2(textureSize(TEXTURE, 0));
	float source_aspect = source_size.x / max(source_size.y, 1.0);
	float target_aspect = preview_size.x / max(preview_size.y, 1.0);
	vec2 sample_scale = vec2(min(1.0, target_aspect / source_aspect), min(1.0, source_aspect / target_aspect));
	vec2 sample_uv = (UV - vec2(0.5)) * sample_scale + vec2(0.5);
	vec4 photo = texture(TEXTURE, sample_uv);
	vec2 half_size = max(preview_size * 0.5, vec2(1.0));
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 q = abs((UV - vec2(0.5)) * preview_size) - half_size + vec2(radius);
	float edge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float feather = max(fwidth(edge), 0.5);
	photo.a *= 1.0 - smoothstep(-feather, feather, edge);
	COLOR = photo;
}
