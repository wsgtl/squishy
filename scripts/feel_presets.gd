extends RefCounted

# Ratings map each parameter's own maximum; recovery time is inverse:
# more rebound means a shorter recovery, not a longer wait.
const TYPES := [
 {"name":"水润嫩滑", "description":"水润柔软", "products":"关东煮、海洋生物", "soft":4, "bounce":3},
 {"name":"绵密泥感", "description":"绵密浓郁、略显厚重的柔软手感。", "products":"舒芙蕾、蛋糕卷", "soft":4, "bounce":2},
 {"name":"紧实弹韧", "description":"紧实饱满、弹力较强的手感（粘稠橡胶）", "products":"大福、可丽饼", "soft":3, "bounce":4},
]

# One product per feel; update these paths when new product assets arrive.
const MODELS := ["res://glb/fy.glb", "res://glb/sfl.glb", "res://glb/banana.glb"]

static func model_path(index: int) -> String:
 return MODELS[clampi(index, 0, MODELS.size() - 1)]

# Shared material controls for every normal squish action.
const RESPONSE := [
 {"limit":1.0,"recovery":1.3,"elasticity":0.75,"bounce":0.40,"single":false,"stretch_speed":1.0,"single_damping":0.65},
 {"limit":0.69444444,"recovery":2.1,"elasticity":0.18,"bounce":0.12,"single":true,"stretch_speed":1.3,"single_damping":0.58},
 {"limit":1.0,"recovery":1.04,"elasticity":0.8,"bounce":0.48,"single":false,"stretch_speed":1.0,"single_damping":0.65},
]

static func parameters(index: int) -> Dictionary:
 var selected := clampi(index,0,TYPES.size()-1)
 var type: Dictionary = TYPES[selected]
 var response: Dictionary = RESPONSE[selected]
 var soft: float = type.soft/5.0
 var limit: float = response.limit
 return {"softness":1.6*soft,"min_depth":0.5*soft*limit,
 "grip_deformation_scale":soft/0.8*limit,"twist_deformation_scale":soft/0.8*limit,
 "stretch_sensitivity":2.5*soft,"max_stretch":3.6*soft*limit,
 "recovery_time":response.recovery,"elasticity":response.elasticity,
 "initial_bounce":response.bounce,"rebound_vibration":0.5*response.elasticity,
 "single_rebound":response.single,"single_rebound_damping":response.single_damping,
 "stretch_recovery_speed":response.stretch_speed}
