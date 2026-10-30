extends Control
var host: Node3D
var choices: Array[Button] = []
var description: Label
const Presets = preload("res://scripts/feel_presets.gd")

func setup(scene: Node3D, font: Font) -> void:
 host = scene
 name = "HomeScreen"
 set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
 mouse_filter = Control.MOUSE_FILTER_IGNORE
 var theme := Theme.new()
 theme.default_font = font
 theme.default_font_size = 22
 self.theme = theme
 var language := LocaleManager.make_selector(font)
 add_child(language)
 language.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
 language.offset_left = -252
 language.offset_right = -24
 language.offset_top = 24
 language.offset_bottom = 88
 var title := Label.new()
 title.text = tr("punikko 捏捏乐")
 title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
 title.add_theme_font_size_override("font_size",42)
 title.add_theme_color_override("font_color",Color("#537c80"))
 add_child(title)
 title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
 title.offset_top = 132
 title.offset_bottom = 196
 var note := Label.new()
 note.text = tr("选一种喜欢的手感，开始放松吧")
 note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
 note.add_theme_color_override("font_color",Color("#735d46"))
 add_child(note)
 note.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
 note.offset_top = 205
 note.offset_bottom = 242
 var card := PanelContainer.new()
 add_child(card)
 card.anchor_left = 0.06
 card.anchor_right = 0.94
 card.anchor_top = 0.64
 card.anchor_bottom = 0.88
 var style := StyleBoxFlat.new()
 style.bg_color = Color(0.95,0.98,0.97,0.96)
 style.set_corner_radius_all(20)
 style.set_content_margin_all(16)
 card.add_theme_stylebox_override("panel",style)
 var scroll := ScrollContainer.new()
 card.add_child(scroll)
 scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
 var box := VBoxContainer.new()
 box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 box.add_theme_constant_override("separation",10)
 scroll.add_child(box)
 var heading := Label.new()
 heading.text = tr("选择手感")
 heading.add_theme_color_override("font_color",Color("#537c80"))
 box.add_child(heading)
 var grid := GridContainer.new()
 grid.columns = 2
 grid.add_theme_constant_override("h_separation",10)
 grid.add_theme_constant_override("v_separation",10)
 box.add_child(grid)
 var group := ButtonGroup.new()
 for i in range(Presets.TYPES.size()):
  var type: Dictionary = Presets.TYPES[i]
  var button := Button.new()
  button.name = "FeelChoice" + str(i)
  button.text = tr("%s\n柔软 %d/5星 · 回弹 %d/5星") % [tr(type.name), type.soft, type.bounce]
  button.toggle_mode = true
  button.button_group = group
  button.custom_minimum_size.y = 72
  button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
  button.add_theme_font_size_override("font_size",20)
  var normal := StyleBoxFlat.new()
  normal.bg_color = Color("#e4eded")
  normal.set_corner_radius_all(12)
  normal.set_content_margin_all(8)
  button.add_theme_stylebox_override("normal",normal)
  var selected := normal.duplicate() as StyleBoxFlat
  selected.bg_color = Color("#bcdedd")
  selected.border_color = Color("#56898b")
  selected.set_border_width_all(3)
  button.add_theme_stylebox_override("pressed",selected)
  button.add_theme_color_override("font_color",Color("#3e6568"))
  button.add_theme_color_override("font_pressed_color",Color("#244d50"))
  button.pressed.connect(func(): select(i))
  grid.add_child(button)
  choices.append(button)
 description = Label.new()
 description.add_theme_font_size_override("font_size",19)
 description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
 description.add_theme_color_override("font_color",Color("#735d46"))
 box.add_child(description)
 var start := Button.new()
 start.name = "StartSquishingButton"
 start.text = tr("开始捏它")
 start.add_theme_font_size_override("font_size",32)
 add_child(start)
 start.anchor_left = 0.06
 start.anchor_right = 0.94
 start.anchor_top = 0.90
 start.anchor_bottom = 0.97
 start.pressed.connect(host._start_game)
 select(0)

func select(index: int) -> void:
 host._apply_feel(index)
 for i in range(choices.size()):
  choices[i].set_pressed_no_signal(i == index)
 var type: Dictionary = Presets.TYPES[index]
 description.text = tr("%s\n对应商品：%s") % [tr(type.description),tr(type.products)]

func refresh_language() -> void:
 for i in range(choices.size()):
  var type: Dictionary = Presets.TYPES[i]
  choices[i].text = tr("%s\n柔软 %d/5星 · 回弹 %d/5星") % [tr(type.name), type.soft, type.bounce]
 var type: Dictionary = Presets.TYPES[host._selected_feel]
 description.text = tr("%s\n对应商品：%s") % [tr(type.description), tr(type.products)]
