# 捏捏实验室（Godot Web 原型）

这是一个面向浏览器运行的 3D 捏捏小游戏基础框架。当前原型用程序网格生成软胶球，以鼠标或触屏命中球面，再对球面局部施加按压或拉伸位移；松开后顶点弹簧将形状带回静止网格。它用于验证交互与手感，后续可以替换模型、材质和场景美术。

## 运行

- 使用 Godot 4.7 打开本目录中的 `project.godot`，按 F6/F5 运行。
- 左键按住球面：局部按压；移动指针时按压点跟随。
- 右键拖动或按住 Shift 再左键拖动：拉伸球面。
- 触屏按住：按压；拖动超过阈值后切换为拉伸。
- 调节左上角力度滑杆，或点击右上角“恢复形状”。
- 项目使用 Compatibility 渲染器和 GodotPhysics3D，避免 WebGL 2 不支持的渲染功能及 Jolt Web 导出限制。

## Web 导出

1. 在 Godot 的“项目 > 导出”中确认已安装对应版本的 Web Export Templates。
2. 选择 `Web` 预设并导出。预设输出路径是 `output/web/nienie.html`。
3. 将导出的整个 `output/web/` 目录部署到支持静态文件的 HTTPS 网站，或用本地 HTTP 服务器预览。不要用 `file://` 直接打开 HTML；浏览器需要通过 HTTP(S) 加载 WASM、PCK 和工作线程文件。

导出预设位于 `export_presets.cfg`。浏览器部署需提供 Godot Web 导出所需的 MIME 类型；启用线程导出时还需服务器设置 COOP/COEP 跨源隔离响应头。本项目默认关闭线程支持，通常不需要这组隔离头。

## 目录与文件

```text
.
├── project.godot           # 项目入口、窗口尺寸、输入与渲染/物理设置
├── export_presets.cfg      # Web 平台导出预设和导出目标
├── icon.svg                # Godot 项目图标
├── scenes/
│   └── main.tscn            # 主场景；挂载主控制脚本
├── scripts/
│   ├── main.gd              # 场景搭建、镜头灯光、输入拾取和 HUD
│   └── blob_deformer.gd     # 程序球网格、弹簧形变和网格法线更新
└── output/web/              # Web 导出产物（HTML/JS/WASM/PCK）
```

`.godot/` 是编辑器导入缓存，`.uid` 是 Godot 脚本资源标识；它们由 Godot 管理，不是手写的游戏逻辑。`output/web/` 中若已有导出文件，它们是构建产物，重新导出会覆盖对应文件。

## 软体交互与物理近似

当前效果是**基于网格顶点弹簧的软体近似**，不是 `RigidBody3D` 的刚体碰撞，也不是完整有限元软体求解。碰撞球只负责确定指针命中的世界坐标；可见表面由独立的 `ArrayMesh` 顶点实时变形。

1. **建立静止网格**：`BlobDeformer._build_mesh_data()` 按经纬度生成球面顶点、UV 和三角形索引，并从三角形提取每个顶点的邻接关系。静止顶点保存在 `_rest_positions`。
2. **屏幕拾取**：`main.gd` 用 `Camera3D.project_ray_origin()` 和 `Camera3D.project_ray_normal()` 构造视线，再由 `PhysicsRayQueryParameters3D.create()` 与 `World3D.direct_space_state.intersect_ray()` 命中 `StaticBody3D` 上的 `SphereShape3D`。射线命中坐标作为交互锚点。
3. **局部按压**：命中点转换到模型局部空间并取方向向量。每个顶点根据与锚点的夹角计算高斯权重；按压目标沿径向向内移动，外围加入较小的正向鼓包，形成软胶受压的凹陷与挤出感。按住移动时更新锚点。
4. **拉伸**：右键、Shift+左键或触屏拖动切换到拉伸模式。连续命中点的局部位移累加成 `_pull_offset`，再按顶点到锚点的高斯权重施加到局部表面，并用 `pull_limit` 限制最大拖拽量。
5. **回弹与平滑**：每个 `Node3D._physics_process(delta)` 中以显式弹簧积分更新顶点速度和位置：弹簧力将当前偏移拉向交互目标，阻尼力消耗速度；邻点平滑项减弱尖锐折痕。平滑项减去静止网格本身的离散曲率，避免网格无形变时因拉普拉斯项整体收缩。松手后目标回到静止位置，阻尼让网格振荡衰减。
6. **刷新表面**：重算三角面法线并归一化，将顶点、法线、UV、索引放入 `Mesh.ARRAY_*` 数组，调用 `ArrayMesh.clear_surfaces()` 和 `ArrayMesh.add_surface_from_arrays()` 更新渲染网格。

### 使用的 Godot API

| API | 用途 |
| --- | --- |
| `Node3D._physics_process(delta)` | 以物理帧率推进顶点弹簧积分 |
| `InputEventMouseButton`、`InputEventMouseMotion` | 桌面鼠标按压、拖动与模式选择 |
| `InputEventScreenTouch`、`InputEventScreenDrag` | 触屏按压与拖动 |
| `Camera3D.project_ray_origin()`、`project_ray_normal()` | 从屏幕坐标建立 3D 拾取射线 |
| `PhysicsRayQueryParameters3D.create()` | 配置物理射线查询 |
| `World3D.direct_space_state.intersect_ray()` | 查询指针命中的碰撞体和世界坐标 |
| `StaticBody3D`、`CollisionShape3D`、`SphereShape3D` | 提供稳定的球面拾取碰撞体 |
| `ArrayMesh`、`Mesh.ARRAY_VERTEX/NORMAL/TEX_UV/INDEX` | 构造并逐帧刷新程序化可变形网格 |
| `MeshInstance3D`、`StandardMaterial3D` | 渲染形变网格和舞台材质 |
| `CanvasLayer`、`Control`、`HSlider`、`Button` | 创建跟随视口的 HUD、力度控制和复位按钮 |

### 参数调节

在 `blob_deformer.gd` 中可调：`spring_stiffness` 控制回弹速度，`spring_damping` 控制振荡衰减，`neighbor_stiffness` 控制表面平滑，`press_depth` 控制按压深度，`pull_limit` 限制拉伸位移，`latitude_segments` 与 `longitude_segments` 控制网格精度。提高网格精度会增加每帧法线重算和网格重建的成本，Web 端应先在目标设备上测量。

若需要更可信的体积保持、复杂材料和多点接触，下一阶段可在 GPU shader 中实现位移，或改用经过验证的软体物理方案；此时也应让拾取碰撞体随实际形状更新。目前碰撞球保持静止，因此这是用于可玩原型的视觉形变，而不是可与场景中其他刚体精确碰撞的实体软体。
