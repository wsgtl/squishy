shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

uniform int cell_count = 0;
uniform vec3 cell_seeds[64];
uniform float cell_damage[64];
uniform vec3 partition_axis = vec3(1.0,0.0,0.0);
uniform vec3 model_center;
uniform vec3 wax_anchor = vec3(0.0);
uniform vec3 wax_bend = vec3(0.0);
uniform float model_radius = 1.0;
uniform float opacity : hint_range(0.0, 1.0) = 0.55;
uniform float stress_opacity = 0.96;
uniform vec4 stress_color : source_color = vec4(0.913725, 0.913725, 0.898039, 1.0);
uniform float strain_gain = 2.272727;
varying vec3 rest_point;

vec3 wax_offset(vec3 p) {
	float sigma=max(model_radius*0.65,0.00001);
	vec3 centered=p-model_center;
	vec3 axis=normalize(wax_anchor-model_center+vec3(0.000001));
	vec3 relative=p-wax_anchor;
	float local_weight=exp(-dot(relative,relative)/(2.0*sigma*sigma));
	vec3 opposite=model_center-(wax_anchor-model_center);
	vec3 opposite_relative=p-opposite;
	float opposite_weight=exp(-dot(opposite_relative,opposite_relative)/(2.0*sigma*sigma));
	float radial=dot(wax_bend,axis);
	vec3 transverse=centered-axis*dot(centered,axis);
	float contraction=clamp(radial/max(model_radius,0.00001),-0.5,0.5)*0.20;
	return wax_bend*local_weight+axis*radial*opposite_weight*0.30-transverse*contraction;
}

void vertex() {
	rest_point=VERTEX;
	float epsilon=max(model_radius*0.002,0.00001);
	vec3 offset=wax_offset(VERTEX);
	mat3 jacobian=mat3(
		vec3(1.0,0.0,0.0)+(wax_offset(VERTEX+vec3(epsilon,0.0,0.0))-offset)/epsilon,
		vec3(0.0,1.0,0.0)+(wax_offset(VERTEX+vec3(0.0,epsilon,0.0))-offset)/epsilon,
		vec3(0.0,0.0,1.0)+(wax_offset(VERTEX+vec3(0.0,0.0,epsilon))-offset)/epsilon);
	if (abs(determinant(jacobian))>0.00001) { NORMAL=normalize(transpose(inverse(jacobian))*NORMAL); }
	VERTEX+=offset;
}

void fragment() {
	// Match StandardMaterial3D.vertex_color_is_srgb on the detached fragments.
	vec3 c = COLOR.rgb;
	ALBEDO = mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
	// Evaluate at each pixel, independently of fracture partition IDs.
	float sigma = max(model_radius * 0.65, 0.00001);
	vec3 relative = rest_point - wax_anchor;
	float weight = exp(-dot(relative, relative) / (2.0 * sigma * sigma));
	float strain = length(wax_bend) * length(relative) * weight / (sigma * sigma);
	float whitening = smoothstep(0.0, 0.75, clamp(strain * strain_gain * 0.65, 0.0, 0.45));
	ALBEDO = mix(ALBEDO, stress_color.rgb, whitening);
	float crack_distance = model_radius;
	if (cell_count > 0) {
		float nearest = 1e20;
		float second = 1e20;
		int first_id = 0;
		int second_id = 0;
		for (int i=0; i<64; i++) {
			if (i>=cell_count) { break; }
			vec3 delta = rest_point-cell_seeds[i];
			float along = dot(delta,partition_axis);
			float metric = dot(delta,delta)+along*along*3.0;
			if (metric<nearest) {
				second=nearest; second_id=first_id;
				nearest=metric; first_id=i;
			} else if (metric<second) { second=metric; second_id=i; }
		}
		vec3 difference=cell_seeds[second_id]-cell_seeds[first_id];
		vec3 weighted=difference+partition_axis*dot(difference,partition_axis)*3.0;
		float distance_to_border=(second-nearest)/max(2.0*length(weighted),0.00001);
		// Use the owning cell's damage so a neighbour cannot make this whole cell
		// look detached before its own release state is complete.
		float damage=cell_damage[first_id];
		// Only real shared cell boundaries can open: no independent crossing cuts.
		float phase=dot((cell_seeds[first_id]+cell_seeds[second_id])/model_radius,vec3(7.1,13.7,3.3));
		float reveal=0.5+0.5*sin(dot(rest_point/model_radius,vec3(5.3,3.7,4.1))+phase);
		float visible=smoothstep(reveal*0.65,reveal*0.65+0.18,damage);
		crack_distance=distance_to_border+(1.0-visible)*model_radius;
	}
	float rim = 1.0-smoothstep(model_radius*0.005,model_radius*0.018,crack_distance);
	ALBEDO = mix(ALBEDO,stress_color.rgb,rim);
	if (crack_distance < model_radius*0.003) { discard; }
	whitening = max(whitening,rim);
	ROUGHNESS = 0.68;
	SPECULAR = 0.25;
	ALPHA = mix(max(opacity, COLOR.a), stress_opacity, whitening);
}
