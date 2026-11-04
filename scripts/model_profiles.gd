extends RefCounted

# Per-model presentation offsets, applied after imported axes are baked.
# Unlisted models keep their authored default orientation.
const DEFAULT_ROTATIONS := {
	"res://glb/sfl.glb": Vector3(0.0, 180.0, 0.0),
}

# Surface calibration only; all products share the same scene lighting.
# Keep the imported albedo/UVs untouched, including painted artwork.
const MATERIAL_PROFILES := {
	"res://glb/sfl.glb": {"material_roughness": 0.95, "material_specular": 0.18, "normal_strength": 0.75},
	"res://glb/df.glb": {"material_roughness": 0.96, "material_specular": 0.16, "normal_strength": 0.55},
	"res://glb/tofu.glb": {"material_roughness": 1.0, "material_specular": 0.12, "normal_strength": 0.4},
}

static func rotation_degrees_for(model_path: String) -> Vector3:
	return DEFAULT_ROTATIONS.get(model_path, Vector3.ZERO)

static func material_for(model_path: String) -> Dictionary:
	return MATERIAL_PROFILES.get(model_path, {}).duplicate()
