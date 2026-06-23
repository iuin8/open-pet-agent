# 开发指南 (Development Guide)

> 当前架构总览在 [architecture.md](architecture.md)。本文档只描述构建、运行、测试、调试的操作步骤。

## 克隆与首次配置

```bash
# 必须带 --recurse-submodules —— Vivarium 引擎是子模块
git clone --recurse-submodules https://github.com/iuin8/open-pet-agent.git
```

⚠️ **`--recurse-submodules` 是强制的**。Vivarium 物理/渲染/行为引擎挂在子模块
`Packages/Vivarium`(→ `github.com/iuin8/pet-agent-vivarium`)。普通 `git clone`
会留下空的 `Packages/Vivarium`,`swift build` 直接失败。已 clone 漏了子模块的话补:
`git submodule update --init --recursive`。

**Live2D 可选,不影响主流程**:Live2D Cubism 形象后端需要自备 Cubism SDK(专有许可,
不入库),跑 `scripts/setup-cubism.sh` 用你自己下的官方 SDK 安装到 `Vendor/Cubism/`。
没装 Cubism 时 clone 照常 `swift build && swift run`、桌宠/物理/AI 全功能可用,只是
Live2D 形象渲染为占位、`Live2DTests` 不参与编译(见下方测试章节)。

## 构建与运行

### 日常推荐: 一键 build + 签名 + 装 + 启动

```bash
./install.sh
```

内部跑 `./build.sh`(`swift build -c release --arch arm64`(Apple Silicon only) →
手工组装 `OpenPetAgent.app` bundle → Apple Development 证书签名,无证书则 ad-hoc
回退), 然后覆盖装到 `/Applications/OpenPetAgent.app` 并启动。**TCC 权限稳定**
(Accessibility / 截屏 / 位置 / Apple Events 不会因为重 install 丢失)。

详细签名 / 证书配置 / 故障排查见 [signing-and-install.md](signing-and-install.md)。

### 临时验证 / debug

```bash
# 构建(约 2 秒, debug)
swift build

# 启动 app(不阻塞终端)
open .build/debug/OpenPetAgent

# 或直接运行(阻塞终端,日志输出到 stdout)
swift run
```

⚠️ debug binary 是 unsigned 或 ad-hoc 签名 → 每次 build CDHash 变 → TCC 把
每次启动当成新 app → **Accessibility 权限会重弹**。仅适合短时调试。

**要求**: macOS 15+(会话流用 scrollPosition/onScrollGeometryChange/defaultScrollAnchor 原生 scroll API),Swift 5.9+,Xcode(含免费 Apple Development 证书,5
分钟配置)。

**辅助功能权限**: OpenPetAgent 需要 AX 权限才能监听前景窗口
(`AXFrontmostWindowObserver`)与做遮挡感知(`WindowTracker`)。
系统设置 → 隐私与安全性 → 辅助功能 → 添加 OpenPetAgent.app(走 `./install.sh`
路径授权一次即永久稳定)。

## pet 运动 runtime（纯 Swift）

> **2026-06-06 起无 Rust**：原 Rust crate `weather_motion_runtime` 已退役,pet 运动逻辑(追光标 + contact_count)移植进 `Packages/Vivarium/Sources/RuntimeBridge/LocalRuntimeClient.swift`。`swift build` 一条命令全量构建,**无需 cargo 预构建、无 FFI 链接陷阱**。雪/雨物理在 Metal GPU compute,统一 FallingSand 引擎(`Packages/Vivarium/Sources/SandboxPhysics/FallingSand/`,雪雨同源)。

## 测试

### Swift 层（壳层、桥接、窗口跟踪、渲染装配）

```bash
swift test --parallel                              # 根包(Shell/App/Orchestrator/ToolMode/Weather/AgentSensing/Shimeji/Live2D…)
swift test --parallel --package-path Packages/Vivarium   # Vivarium 子包(Context/RuntimeBridge/SandboxPhysics/Rendering/ShimejiImport/PetCatalog/PetBehavior)
```

