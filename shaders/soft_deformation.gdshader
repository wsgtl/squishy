shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_albedo_texture = false;
uniform sampler2D doodle_texture : source_color, filter_linear, repeat_disable;
uniform bool has_doodle_texture = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal_texture = false;
uniform float normal_strength = 1.0;
uniform float material_roughness = 0.6;
uniform float material_metallic = 0.0;
uniform float dent_shadow_strength : hint_range(0.0, 0.8) = 0.225;
varying float dent_shadow;
uniform vec3 model_center;
uniform vec3 model_size = vec3(1.0);
uniform float model_radius = 1.0;
uniform vec3 anchor_point;
uniform vec3 anchor_normal = vec3(0.0, 1.0, 0.0);
uniform bool raised_rim_press = true;
uniform float press_amount = 0.0;
uniform bool twist_mode = false;
uniform vec3 twist_axis = vec3(0.0, 0.0, -1.0);
uniform float twist_extent = 1.0;
uniform float twist_direction = 1.0;
uniform float twist_deformation_scale = 1.0;
uniform float grip_amount = 0.0;
uniform vec4 grip_pose = vec4(0.0);
uniform float grip_stage = 0.0;
uniform float grip_shake = 0.0;
uniform float grip_shake_vertical = 0.0;
uniform vec3 grip_axis = vec3(1.0, 0.0, 0.0);
uniform float grip_extent = 1.0;
uniform float grip_width = 1.0;
uniform float grip_hand_half_width = 0.27;
uniform float squash_amount = 0.0;
uniform float press_depth = 0.32;
uniform float finger_width = 0.138;
uniform float softness = 0.9;
uniform float squash_strength = 0.10;
uniform vec3 pull = vec3(0.0);
uniform vec3 stretch_axis = vec3(1.0, 0.0, 0.0);
uniform float stretch_amount = 0.0;
uniform vec4 stretch_shape = vec4(1.0, 0.0, 1.0, 1.0);

uniform vec3 grab_point_a;
uniform vec3 grab_point_b;
uniform vec3 grab_normal_a = vec3(0.0, 1.0, 0.0);
uniform vec3 grab_normal_b = vec3(0.0, 1.0, 0.0);
uniform float grab_pressure = 0.0;
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
	if (!raised_rim_press) {
		return normal * (rim - dent) * depth * clamp(amount, -0.1, 1.0) * depth_mask;
	}
	depth = min(press_depth * model_radius * 2.1, min(dot(model_size, abs(normal)) * 0.63, sigma * 2.1));
	float bottom = model_center.y - model_size.y * 0.5;
	float height = clamp((p.y - bottom) / max(model_size.y, 0.000001), 0.0, 1.0);
	float base_mask = smoothstep(0.0, 0.65, height);
	float gather_radius = model_radius * 0.85;
	float broad = exp(-dot(tangent, tangent) / (2.0 * gather_radius * gather_radius));
	vec2 normalized_position = (p.xz - model_center.xz) / max(model_size.xz * 0.5, vec2(0.000001));
	float edge = smoothstep(0.50, 0.95, length(normalized_position));
	float pressure = clamp(amount, 0.0, 1.0);
	vec3 inward = -tangent * 0.24 * broad * pressure * base_mask;
	vec3 curl = vec3(0.0, (depth / 1.4) * 0.70 * edge * broad * pressure * base_mask * abs(normal.y), 0.0);
	return -normal * dent * depth * pressure * depth_mask * base_mask + inward + curl;
}

vec3 grab_dent(vec3 p, vec3 point, vec3 normal) {
	vec3 relative = p - point;
	float axial = dot(relative, normal);
	vec3 tangent = relative - normal * axial;
	float sigma = model_radius * finger_width;
	float depth_ratio = axial / (model_radius * 0.32);
	float mask = exp(-dot(tangent, tangent) / (2.0 * sigma * sigma) - depth_ratio * depth_ratio);
	float depth = min(sigma * 0.7, dot(model_size, abs(normal)) * 0.2);
	return -normal * depth * mask * grab_pressure;
}

float grip_finger_profile(float z) {
	float profile = 0.0;
	for (int i = 0; i < 4; i++) {
		float center = -0.72 + float(i) * 0.48;
		float t = (z - center) / 0.30;
		float bump = max(1.0 - t * t, 0.0);
		profile += bump * bump;
	}
	return profile;
}

