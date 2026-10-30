extends RefCounted

# Ratings map each parameter's own maximum; recovery time is inverse:
# more rebound means a shorter recovery, not a longer wait.
const TYPES := [
 {"name":"水润嫩滑", "description":"水润柔软", "products":"关东煮、海洋生物", "soft":4, "bounce":3},
 {"name":"绵密泥感", "description":"绵密浓郁、略显厚重的柔软手感。", "products":"舒芙蕾、蛋糕卷", "soft":4, "bounce":2},
 {"name":"紧实弹韧", "description":"紧实饱满、弹力较强的手感（粘稠橡胶）", "products":"大福、可丽饼", "soft":3, "bounce":4},
 {"name":"绵密黄油感", "description":"紧实弹韧、按压时会舒适下陷（冰黄油）", "products":"木棉豆腐（老豆腐）", "soft":2, "bounce":2},
]

static func parameters(index: int) -> Dictionary:
 var type: Dictionary = TYPES[clampi(index, 0, TYPES.size()-1)]
 var soft: float = type.soft / 5.0
 var bounce: float = type.bounce / 5.0
 return {"softness":1.6*soft, "min_depth":0.5*soft,
 "grip_deformation_scale":soft/0.8, "twist_deformation_scale":soft/0.8,
 "stretch_sensitivity":2.5*soft, "max_stretch":3.6*soft,
 "recovery_time":lerpf(4.0,0.3,bounce), "elasticity":bounce,
 "initial_bounce":0.6*bounce, "rebound_vibration":0.5*bounce}
