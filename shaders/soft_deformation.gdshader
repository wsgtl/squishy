shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_albedo_texture = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal_texture = false;
uniform float normal_strength = 1.0;
uniform float material_roughness = 0.6;
uniform float material_metallic = 0.0;
uniform vec3 model_center;
uniform vec3 model_size = vec3(1.0);
uniform float model_radius = 1.0;
uniform vec3 anchor_point;
uniform vec3 anchor_normal = vec3(0.0, 1.0, 0.0);
uniform float press_amount = 0.0;
uniform float squash_amount = 0.0;
uniform float press_depth = 0.32;
uniform float finger_width = 0.138;
uniform float softness = 0.9;
uniform float squash_strength = 0.10;
uniform vec3 pull = vec3(0.0);
uniform vec3 stretch_axis = vec3(1.0, 0.0, 0.0);
uniform float stretch_amount = 0.0;

uniform int trail_count = 0;
uniform vec3 trail_points[20];
uniform vec3 trail_ends[20];
uniform float trail_end_amounts[20];
uniform vec3 trail_normals[20];
uniform float trail_amounts[20];

vec3 dent_at(vec3 p, vec3 point, vec3 normal, float amount) {
	vec3 relative = p - point;
	float axial = dot(relative, normal);
	vec3 tangent = relative - normal * axial;
	float sigma = model_radius * finger_width * (0.85 + softness * 0.25);
	float radial_sq = dot(tangent, tangent) / (sigma * sigma);
	float depth_ratio = axial / (model_radius * 0.42);
	float depth_mask = exp(-depth_ratio * depth_ratio);
	float dent = exp(-radial_sq * 0.5);
	float rim = radial_sq * dent * 0.06;
	float depth = min(press_depth * model_radius * 1.5, min(dot(model_size, abs(normal)) * 0.45, sigma * 1.5));
	return normal * (rim - dent) * depth * clamp(amount, -0.1, 1.0) * depth_mask;
}

vec3 deform(vec3 p) {
	vec3 relative = p - anchor_point;
	vec3 offset = dent_at(p, anchor_point, anchor_normal, press_amount);
	float max_squared = dot(offset, offset);
	float weight_sum = max_squared > 0.0 ? 1.0 : 0.0;
	vec3 weighted_offset = offset * weight_sum;
	for (int i = 0; i < 20; i++) {
		if (i >= trail_count) { break; }
		vec3 normal = trail_normals[i];
		vec3 segment = trail_ends[i] - trail_points[i];
		vec3 tangent = segment - normal * dot(segment, normal);
		float weight = clamp(dot(p - trail_points[i], tangent) / max(dot(tangent, tangent), 0.00000001), 0.0, 1.0);
		vec3 trail = dent_at(p, mix(trail_points[i], trail_ends[i], weight), normal, mix(trail_amounts[i], trail_end_amounts[i], weight));
		float squared = dot(trail, trail);
		if (squared > max_squared) {
			float ratio = max_squared / squared;
			weighted_offset *= ratio * ratio;
			weight_sum *= ratio * ratio;
			max_squared = squared;
		}
		if (max_squared > 0.0) {
			float ratio = squared / max_squared;
			float trail_weight = ratio * ratio;
			weighted_offset += trail * trail_weight;
			weight_sum += trail_weight;
		}
	}
	offset = weighted_offset / max(weight_sum, 1.0);
	float bottom = model_center.y - model_size.y * 0.5;
	float squash = clamp(squash_amount * squash_strength, -0.04, 0.18);
	float spread = inversesqrt(1.0 - squash) - 1.0;
	offset += vec3((p.x - model_center.x) * spread, -(p.y - bottom) * squash, (p.z - model_center.z) * spread);
	float pull_length = stretch_amount;
	if (abs(pull_length) > model_radius * 0.00001) {
		vec3 direction = stretch_axis;
		vec3 centered = p - model_center;
		float strain = pull_length / (model_radius * 2.0);
		float factor = strain >= 0.0 ? 1.0 + strain : max(0.35, exp(strain));
		float neck_strength = smoothstep(0.65, 2.6, pull_length / model_radius);
		float half_extent = max(dot(abs(direction), model_size * 0.5), model_radius * 0.01);
		float along = dot(centered, direction);
		float axis_position = along / half_extent;
		float neck_weight = exp(-0.5 * (axis_position / 0.36) * (axis_position / 0.36));
		float thin = mix(inversesqrt(factor), 1.0, neck_strength * (1.0 - neck_weight));
		thin = max(0.16, thin * (1.0 - 0.82 * neck_strength * neck_weight));
		float strain_profile = mix(axis_position, tanh(axis_position * 2.2) / tanh(2.2), neck_strength * 0.8);
		float stretched_along = along + (factor - 1.0) * half_extent * strain_profile;
		vec3 stretched = direction * stretched_along + (centered - direction * along) * thin;
		stretched.y = bottom - model_center.y + (p.y - bottom) * thin;
		float grab_sigma = model_radius * (0.75 + softness * 0.25);
		float grab = exp(-dot(relative, relative) / (2.0 * grab_sigma * grab_sigma));
		offset += stretched - centered + pull * (0.10 + grab * 0.15);
	}
	if (offset.y < 0.0) {
		float height = max(p.y - bottom, 0.0);
		float compressible = max(height * 0.85, model_radius * 0.000001);
		offset.y = -height * 0.85 * (1.0 - exp(offset.y / compressible));
	}
	return p + offset;
}

void vertex() {
	// Differentiate the continuous field on GPU. No CPU normal reconstruction,
	// vertex uploads or surface allocations are needed while interacting.
	vec3 p = VERTEX;
	vec3 n = normalize(NORMAL);
	vec3 reference = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t = normalize(cross(reference, n));
	vec3 b = cross(n, t);
	float epsilon = model_radius * 0.002;
	vec3 deformed = deform(p);
	vec3 dt = deform(p + t * epsilon) - deformed;
	vec3 db = deform(p + b * epsilon) - deformed;
	vec3 new_normal = cross(dt, db);
	if (dot(new_normal, new_normal) > 1e-20) {
		NORMAL = normalize(new_normal);
	}
	if (has_normal_texture) {
		vec3 deformed_tangent = deform(p + TANGENT * epsilon) - deformed;
		vec3 deformed_binormal = deform(p + BINORMAL * epsilon) - deformed;
		vec3 tangent_projected = deformed_tangent - NORMAL * dot(NORMAL, deformed_tangent);
		vec3 binormal_projected = deformed_binormal - NORMAL * dot(NORMAL, deformed_binormal);
		TANGENT = length(tangent_projected) > 1e-8 ? normalize(tangent_projected) : t;
		BINORMAL = length(binormal_projected) > 1e-8 ? normalize(binormal_projected) : cross(NORMAL, TANGENT);
	}
	VERTEX = deformed;
}

void fragment() {
	vec4 color = base_color;
	if (has_albedo_texture) {
		color *= texture(albedo_texture, UV);
	}
	ALBEDO = color.rgb;
	if (has_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	ROUGHNESS = material_roughness;
	METALLIC = material_metallic;
}