vec3 twist_offset(vec3 p) {
	float amount = grip_amount * twist_deformation_scale;
	vec3 c = p - model_center;
	float axial = dot(c, twist_axis);
	float t = clamp(axial / twist_extent, -1.0, 1.0);
	vec3 radial = c - twist_axis * axial;
	float waist = 1.0 - t * t;
	float angle = twist_direction * 1.8325957146 * sin(t * 3.14159265359 * 0.5) * amount;
	float ends = smoothstep(0.25, 0.90, abs(t));
	vec3 side = normalize(cross(twist_axis, vec3(0.0, 1.0, 0.0)));
	float side_extent = max(abs(side.x) * model_size.x * 0.5 + abs(side.z) * model_size.z * 0.5, 0.000001);
	float ry = radial.y / max(model_size.y * 0.5, 0.000001);
	float rx = dot(radial, side) / side_extent;
	float rho = sqrt(rx * rx + ry * ry);
	float theta = rho > 0.00001 ? atan(ry, rx) : 0.0;
	// Integer angular frequencies keep the seam continuous. Axial pitch tightens
	// at the waist; warped phases and local envelopes avoid parallel grooves.
	float pitch = 3.14159265359 * (6.0 * t - 2.0 * t * t * t);
	float warp = 0.65 * sin(2.0 * theta + 3.1 * t) + 0.28 * sin(3.0 * theta - 5.3 * t);
	float phase = 5.0 * theta - twist_direction * pitch + warp;
	float secondary = 8.0 * theta - twist_direction * (pitch * 1.37 + 1.1 * sin(2.7 * t)) + 0.7 * sin(theta + 4.2 * t);
	float fine = 11.0 * theta - twist_direction * pitch * 1.85 + 0.9 * sin(3.0 * theta + 2.3 * t);
	float depth = 0.76 + 0.24 * sin(theta - 4.1 * t);
	float local_fold = 0.5 + 0.5 * sin(2.0 * theta + 5.7 * t + 0.8);
	float wave = (0.065 + 0.045 * ends) * sin(phase) * depth + 0.045 * waist * sin(secondary) * local_fold + 0.022 * waist * waist * sin(fine);
	float wrinkle = wave * smoothstep(0.15, 0.9, rho) * (1.0 - smoothstep(0.90, 1.0, abs(t))) * pow(max(amount, 0.0), 1.5);
	radial *= 1.0 + (-0.23 * waist + 0.20 * ends) * amount + wrinkle;
	vec3 rotated = radial * cos(angle) + cross(twist_axis, radial) * sin(angle);
	vec3 result = rotated + twist_axis * axial * (1.0 + 0.06 * amount) - c;
	result.y += model_radius * 1.8 * smoothstep(0.0, 1.0, grip_stage);
	return result + grip_axis * grip_shake + cross(grip_axis, vec3(0.0, 1.0, 0.0)) * grip_shake_vertical;
}

