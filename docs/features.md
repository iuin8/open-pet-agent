# 功能说明 (Features)

> 这份文档记录**当前主线上已经能跑的功能**。计划中、还没落地的功能不在这里。

OpenPetAgent 是一个 macOS 原生桌面 AI 物理沙盒桌宠：纯原生 AppKit 壳层 + Metal 渲染 / GPU compute（雪/雨高频物理）+ Swift pet 运动 runtime（Rust 已 2026-06-06 退役）。

## 🪟 桌面壳层（三窗口模型）

详见 [architecture.md §2 总体分层](architecture.md)。

- **Overlay**：全屏透明 `NSWindow`，点击穿透，承载 `MetalSnowOverlayView`（雪粒子层 + `DesktopOverlayView` NSTextField 占位 fallback）
- **Pet**：桌宠球本体的 `NSPanel`（`PetShellWindow`），可拖拽、可右键
- **Chat**：附着在桌宠旁的聊天浮层（`ChatShellView`）

跨 Space 自动跟随；wallpaper 全屏窗口自动从碰撞集中过滤；前到后 z-order 感知遮挡（详见 [architecture.md §6 已知陷阱](architecture.md)）。

## 🧊 物理引擎

**唯一路径 = GPU falling-sand**（详见 [architecture.md §4](architecture.md)）：

| 维度 | 实现 |
|------|------|
| **雪/雨物理** | Metal compute（`fs_*` kernel：粒子积分 + 沉积 + 三 pass 无锁 CA + 相变 + 升华 + 窗口遮挡），全在 GPU 显存 / `MTLBuffer` |
| **pet 运动** | 纯 Swift `LocalRuntimeClient`（朝光标追踪 + contact_count；Rust runtime 已 2026-06-06 退役） |

共用能力：

- **遮挡感知 settle**：粒子只停在视觉上没被前面窗口盖住的窗口顶（z-order scan + per-column visibility）
- **跨坐标系翻转**：CGWindow top-origin ↔ Runtime bottom-origin 自动翻转

**当前差距**：还没达到 Noita 级硬标准（详见项目设计标准）。缺：像素级窗口碰撞、堆积层（falling-sand CA）、风场/温度场消费。

## 🖱️ 桌面感知（Context）

| 组件 | 作用 |
|------|------|
| `DisplayTracker` | 屏幕分辨率与位置 |
| `WindowTracker` | 可见窗口列表（CGWindowList + 100ms TTL 缓存，对抗关窗事件不可靠） |
| `SpaceTracker` | 当前 Space ID 与切换事件 |
| `AXFrontmostWindowObserver` | 前景窗口的 AX 树（需要 Accessibility 权限） |
| `DesktopSnapshotSampler` | 每帧统一采样上述信号 → `DesktopSnapshot` |

## 🎯 桌宠行为

- **拖拽**：`PetWindowDragAdapter` 监听 `NSWindowDelegate` 拖动事件；释放后桌宠回到 runtime 物理控制
- **跟随光标**：菜单栏 ❄ 可勾选「跟随光标」开关。frame loop 在开关开启时每帧把桌宠位置同步到光标。**默认关闭**——确保用户能右键到桌宠（[architecture.md §6.6](architecture.md)）

## 🍎 菜单栏

`MenuBarController` 在系统状态栏挂 ❄ 图标，菜单项：

- 跟随光标开关（默认关闭）
- 启停雪
- 退出

## 💬 AI 助理

LLM chat 闭环已通：OpenAI/Anthropic SSE 流式 + 对话持久化（rolling-window token 预算）+
桌面上下文注入（前台 app + **窗口标题列表** + 光标九宫格，感知加深·标题层 2026-06-04）+
工具模式（`claude -p` / `codex exec` 子进程）。入口：QuickAsk Spotlight 浮窗（⌥Space）+
pet 头顶 Bonded 气泡。设置 → 后端 填 API key（热重载，无需重启）。架构见
[architecture.md §3](architecture.md)。

## 🎨 渲染细节

- Metal point sprite 软边圆：fragment shader 用 `[[point_coord]]` 做径向 alpha falloff
- 透明 `CAMetalLayer`（`isOpaque = false`，避免变黑）
- `MetalSnowOverlayView` 驱动 `FallingSandDriver`（唯一雪路径，GPU falling-sand）
