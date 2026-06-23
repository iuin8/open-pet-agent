# 开发指南 (Development Guide)

> 当前架构总览在 [architecture.md](architecture.md)。本文档只描述构建、运行、测试、调试的操作步骤。

## 构建与运行

### 日常推荐: 一键 build + 签名 + 装 + 启动

```bash
./install.sh
```

内部跑 `./build.sh`(`swift build -c release` → 打 `OpenPetAgent.app` bundle →
Apple Development 证书签名), 然后覆盖装到 `/Applications/OpenPetAgent.app` 并启
动。**TCC 权限稳定**(Accessibility / 截屏 / 位置不会因为重 install 丢失)。

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
swift test --parallel                              # 根包:1215 测试(Shell/App/Orchestrator/ToolMode/Weather/Shimeji/Live2D/AgentSensing…)
swift test --parallel --package-path Packages/Vivarium   # Vivarium 子包:356 测试(Context/RuntimeBridge/Rendering/ShimejiImport/PetCatalog/PetBehavior)
```

> **测试分两包(2026-06-09 P3 后)**：桌宠引擎簇迁入 `Packages/Vivarium` 子包后,`swift test` 按包跑。**全套 = 两条命令都绿**(2026-06-14 实测 1215+356=1571,会随提交增长 —— 数字以 `swift test list` 为准);只跑根包会漏掉 Vivarium 测试、误判全绿。

测试模块：根包 `AppTests` / `ShellTests` / `OrchestratorTests` / `ToolModeTests` / `WeatherTests` / `ShimejiTests`(+ `Live2DTests`);Vivarium 子包 `ContextTests` / `RuntimeBridgeTests` / `RenderingTests` / `ShimejiImportTests` / `PetCatalogTests` / `PetBehaviorTests`。

> `--parallel` 让 8 个 test target 跨进程并发执行（默认 SwiftPM CLI 是 `--no-parallel`，只在 Swift Testing framework 内 parallel，不跨 target）。实测在本仓库可把全套从 ~46s 压到 ~40s。

### 关键回归测试（不要让它们挂）

| 回归名 | 防护什么 |
|--------|---------|
| `snowflakes_do_not_settle_when_back_window_top_is_occluded_by_front_window` | 上层窗口遮挡时下层 top 不应该接住雪 |
| `runtimeBridgeFlipsTopOriginWindowBoundsIntoBottomOriginCollisionRects` | CGWindow 顶为 y=0 vs Runtime 底为 y=0 的坐标翻转 |
| `metalSnowOverlayViewUsesTransparentMetalLayer` | `CAMetalLayer.isOpaque = false`，否则透明叠加层变黑 |
| `minimalAppDelegateDefaultFrameLoopTicksWithoutRunLoopModeDependence` | 主线程 frame loop 与 `NSApplication.run()` 兼容性 |
| `windowTrackerRefreshesVisibleWindowsAfterCacheLifetimeExpires` | 关窗事件不可靠时 100ms TTL 强制重读 |

陷阱与对应回归的完整清单见 [architecture.md §6 已知陷阱与设计教训](architecture.md)。

## 调试技巧

### Metal compute / 渲染 debug

- Xcode → Open Developer Tool → Metal Debugger，attach 到 `OpenPetAgent` 进程
- `FallingSandDriver.tick` 一次完整 frame 的 compute dispatch（`FallingSandGPUEngine`）+ render pass 可以单帧 capture
- `[[point_coord]]` fragment shader 出黑屏：检查 `MTKView.layer?.isOpaque = false`（[architecture.md §6.4](architecture.md)）
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