vec3 grip_offset(vec3 p) {
	if (twist_mode) { return twist_offset(p); }
	vec4 pose = grip_pose;
	vec3 centered = p - model_center;
	vec3 along = cross(grip_axis, vec3(0.0, 1.0, 0.0));
	vec3 c = vec3(dot(centered, grip_axis), centered.y, dot(centered, along));
	float extent = grip_extent;
	float width = grip_width;
	float hand = max(grip_hand_half_width, 0.000001);
	float nx = c.x / max(width, 0.000001);
	float z = c.z / max(extent, 0.000001);
	float nz = clamp(abs(z), 0.0, 1.0);
	float y = c.y / max(model_size.y * 0.5, 0.000001);
	// Oblique contact frame: four fingers rise toward the inside of the palm.
	float hand_z = c.z / hand - (0.10 + 0.18 * pose.w) * nx;
	float waist = 1.0 - smoothstep(0.50, 1.50, abs(hand_z));
	float ends = 1.0 - waist;
	float pressure = pose.z;
	float left = 1.0 - smoothstep(-0.35, 0.35, nx);
	float finger_side = 1.0 - smoothstep(-0.70, 0.10, nx);
	float fingers = grip_finger_profile(hand_z) * finger_side * smoothstep(-0.9, -0.2, y) * pressure;
	// Broad, rounded thumb pad, diagonally crossing the upper-right surface.
	float dx = (c.x - width * (0.54 - 0.06 * pose.w)) / hand;
	float dz = c.z / hand + (1.20 - 0.10 * pose.w);
	float thumb_angle = mix(0.26, 0.61, max(pose.w, 0.0));
	float u = (cos(thumb_angle) * dx + sin(thumb_angle) * dz) / 1.02;
	float v = (-sin(thumb_angle) * dx + cos(thumb_angle) * dz) / 0.48;
	float thumb_bump = max(1.0 - u * u - v * v, 0.0);
	float thumb = thumb_bump * thumb_bump * smoothstep(-0.5, 0.55, y) * pressure;
	float round_end = ends * (1.0 - 0.30 * nz * nz);
	float cap_x = clamp(nx, -1.0, 1.0);
	float cap = 1.0 - cap_x * cap_x;
	float fold = sin(hand_z * 3.14159265359 * 3.0 + y * 1.4) * 0.008 * waist * pressure;
	vec3 offset = vec3(c.x * (-(0.406 + 0.112 * left) * waist * pose.x + 0.24 * round_end * pose.y) + c.x * fold + width * (0.12 * fingers - 0.16 * thumb),
		c.y * (-0.336 * waist * pose.x + 0.60 * round_end * (0.65 + 0.35 * cap) * pose.y) + c.y * fold - model_size.y * (0.16 * fingers * smoothstep(-0.1, 0.65, y) + 0.46 * thumb),
		c.z * smoothstep(1.0, 1.5, abs(hand_z)) * (0.12 + 0.12 * (1.0 - nz * nz) + 0.12 * cap) * pose.y - hand * 0.07 * thumb);
	// Opposing end roll and palm shear produce a twisted grip, not a rigid rotation.
	vec3 deformed = c + offset;
	float roll = 0.24 * clamp(c.z / hand, -1.0, 1.0) * pose.w;
	float rolled_x = cos(roll) * deformed.x - sin(roll) * deformed.y;
	float rolled_y = sin(roll) * deformed.x + cos(roll) * deformed.y;
	offset.x = rolled_x - c.x - width * 0.20 * z * pose.w;
	offset.y = rolled_y - c.y;
	offset.z += hand * 0.08 * nx * waist * pose.w;
	offset.y += model_radius * 1.8 * smoothstep(0.0, 1.0, grip_stage);
	return grip_axis * (offset.x + grip_shake) + vec3(0.0, 1.0, 0.0) * offset.y + along * (offset.z + grip_shake_vertical);
}

vec3 deform(vec3 p, out vec3 contact_offset) {
	vec3 relative = p - anchor_point;
	vec3 offset = vec3(0.0);
	// A zero pressure is a valid zero displacement, not a different code path.
	offset = dent_at(p, anchor_point, anchor_normal, press_amount);
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
	if (grab_pressure > 0.0) {
		vec3 grab_a = grab_dent(p, grab_point_a, grab_normal_a);
		vec3 grab_b = grab_dent(p, grab_point_b, grab_normal_b);
		offset += dot(grab_a, grab_a) >= dot(grab_b, grab_b) ? grab_a : grab_b;
	}
	contact_offset = offset * (1.0 - clamp(grip_amount * 1.5, 0.0, 1.0));
	float bottom = model_center.y - model_size.y * 0.5;
	float squash = clamp(squash_amount * squash_strength, -0.04, 0.18);
	float spread = inversesqrt(1.0 - squash) - 1.0;
	offset += vec3((p.x - model_center.x) * spread, -(p.y - bottom) * squash, (p.z - model_center.z) * spread);
	float pull_length = stretch_amount;
	if (abs(pull_length) > model_radius * 0.00001) {
		vec3 direction = stretch_axis;
		vec3 centered = p - model_center;
		float strain = pull_length / (model_radius * 2.0);
		float factor = stretch_shape.x;
		float neck_strength = stretch_shape.y;
		float half_extent = stretch_shape.z;
		float along = dot(centered, direction);
		float axis_position = along / half_extent;
		float neck_weight = exp(-0.5 * (axis_position / 0.36) * (axis_position / 0.36));
		float thin = mix(stretch_shape.w, 1.0, neck_strength * (1.0 - neck_weight));
		thin = max(0.16, thin * (1.0 - 0.82 * neck_strength * neck_weight));
		float strain_profile = mix(axis_position, tanh(axis_position * 2.2) / tanh(2.2), neck_strength * 0.8);
		float stretched_along = along + (factor - 1.0) * half_extent * strain_profile;
		vec3 stretched = direction * stretched_along + (centered - direction * along) * thin;
		// Recoil also rises upward; the bottom remains the thickness pivot.
		float height_scale = thin;
		if (strain < 0.0) {
			vec2 normalized_position = clamp(abs(centered.xz) / max(model_size.xz * 0.5, vec2(model_radius * 0.01)), vec2(0.0), vec2(1.0));
			vec2 dome_axes = cos(normalized_position * 1.57079632679);
			float dome = dome_axes.x * dome_axes.y;
			height_scale = 1.0 + (thin - 1.0) * 1.75 * dome * dome;
		}
		stretched.y = bottom - model_center.y + (p.y - bottom) * height_scale;
		float grab_sigma = model_radius * (0.75 + softness * 0.25);
		float grab = exp(-dot(relative, relative) / (2.0 * grab_sigma * grab_sigma));
		offset += stretched - centered + pull * (0.10 + grab * 0.15);
	}
	if (offset.y < 0.0) {
		float height = max(p.y - bottom, 0.0);
		float compressible = max(height * 0.85, model_radius * 0.000001);
		offset.y = -height * 0.85 * (1.0 - exp(offset.y / compressible));
	}
	return p + offset * (1.0 - clamp(grip_amount * 1.5, 0.0, 1.0)) + grip_offset(p);
}

