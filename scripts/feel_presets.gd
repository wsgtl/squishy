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
 {"limit":1.0,"stretch_limit":2.88,"stretch_input":2.0,"rebound_speed":0.48,"rebound_damping":0.72,"press_depth":0.48,"press_duration":0.6,"recovery":2.4,"elasticity":0.75,"bounce":0.40,"single":false,"stretch_speed":1.0,"single_damping":0.65},
 {"limit":0.69444444,"stretch_limit":1.4,"stretch_input":1.45,"rebound_speed":0.72,"press_depth":0.27777778,"press_duration":2.0,"recovery":2.8,"elasticity":0.18,"bounce":0.12,"single":true,"stretch_speed":1.0,"single_damping":0.58},
 {"limit":1.0,"stretch_limit":1.05,"stretch_input":1.1,"rebound_speed":1.0,"press_depth":0.30,"press_duration":2.8,"recovery":1.04,"elasticity":0.8,"bounce":0.48,"single":false,"stretch_speed":1.0,"single_damping":0.65},
]

static func parameters(index: int) -> Dictionary:
 var selected := clampi(index,0,TYPES.size()-1)
 var type: Dictionary = TYPES[selected]
 var response: Dictionary = RESPONSE[selected]
 var soft: float = type.soft/5.0
 var limit: float = response.limit
 return {"softness":1.6*soft,"min_depth":response.press_depth,"press_duration":response.press_duration,
 "press_depth_scale":1.3 if selected == 0 else 1.0,
 "twist_extra_length":0.30 if selected == 0 else 0.0,
 "twist_end_angle":0.35 if selected == 0 else 0.0,
 "grip_waist_scale":1.35 if selected == 0 else 1.0,
 "grip_end_scale":1.55 if selected == 0 else 1.0,
 "grip_deformation_scale":soft/0.8*limit,"twist_deformation_scale":soft/0.8*limit,
 "stretch_sensitivity":response.stretch_input,"max_stretch":response.stretch_limit,
 "rebound_speed_scale":response.rebound_speed,
 "rebound_damping_override":response.get("rebound_damping", -1.0),
 "recovery_time":response.recovery,"elasticity":response.elasticity,
 "initial_bounce":response.bounce,"rebound_vibration":0.5*response.elasticity,
 "single_rebound":response.single,"single_rebound_damping":response.single_damping,
 "stretch_recovery_speed":response.stretch_speed}