> **测试分两包(2026-06-09 P3 后)**：桌宠引擎簇迁入 `Packages/Vivarium` 子包后,`swift test` 按包跑。**全套 = 两条命令都绿**(具体测试数随提交增长,以 `swift test list` 为准);只跑根包会漏掉 Vivarium 测试、误判全绿。

测试模块：根包 `AppTests` / `ShellTests` / `OrchestratorTests` / `ToolModeTests` / `WeatherTests` / `AgentSensingTests` / `ShimejiTests`(+ `Live2DTests`,**仅当 `Vendor/Cubism` 存在**;Cubism SDK 经 `scripts/setup-cubism.sh` 自装,新 clone 不带 SDK 照常 build/run、无 Live2D 形象、`Live2DTests` 也不存在);Vivarium 子包 `ContextTests` / `RuntimeBridgeTests` / `SandboxPhysicsTests` / `RenderingTests` / `ShimejiImportTests` / `PetCatalogTests` / `PetBehaviorTests`。

> `--parallel` 让一个包内的多个 test target 跨进程并发执行（默认 SwiftPM CLI 是 `--no-parallel`，只在 Swift Testing framework 内 parallel，不跨 target）。target 数是**按包计**：根包约 8 个(含 `AgentSensingTests`、`Live2DTests` 视 Cubism 而定)、Vivarium 约 7 个(含 `SandboxPhysicsTests`)，`--parallel` 在各自那条命令内生效，不跨包。

### 关键回归测试（不要让它们挂）

| 回归名 | 防护什么 |
|--------|---------|
| `clearsOccludedSnow`(Vivarium `SandboxPhysicsTests/FallingSandGPUPhaseTests`) | 逐格矩形遮挡：落在任意窗口矩形内的格子每帧被清除（2D 遮挡，无 z-order） |
| `runtimeBridgeFlipsTopOriginWindowBoundsIntoBottomOriginCollisionRects` | CGWindow 顶为 y=0 vs Runtime 底为 y=0 的坐标翻转 |
| `desktopOverlayViewHidesNSTextFieldSnowflakesWhenMetalLayerIsActive`(`ShellTests/DesktopShellControllerTests`) | Metal 层激活后旧 NSTextField 雪花被隐藏，叠加层走 Metal 透明渲染 |
| `minimalAppDelegateDefaultFrameLoopTicksWithoutRunLoopModeDependence` | 主线程 frame loop 与 `NSApplication.run()` 兼容性 |
| `windowTrackerRefreshesVisibleWindowsAfterCacheLifetimeExpires` | 关窗事件不可靠时 100ms TTL 强制重读 |

陷阱与对应回归的完整清单见 [architecture.md §6 已知陷阱与设计教训](architecture.md)。

### 桌宠渲染器形象与测试位置

OpenPetAgent 是**可插拔多桌宠平台**：`PetRenderer` 协议 + `PetPluginRegistry`，
`DesktopShellController.replacePetRenderer` 运行时热切换。弹力球只是默认皮肤。
五种已工作的形象格式与其测试归属:

| 形象格式 | 渲染器 | 测试 |
|---------|--------|------|
| Orb SDF（默认） | `OrbMetalRenderer` | `RenderingTests`(Vivarium) |
| Slime SDF | `SlimeMetalRenderer` | `RenderingTests`(Vivarium) |
| Codex·petdex sprite 图集（8×9 + `pet.json`） | `SpriteSheetPetRenderer` + `CodexSpritePackLoader` | `RenderingTests`(Vivarium) |
| Shimeji | `ShimejiPetRenderer` + 行为引擎 | `ShimejiTests`(根) + `ShimejiImportTests`(Vivarium) |
| Live2D Cubism | `Live2DPetRenderer` | `Live2DTests`(根,**仅当 Cubism SDK 存在**) |