void vertex() {
	// Differentiate the continuous field on GPU. No CPU normal reconstruction,
	// vertex uploads or surface allocations are needed while interacting.
	vec3 p = VERTEX;
	vec3 n = normalize(NORMAL);
	vec3 reference = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t = normalize(cross(reference, n));
	vec3 b = cross(n, t);
	// Geometry derivatives must not change direction across mirrored UV islands.
	vec3 source_tangent = TANGENT;
	vec3 source_binormal = BINORMAL;
	float epsilon = model_radius * 0.002;
	vec3 contact_offset;
	vec3 scratch_offset;
	vec3 deformed = deform(p, contact_offset);
	// Use only local press displacement: global squash and stretch must not
	// darken the whole object. Reuse the field evaluation already used to render.
	float contact_radius = model_radius * finger_width * (0.85 + softness * 0.25);
	float inward_depth = max(-dot(contact_offset, n), 0.0);
	dent_shadow = 1.0 - exp(-inward_depth / max(contact_radius, 1e-6));
	// Normalize the difference scale BEFORE the cross product. Otherwise its
	// squared magnitude scales with epsilon^4 and can underflow on mobile GPUs.
	vec3 dt = (deform(p + t * epsilon, scratch_offset) - deformed) / epsilon;
	vec3 db = (deform(p + b * epsilon, scratch_offset) - deformed) / epsilon;
	vec3 new_normal = cross(dt, db);
	float normal_length_squared = dot(new_normal, new_normal);
	NORMAL = n;
	if (normal_length_squared > 0.000001) {
		NORMAL = new_normal * inversesqrt(normal_length_squared);
	}
	if (has_normal_texture) {
		// Transport the authored UV frame through the same surface derivatives.
		// Preserve mirrored-island handedness without using it for geometry normals.
		vec3 deformed_tangent = dt * dot(source_tangent, t) + db * dot(source_tangent, b);
		vec3 tangent_projected = deformed_tangent - NORMAL * dot(NORMAL, deformed_tangent);
		float tangent_length_squared = dot(tangent_projected, tangent_projected);
		vec3 fallback_reference = abs(NORMAL.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		TANGENT = tangent_length_squared > 0.000001 ? tangent_projected * inversesqrt(tangent_length_squared) : normalize(cross(fallback_reference, NORMAL));
		float handedness = dot(cross(source_tangent, source_binormal), n) < 0.0 ? -1.0 : 1.0;
		BINORMAL = normalize(cross(NORMAL, TANGENT)) * handedness;
	}
	VERTEX = deformed;
}

void fragment() {
	vec4 color = base_color;
	if (has_albedo_texture) {
		color *= texture(albedo_texture, UV);
	}
	if (has_doodle_texture) {
		vec4 ink = texture(doodle_texture, UV);
		color.rgb = mix(color.rgb, ink.rgb, ink.a);
	}
	float cavity = clamp(dent_shadow, 0.0, 1.0) * dent_shadow_strength;
	ALBEDO = color.rgb * (1.0 - cavity);
	AO = 1.0 - cavity;
	AO_LIGHT_AFFECT = 0.35;
	if (has_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	ROUGHNESS = material_roughness;
	METALLIC = material_metallic;
}
