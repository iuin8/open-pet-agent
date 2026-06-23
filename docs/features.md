# 功能说明 (Features)

> 这份文档记录**当前主线上已经能跑的功能**。计划中、还没落地的功能不在这里。

OpenPetAgent 是一个 macOS 原生桌面 AI 桌宠**平台**：纯原生 AppKit 壳层 + Metal 渲染 / GPU compute（雪/雨高频物理）+ Swift pet 运动 runtime（Rust 已于 2026-06-06 退役）。它不是单一形象的桌宠，而是一个 `PetRenderer` 协议之上的**可换装多形象平台**——默认是一颗弹力球，可换成 Slime / Codex·petdex 精灵 / Shimeji / Live2D。

## 🧩 可换装桌宠平台（多形象）

核心是 `PetRenderer` 协议（`Packages/Vivarium/Sources/Rendering/PetRenderer.swift`）+ `PetPluginRegistry`（编译期类型插件 Orb/Slime + 运行时从磁盘发现的值条目）；`DesktopShellController.replacePetRenderer` 运行时热切换形象。**已落地五种形象**：

| 形象 | 渲染器 | 状态 |
|------|--------|------|
| Orb 弹力球（默认） | `OrbMetalRenderer`（Metal SDF + Fresnel metaball + 速度 squash + 5 态情绪） | ✅ |
| Slime 史莱姆 | `SlimeMetalRenderer`（独立情绪映射 + 招牌动作） | ✅ |
| Codex / petdex 精灵 | `SpriteSheetPetRenderer` + `CodexSpritePackLoader`（8×9 spritesheet + `pet.json`） | ✅ |
| Shimeji 看板娘 | `ShimejiPetRenderer` + 行为图引擎（走/落/坐/爬墙、抓起甩出、多宠拥抱） | ✅ |
| Live2D 模型 | `Live2DPetRenderer`（Cubism Metal，待机/呼吸/眨眼/物理 + 情绪驱动动作） | ✅（需自备 Cubism SDK） |

诚实边界：Shimeji 不消费 chat 情绪态（其行为由 `behaviors.xml` 驱动，按设计为 no-op）；Live2D 暂不做假口型（接 TTS 音频后再驱动 `ParamMouthOpenY`）；无 Cubism SDK 时仍能安装/显示 Live2D 包，但渲染为占位（`Live2DModelPackLoader.rendererFactory` 为 nil）。

## 🛒 桌宠库与社区生态

- **桌宠库 GUI**：设置 → *管理桌宠库…* 打开 `PetLibraryView`（无模态浮层）——分类标签（内置 / Codex 社区 / Shimeji 导入 / Live2D）、缩略图网格、即时切换、删除确认、搜索。
- **社区一键获取**：*获取社区桌宠…* → `CommunityPetsSheet` → `PetCatalogClient`（petdex `api/manifest`）→ `PetPackInstaller` 下载安装，含 Codex / Shimeji 分页。
- **导入**：拖 Shimeji `.zip`/文件夹或点「导入 Shimeji」→ `ShimejiPackConverter` → 装到 `~/.petagent/pets/shimeji/`；Live2D 同理拖 `.model3.json` 包；命令行另有 `shimeji-convert`（`ShimejiConvert` 产品）。
- **自动发现**：启动时扫描 `~/.petagent/pets/codex/` 与 `~/.codex/pets/`，发现 petdex 包即注册——兼容现有 Codex/petdex 生态。
- **多宠同屏**：任一 Shimeji 可作为「装饰伙伴」与主宠同屏漫步（`MinimalAppDelegate+DecorativePets.swift`），支持整包批量开关。
- **每宠缩放**：0.5×–2.0×（`petScale`），对所有渲染器类型生效。
- **安全安装**：可信主机白名单（防 SSRF）+ 防盗链 Referer + 429/5xx 退避 + slug/sheet 名路径穿越净化；`removePack` 限制在库子目录内。

## 🪟 桌面壳层（三窗口模型）

详见 [architecture.md §2 总体分层](architecture.md)。

- **Overlay**：全屏透明 `NSWindow`，点击穿透，承载 `MetalSnowOverlayView`（雪粒子层）。
- **Pet**：桌宠本体 `PetShellWindow`（borderless `NSWindow`），可拖拽、可右键。
- **Chat**：锚定在桌宠旁的对话卡片 `ChatCardWindowController`。（工厂里那块旧的侧贴聊天面板 `ChatBubblePanel`/`ChatShellView` 已弃用、不再显示。）

跨 Space 自动跟随；wallpaper 全屏窗口自动从碰撞集中过滤；CGWindowList 前到后 z-order 端到端保留并喂给 GPU 雪遮挡（详见 [architecture.md §6 已知陷阱](architecture.md)）。

## 🧊 物理引擎

**唯一路径 = GPU falling-sand**（详见 [architecture.md §4](architecture.md)）：

| 维度 | 实现 |
|------|------|
| **雪/雨物理** | Metal compute（`fs_*` kernel：亚像素粒子积分 + 沉积 + 三 pass 无锁 CA + 相变 + 升华 + 矩形遮挡），数据驻留共享 `MTLBuffer`（`storageModeShared`，少量初始化/读回走 CPU） |
| **pet 运动** | 纯 Swift `LocalRuntimeClient`（朝光标追踪 + contact_count；Rust runtime 已 2026-06-06 退役） |

共用能力：

