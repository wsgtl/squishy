shader_type canvas_item;
uniform float top = 0.64;
uniform float bottom = 0.862;
uniform float edge = 0.0125;
void fragment() {
	COLOR.a *= smoothstep(top, top + edge, SCREEN_UV.y) * (1.0 - smoothstep(bottom - edge, bottom, SCREEN_UV.y));
}
