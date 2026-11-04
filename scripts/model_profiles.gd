extends RefCounted

# Per-model presentation offsets, applied after imported axes are baked.
# Unlisted models keep their authored default orientation.
const DEFAULT_ROTATIONS := {
	"res://glb/sfl.glb": Vector3(0.0, 180.0, 0.0),
}

static func rotation_degrees_for(model_path: String) -> Vector3:
	return DEFAULT_ROTATIONS.get(model_path, Vector3.ZERO)