- **遮挡感知 settle**：雪堆在窗口顶部与桌宠真实 alpha 轮廓上（`fs_rasterize_pet`）；悬浮窗下方开阔地照常落雪；窗口移动/关闭/切 Space 时逐帧重新评估（`fs_clear_occluded`）。**当前为逐格矩形遮挡**——被前景窗口盖住的后方窗口顶仍会落雪，暂不做前后 z-order 可见性判定（驱动里显式注释「无需 z-order」）。
- **相变与温度**：snow↔water↔ice↔steam 相变（`fs_apply_phase`）+ 升华深度反馈（自限稳态雪深 ~√(S/k)）+ 逐列硬上限（`maxColumnDepth=24`）；温度来自实时 Open-Meteo °C → 归一 ambient → 相变 kernel。
- **跨坐标系翻转**：CGWindow top-origin ↔ Runtime bottom-origin 自动翻转。

**当前差距**（距项目自设的 Noita 级硬标准）：(a) 窗口遮挡仍是 sharp-corner 矩形近似——未识别 macOS 圆角、无 z-order、非逐像素轮廓（分阶段提升路线见 [architecture.md §7](architecture.md)）；(b) CA 栅格风场未接（`engine.windX` 恒为 0，仅 particle 级 `windStrength` 生效）；(c) 天气风速取了但未动态驱动（恒定轻风）；(d) 温度场仅均匀填充，无热源/热扩散。

## 🖱️ 桌面感知（Context）

| 组件 | 作用 |
|------|------|
| `DisplayTracker` | 屏幕分辨率与位置 |
| `WindowTracker` | 可见窗口列表（CGWindowList + 100ms TTL 缓存 + 事件硬失效，对抗关窗事件不可靠） |
| `SpaceTracker` | Space 标识与切换事件（合成 `space-{kCGWindowWorkspace}` 串，由前景窗口推导，非真 CGSSpaceID） |
| `AXFrontmostWindowObserver` | 前景窗口的 AX 树（需要 Accessibility 权限） |
| `DesktopSnapshotSampler` | 每帧统一采样上述信号 → `DesktopSnapshot`（光标位置与前台 app 名每帧实采，window/display/space 走 TTL + 事件） |

## 🛰️ 外部 Agent 感知（AgentSensing）

只读 tail Claude Code（`~/.claude/projects/**/*.jsonl`，递归）与 Codex（`$CODEX_HOME` 或 `~/.codex/sessions/**/rollout-*.jsonl`，递归）的会话日志——`FileTailer` 首见即 seek 到文件尾，只读新追加字节、从不回放历史——把会话活动映射成桌宠情绪态（写代码→工作、读文件→审阅、报错→沮丧、等输入→等待、完成→庆祝）。**默认开启，纯文件读取**：不注册 hook、不改 `settings.json`、不起常驻服务，与其它 hook 工具零冲突。含静默 idle 合成（Claude 日志无 Stop 标记）与工具进行中保护（长 build/test 不误判 idle）。

> 注：同一 `AgentSensing` target 里另有一个**默认关闭**的「在卡片上回答权限」功能（`PermissionHookServer` + `HookInstaller`），它会起本地回环 HTTP 服务并把 OpenPetAgent 自己的 hook 写进 `~/.claude/settings.json`——与上述只读感知是两个相互独立的特性，不要混淆。

## 🎯 桌宠行为

- **拖拽**：`PetWindowDragAdapter` 监听 `NSWindowDelegate` 拖动事件；释放后桌宠回到 runtime 物理控制。
- **跟随光标**：菜单栏 ❄ 可勾选「跟随光标」开关。frame loop 在开关开启时每帧把桌宠位置同步到光标。**默认关闭**——确保用户能右键到桌宠（[architecture.md §6.6](architecture.md)）。

## 🍎 菜单栏

`MenuBarController` 在系统状态栏挂 ❄ 图标，菜单项：跟随光标、桌面漫游、感知编码会话（Claude Code / Codex）、在卡片上回答权限 / 问题、交互时冻结 pet、打开聊天浮窗、截图分享、设置…、**天气子菜单**（关闭天气效果 / 自动 / 强制 sunny·cloudy·rainy·snowy·windy + 立即清除积雪）、退出 OpenPetAgent。

## 💬 AI 助理

LLM chat 闭环已通：

- **双 provider**：`OpenAIProvider`（Bearer，`/chat/completions`）+ `AnthropicProvider`（x-api-key，Messages API），设置里运行时切换、**下一条消息即生效无需重启**（actor `LLMProviderBox`）。OpenAI 兼容端点（DeepSeek / Groq / Ollama）改 base URL 即可达。
- **无第三方依赖的流式 SSE**：手写在 `URLSession.bytes` 上，`Data` 缓冲按事件切分，跨 HTTP 分块保住多字节 UTF-8。
- **桌面上下文注入**：前台 app + 可见窗口属主与标题（按 z-order、限额预算）+ 光标九宫格 + 时间/显示器；OpenPetAgent 自身按 PID 与名字过滤两遍。
- **工具模式**：`claude -p`（stream-json）/ `codex exec`（json）子进程，带看门狗超时、取消即 SIGTERM、`SubprocessRegistry` 清理。
- **对话持久化**：`ConversationStore` actor 原子写 + `.bak` 恢复 + 滚动窗口 token 预算（不拆散一问一答）+ 90s idle 看门狗。
- 入口：⌥Space 召唤锚定在桌宠旁的多轮对话卡片（`ChatCardWindowController`）；⌘⇧Space 带选中文本快问、预填到同一张卡片；pet 头顶 Bonded 气泡。设置 → 后端 填 API key（热重载）。架构见 [architecture.md §3](architecture.md)。

## 🎨 渲染细节

- 雪粒子用 instanced quad billboard（macOS `point_size` 可能被钳到 1）；fragment 做径向 alpha falloff 软边。
- 透明 `CAMetalLayer`（`isOpaque = false`，避免变黑）。
- `MetalSnowOverlayView` 驱动 `FallingSandDriver`（唯一雪路径，GPU falling-sand）。