桌宠库 / 目录 / 行为另有 `PetCatalogTests`、`PetBehaviorTests`(均 Vivarium)。

## 调试技巧

### Metal compute / 渲染 debug

- Xcode → Open Developer Tool → Metal Debugger，attach 到 `OpenPetAgent` 进程
- `FallingSandDriver.tick` 一次完整 frame 的 compute dispatch（`FallingSandGPUEngine`）+ render pass 可以单帧 capture
- Metal overlay 出黑屏：检查 `MTKView.layer?.isOpaque = false` 且 `(layer as? CAMetalLayer)?.isOpaque = false`（粒子用 instanced quad billboard，macOS 上 `point_size` 被钳到 1，没有 point sprite）（[architecture.md §6.4](architecture.md)）
- 粒子位置看起来错位：检查 viewport 用 `bounds.size` 还是 `drawableSize`（[architecture.md §6.5](architecture.md)）

### 物理悬浮 / 不掉雪问题

- **雪堆积/遮挡**：检查 GPU compute kernel 是否收到正确的 `collision_rects` 与 `is_snow_enabled` intent；`CollisionRect.collection` 的 z-order 前到后传入 + 坐标 top→bottom 翻转是否正确；用 Metal Debugger 看 compute buffer 输入

### 动态效果录制验证（spring / halo / 任何 SwiftUI 进场动画）

录进场动画用 **app 维度干净录制**：`scripts/record-app-windows.py`（`CGWindowListCreateImageFromArray` **只合成本 app 指定窗口**，背后终端/桌面全部排除）。比全屏/单窗截图强在三点：

1. **干净** —— 只录卡片，没有终端/桌面杂物入画；
2. **快** —— 只编码卡片大小（非 Retina 全屏 ~200ms/帧），合成 2 个卡片窗 ~15fps；
3. **可读** —— 这种合成 PNG **Claude Read 读得了，能逐帧自评动画**。

```bash
pkill -f "MacOS/OpenPetAgent"; sleep 1
/Applications/OpenPetAgent.app/Contents/MacOS/OpenPetAgent >/dev/null 2>&1 &
/usr/bin/python3 scripts/record-app-windows.py --frames 70 --out /tmp/frames \
    --wait 500-540 --match 500-540 --match 340-380   # 等卡片(w≈520)出现再抓;合成侧卡+主卡(w≈360)
ffmpeg -y -framerate "$(cat /tmp/frames/fps.txt)" -i /tmp/frames/f%03d.png \
    -vf "scale=760:-2,format=yuv420p" -pix_fmt yuv420p ~/Desktop/anim.mp4
```

**坑（都踩过）**：

- **透明 NSPanel 别按单窗 ID 截** —— 侧宽卡 / overlay 是透明面板，`CGWindowListCreateImage(…IncludingWindow, id)` 会**穿透**抓到背后窗口（看着像 Read 坏了，其实是抓错了）。必须用 `…CreateImageFromArray([ids])` 合成，或全屏区域截（composited）。
- **全屏区域截能抓到透明卡但慢**（~5fps），抓不流畅 spring → 用 array 合成法。
- **ffmpeg `scale=W:-2` 不是 `-1`** —— 奇数高度 yuv420p 会 `Conversion failed!`。
- **用 `fps.txt` 真实帧率喂 ffmpeg** —— 脚本抓帧是「尽快抓」非定频，回放才真实速度。
- 需「屏幕录制」TCC 权限给调用方进程;`/usr/bin/python3`(系统自带 PyObjC)有 Quartz,`/opt/homebrew` 的没有。

## 已知问题

- **Xcode license** 可能挡构建：`sudo xcodebuild -license`
- **单元测试不覆盖 GPU compute kernel**：只能靠 Metal Debugger 或者人眼观察（物理效果需自己截屏验证）

## 性能目标

性能目标见项目文档。
