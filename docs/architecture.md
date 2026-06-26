# OpenPetAgent 架构

> 这份文档描述代码当前事实和长期设计原则。

## 1. 产品定位

OpenPetAgent 是一个建立在**可插拔 PetRenderer 平台**之上的 macOS 桌面 AI 伴侣，不是单一一颗弹力球：

- 默认皮肤 = Metal-SDF 弹力球（Orb），但它只是**五种工作形象之一**，不是产品本身
- 五种已落地形象（运行时可热切换）：Orb SDF / Slime SDF / Codex·petdex sprite 表 / Shimeji 行为引擎 / Live2D Cubism——经 `PetRenderer` 协议 + `PetPluginRegistry` 注册，`DesktopShellController.replacePetRenderer` 运行时热换，应用内桌宠库 GUI（设置 →「管理桌宠库…」→ `PetLibraryView`，「获取社区桌宠…」→ `CommunityPetsSheet`）切换/导入/在线安装/同屏
- 与桌面窗口交互、能造雪/雨、能聊天，并能感知外部编码会话；长期目标是从「桌宠」演进为「macOS 桌面级全能个人助理」
- 核心难点是系统集成（透明 overlay、点击穿透、跨 Space、TCC 权限），不是场景编辑器

> 第 3 节模块清单印证此定位：Rendering 层同时承载抽象 SDF 形象、社区 sprite、Shimeji 引擎、Live2D 四类后端；弹力球只是默认皮肤。

因此长期架构选择 **「原生 macOS 壳层 + 游戏化运行时」**，不走纯 Godot 也不走纯原生：

| 候选 | 优势 | 劣势 |
|---|---|---|
| 纯原生 macOS | 系统集成顺手 | 高频粒子/物理写在 Swift 难维持 60 fps |
| 纯 Godot | 物理与渲染原生 | 透明覆盖层、点击穿透、跨 Space、TCC 等都和 NSWindow 模型相反 |
| **原生壳层 + GPU 物理** | 各取所长：AppKit 系统集成 + Metal compute 跑高频物理 | 需要严格守住边界，不让渲染/物理反向接管生命周期（Rust runtime 已于 2026-06-06 退役，pet 运动纯 Swift） |

## 2. 总体分层

```text
+==============================================================+
|                      Native Shell (AppKit)                   |
| OpenPetAgentApp | MinimalAppDelegate | DesktopShellController  |
| OverlayWindow | PetShellWindow | ChatShellView               |
| MenuBarController | AccessibilityBridge                      |
+-------------------------------+------------------------------+
                                |
                                v
+==============================================================+
|                   Desktop Context (Swift)                    |
| DisplayTracker | WindowTracker (TTL cached)                  |
| SpaceTracker  | AXFrontmostWindowObserver                    |
| ActiveSpaceIdentifierProvider | VisibleWindowsProvider       |
| DesktopSnapshotSampler → DesktopSnapshot                     |
+-------------------------------+------------------------------+
                                |
                                v
+==============================================================+
|              Companion Orchestrator (Swift)                  |
| CompanionOrchestrator | PresentationMapper | BehaviorEngine  |
| ConversationResponder | RuntimeTicker                        |
+-------------------------------+------------------------------+
                                |
                                v
+==============================================================+
|              Runtime Bridge (纯 Swift, 无 Rust/FFI)          |
| RuntimeBridgeService | LocalRuntimeClient | NoOpRuntimeClient |
|   step(input) → output:                                      |
|     pet 朝光标恒速追踪(160px/s) + contact_count              |
|   (Rust weather_motion_runtime 已于 2026-06-06 退役,         |
|    ~40 行弹力球物理移植进 LocalRuntimeClient)                 |
+-------------------------------+------------------------------+
                                |
                                v
+==============================================================+
|                Rendering (Swift + Metal)                     |
| MetalSnowOverlayView (MTKView, FS-only host)                 |
|  → FallingSandDriver.tick (encodeFrame)                      |
|     ├─ FallingSandParticles (飞行雪 = GPU 浮点粒子)          |
|     └─ FallingSandGPUEngine (落地积雪 = cell-CA, 双缓冲)     |
| DesktopOverlayView (overlay 宿主, FS-only)                   |
+==============================================================+
```

**falling-sand 是唯一雪路径**（旧 GPU 粒子雪 / Rust-runtime fallback 雪已于 2026-06-02 移除）。雪 = 飞行浮点粒子（亚像素丝滑）+ 落地 cell-CA（堆积/相变/升华平衡）。Rust runtime 只算 pet pose + contact_count，不再回传 particle buffer（`wantsParticles = false`）。雨也走 FS（spawnRain → water 粒子 → 水洼，温度耦合冷天冻冰），与雪同引擎；旧独立 `GPURainCoordinator`（Phase B splash/wetness）已于 2026-06-12 **删除**（overlay 早已永久隐藏、不参与渲染，视觉已 port 到 FS 雨；连同 `MetalRainRenderer` + Shell/App 接线一并清理）；其三个视觉（splash 水花 / 随风斜 / 湿亮 sheen）已于 2026-06-03 以 FS 真物理方式 port 到 FS 雨（splash=弹道 `kind=2` 水花、风斜=有向 lean + streak 沿 velocity 定向、sheen=water cell 湿亮反光）。

## 3. 当前模块清单

> **桌宠引擎簇已抽成独立开源仓库 [`pet-agent-vivarium`](https://github.com/iuin8/pet-agent-vivarium)(Apache-2.0,2026-06-12),由父仓以 git submodule 挂在 `Packages/Vivarium`**(前身为 2026-06-09 P3 的同仓 local 子包;见 `Packages/Vivarium/README.md`)：`Context`、`RuntimeBridge`、`SandboxPhysics`(GPU 物理沙盒,2026-06-12 从 Rendering 分出,deps[])、`Rendering`、`ShimejiImport`、`PetCatalog`、`PetBehavior`(P4,2026-06-10 新增) 七个 target 现位于 `Packages/Vivarium/Sources/<X>`(下表写 `Sources/<X>` 处实为此),根包 App/Shell/Orchestrator 仍经 `.product(name:,package:"Vivarium")` 本地路径依赖(submodule 路径不变,`.package(path:)` 无需改;`PetBehavior` 待 S3 接线后被 Shell 消费);它们的测试同在 `Packages/Vivarium/Tests/`(根 `swift test` 不跑,需 `swift test --package-path Packages/Vivarium`)。**克隆父仓需 `git submodule update --init` 拉取引擎内容。** Live2D 簇因 Cubism `Vendor/` 留根、跨包依赖 Vivarium.Rendering。

| 模块 | 入口文件 | 主要职责 | 状态 |
|---|---|---|---|
| **App** | `Sources/App/PetAgentApp.swift`, `AppMainMenu.swift`, `MinimalAppDelegate.swift` (+ `+Launch` / `+RuntimeFrame` / `+Settings` / `+ChatCard` / `+ToolEngine` / `+PetBehavior` / `+ProactiveWiring` / `+DecorativePets` / `+AgentSensingWiring` / `+PermissionWiring` 十个 extension 文件), `IdleSleepingFanout.swift`, `CoreLocationCoordinateAdapter.swift`, `ScreenAwakeController.swift`, `ScreenAwakeMode.swift`, `LidCloseSleepDisabler.swift`, `PowerStateMonitor.swift`, `LaunchAtLoginManager.swift` | 同步 `@main` 入口、生命周期、frame loop、菜单栏跟随开关 gate、**开机自启**（`LaunchAtLoginManager`：协议 + `SMAppService.mainApp` 实现，`register()/unregister()`，`status` 为权威源**无 UD**；设置→系统 tab toggle，`requiresApproval` 时引导去系统设置登录项，2026-06-25）、**防休眠四态**（`ScreenAwakeController` 编排 `ScreenAwakeMode`：`displayAwake`→`ProcessInfo .idleDisplaySleepDisabled`（屏幕常亮）/ `systemAwake`→`.idleSystemSleepDisabled`（屏幕可息屏但系统不睡、网络保持，挂机跑 Claude）/ `lidClosedAwake`→全局 `pmset disablesleep`（经 `LidCloseSleepDisabler` 的 osascript 提权，**合盖也不睡、无需外接屏**）/ `off`。**lidClosedAwake 安全模型**：风险确认 alert + 仅接电源维持（`PowerStateMonitor` 拔电自动关）+ 低电量自动关 + 定时自动关（默认 8h）+ 退出/切换提权复位 + 启动 `selfHeal` 强制复位残留 + 不跨重启持久（会话级）。设置→系统 tab Picker/Picker/Toggle 即时生效 + UD `screenAwakeMode`/`screenAwakeAutoOff`/`screenAwakeDisableOnLowPower` 持久化；旧布尔 key `keepScreenAwake`→`displayAwake` 一次性迁移。2026-06-25）、**全局编辑菜单**（`AppMainMenu.swift`：accessory app 必须手动 install `NSApp.mainMenu` 的标准 Edit 菜单项 ⌘C/V/X/A/Z，才能路由全局快捷键，2026-06-24）、**主动协助引擎 wiring**（`+ProactiveWiring`）、**外部 agent 感知 wiring**（`+AgentSensingWiring`：transcript 事件→气泡 + 陪伴卡片会话流接线）、**权限应答 wiring**（`+PermissionWiring`）、**多宠同屏装饰伙伴**（`+DecorativePets`：spawn/despawn/sync + `driveDecorativePets` 帧驱动 + `makeShimejiEnvironment` 共享 env，主宠之外的轻量物理伙伴）、**CoreLocation 适配器**（`CoreLocationCoordinateAdapter`：实现 `LocationAuthorizing` 协议，封装 CLLocationManager 请求授权 + 一次性坐标取位，供自动跟随天气位置功能） | 已落地（全局 Edit 菜单 2026-06-24；主动协助 wiring 2026-06-04；多宠同屏 S1-S3 运行时 2026-06-11；CoreLocation 适配器 2026-06-21） |
| **Shell** | `Sources/Shell/DesktopShellController.swift`, `MenuBarController.swift`, `PetShellWindow.swift`, `PetActionMenu.swift`, `ChatShellView.swift`, `DesktopOverlayView.swift`, `ChatBubblePanel.swift`, `ChatBubbleTheme.swift`, `SpeechBubbleShape.swift`, `PetEmotionBubble.swift`, `GlobalChatHotkey.swift`, `QuickAskHotkey.swift`, `OrbStateBridge.swift`, `BondedBubble.swift`, `BondedBubbleChain.swift`, `BondedSession.swift`, `BondedSession+Proactive.swift`, `ChatCardAnchor.swift`, `ChatCardState.swift`, `ChatCardTheme.swift`, `ChatCardMessageRow.swift`, `ChatCardComposer.swift`, `ChatCardView.swift`, `ChatCardWindowController.swift`, `CompanionTab.swift`, `CompanionTabBar.swift`, `PetChatTabContent.swift`, `AgentSessionStore.swift`, `AgentSessionTabView.swift`, `TranscriptListView.swift`, `TranscriptListCoordinator.swift`, `ContextUsageBar.swift`, `DiffView.swift`, `DetailContentView.swift`, `TurnMetadataBar.swift`, `SessionPickerView.swift`, `SessionRowCard.swift`, `SessionResumeCommand.swift`, `SessionRecency.swift`, `PinnedSessionStore.swift`, `BrowsedSession.swift`, `SessionBrowseSheet.swift`, `BesideMainLayout.swift`, `AgentConversationRow.swift`, `PendingActionView.swift`, `PermissionStackView.swift`, `PermissionCardWindowController.swift`, `ColumnContainerWindowController.swift` + `ColumnContainer/{Column,ColumnContainerState,ColumnPaneView,DetailPaneContent,ImagePaneContent,MillerColumnsView}.swift`, `WindowPinState.swift`, `DecorativePet.swift`, `SettingsWindowController.swift`, `SettingsRootView.swift`, `SettingsKeyForwardingWindow.swift` + `Settings{Backend,Pet,Weather,Proactive,Tool,Debug,System,About}Section.swift` + `PetLibraryView.swift` + `SettingsViewModel.swift`, `ThermalOverrideMode.swift`, `DynamicIslandController.swift`, `SystemPermission.swift`（权限项枚举：辅助功能/屏幕录制/位置/Apple Events 四项）, `SystemPermissionProbe.swift`（权限探针：各项 status 闭包 + request 分发，测试可 mock）, `SettingsPermissionsView.swift`（权限中心 UI：系统 tab 内 GroupBox，四项状态 + 申请/打开系统设置） | 三窗口（overlay/pet/chat）、右键菜单、菜单栏 status item、**桌宠操作菜单单一 source of truth**（`PetActionMenu`：闭包式共享构建器，状态栏菜单 `MenuBarController` + 右键桌宠菜单 `PetShellWindow` 都从它产出同一份 NSMenu → 内容/顺序/标题永远一致，加项只改一处；动作走 `Callbacks` 注入、状态走 `applyState` 同步、跟随/漫游灰显走 `validateMenuItem` pull 式 gate；装饰宠精简菜单独立。2026-06-25）、speech bubble shape 工具、pet 头顶情绪短气泡、⌥Space + ⌘⇧Space 全局快捷键、Bonded 气泡链 + Session（pet 主动智能输出 / idle 短语 / emotion bubble / 主动建议气泡）、**对话卡片**（`ChatCard*`：锚定 pet 旁的多轮可滚动聊天卡，`ChatCardAnchor` 纯函数选边 + clamp，spring 进场；⌘⇧Space / ⌥Space / pet 双击 / 灵动岛点击统一召唤；backing = `ConversationStore` + `replyStream` 写历史 + 拼上下文；**P3 升级为统一陪伴卡片**：顶部 `CompanionTabBar` 三段 tab（Pet Chat 走 `PetChatTabContent` 现有聊天 / Claude Code / Codex 走 `AgentSessionTabView`+`AgentConversationRow` 渲染 `AgentSessionStore` 折叠的外部会话流，store 合并 `SessionHistoryReader` 历史 + `AgentSensingService` 实时 events；**多会话 picker**：store 每 agent 持多 session log，选中**粘滞**（首次初选最近活跃，之后只手动切，§5.9），tab 顶 `SessionPickerView`（自定义 `Button`+`.popover` 富列表替 Menu；折叠栏绿点+标题+分支药丸+会话数 / 下拉行 标题·项目·分支·N条·相对时间；元数据由 `SessionMetadataScanner` 头尾扫 transcript 抽、`SessionRecency` 算相对时间）；**会话列表 = 活跃 ∪ 钉住 ∪ 当前选中**（2026-06-20：`makeSummaries` 合成，`injectedMeta` 兜底浏览/钉住会话元数据不被 poll 替换；没钉住的只有活跃才显，选中恒在不掉出）；**钉住**（行内 📌，`PinnedSessionStore` UserDefaults 持久化 → 跨静默/重启留列表，文件被删→`isUnavailable` 灰显不丢钉）+ **「浏览历史…」**（picker 底入口 → `NSOpenPanel` 选目录 → `SessionDirectoryBrowser` 智能识别(项目 cwd 编码 / `~/.claude/projects` 子目录直读)扫会话 → `SessionBrowseSheet` 列出 → 点行加载+可钉住；接线 `MinimalAppDelegate+SessionBrowse.swift`，`PETAGENT_DEBUG_PINTEST` 验跨重启持久 / `PETAGENT_DEBUG_SESSIONCARD` 验卡片渲染；Codex 完整 browse 留后续）；**会话行卡片统一**（2026-06-20：picker 下拉与浏览 sheet 共用 `SessionRowCard`（活跃点+标题+副行+复制+钉住，选中=accent 底色无勾），`SessionResumeCommand` 拼终端续聊命令复制（Claude `claude --resume <id>` / Codex `codex resume <id>`，参考 claude-devtools），`PinnedSessionStore` 改 `ObservableObject` 作钉住单一真相 → sheet `@ObservedObject` 观察、与 picker 同步）；**权限/问题待答**：2026-06-16 改 **pet 旁权限侧卡**（`PermissionCardWindowController` + `PermissionStackView` 堆叠**多请求队列** `claudePendingQueue`，陪伴卡片关着也能答；超时 600s + App liveness 轮询撤死卡；**带尖角**：`ChatCardShape` 画 beak，`PermissionCardState` 驱动 tailSide/tailPercent；**pet 模式**尖角指 pet，**row 模式**（点卡上「定位会话」`onLocate` → `locatePermissionSession` 选中触发会话 + 开陪伴卡片 + 高亮 `matchingPermissionRow` 行 + 贴卡旁尖角对准该行，toggle 切回）。源行 midY 由 `TranscriptListCoordinator.onHighlightedRowMidY`（`rect(ofRow:)` 几何，**取代跨不过 NSTableView 边界的 SwiftUI preference**）喂 `store.highlightedRowMidY`）；`PendingActionView`（允许/拒绝/选项/自定义答案）从会话流底部内联 retire 进侧卡，更早 retire 头顶 `PermissionCardBubble`）；**详情/drill-in 统一**（2026-06-18 重构）：所有「看详情 / 子 agent / workflow / 图片」收进**列容器** `ColumnContainerWindowController`（**一个**窗口贴主卡侧，横向平铺**访达式列视图**：点主卡行 → `openRoot` 根列，列内行 → `drillIn` 截断+追加子列，超屏横向滚动；列内容复用 `TranscriptListView`/`DetailPaneContent`/`ImagePaneContent`；纯逻辑 `ColumnStack` 无头测）。**取代** 旧多窗口侧卡机制（`SideCardStack`+3 卡控制器+beak，已删 ~1400 行，根治 z-order/远卡/移动跟随/双尖问题）。`DetailContentView` 统一详情块自带工具条（换行 / 原文·markdown 切换 / 复制）；`ContextUsageBar` 上下文占用条 Claude Code tab **常驻**顶部（无数据显「统计中」）；**Shell 因此依赖 `AgentSensing` 的 ConversationItem/AgentEvent/AgentSessionRef 值类型**，仍感知-free 不 tail/discovery）、Chat→Orb 状态桥接、**多宠装饰伙伴窗口单元**（`DecorativePet`：borderless 浮窗 + layer host + 拖拽转引擎，无 chat/雪；App `+DecorativePets` 驱动）、Settings 面板（**全面 modeless**：每个控件 onChange 即时生效并持久化、无「保存」按钮，LLM 文本框回车/关窗 flush，⌘W/Esc 关窗；sidebar 分组: 后端 / 桌宠（当前宠卡片 + 大小滑杆 + 管理库按钮）/ 天气 / 工具 / **调试** / 系统 / 关于；**`PetLibraryView` 库 overlay 卡片**：顶层 ZStack 弹出、点暗背景空白处/Esc 关、横排分类 tab + 网格 tile（主宠 checkmark / 同屏徽标 / 全部同屏）+ 搜索 + 导入 + 删除）、灵动岛 | 已落地（用户主动 ask 入口由对话卡片 `ChatCardWindowController` 承担：pet **双击**召唤、锚定 pet 旁、多轮历史、AccountyCat 式气泡外观；单击 = 轻反应（`triggerJump` + `.acknowledge`）。旧 `QuickAskWindowController` / `QuickAskView` + `BondedSession.injectQuickAskExchange` 已删除。BondedSession 收敛为「pet 主动智能输出」专用通道；legacy chatWindow 仍 instantiate 但默认 hidden — `ChatBubblePanel` / `ChatShellView` 待 refactor-cleaner 物理删） |
| **Context** | `Sources/Context/DesktopSnapshot.swift` 等 | 屏幕、active space、可见窗口（ownerName + bounds + **title** via `kCGWindowName`，需屏幕录制权限）、光标、AX 权限 — 全部 lazy + TTL/event-driven 刷新。窗口标题经 Orchestrator `DesktopContextFormatter` 注入 LLM 上下文（感知加深·标题层 2026-06-04） | 已落地 |
| **RuntimeBridge（纯 Swift）** | `Sources/RuntimeBridge/{RuntimeClient,LocalRuntimeClient,RuntimeTypes,PetMotion,PetMotionController,PetMotionRandom}.swift` | pet 运动 runtime + 运动仲裁 + 窗口几何。`LocalRuntimeClient`：pet 朝光标恒速追踪（160px/s）+ contact_count（移植自原 Rust）。`PetMotionController`（工作块 A，决策 D2）：**形象无关运动仲裁层** —— 每帧消费 cursor-follow 候选,按模式（`.physics` 透传 / `.roaming` 漫步 / `.perched` 栖息 / `.dragged` 跟手）仲裁出最终位置 + `PetMotionPhase`（walking 朝向 / idle / falling / perching）；纯值类型,App 帧循环唯一位置出口。**漫步（A2）**：空闲 ≥8s → `.roaming`,先重力降到可见地面(visibleFrame 底,Dock 之上)再沿地面走向随机路点(确定性 `PetMotionRandom` 选点)+ 到点暂停 + 边界 clamp。**爬墙（A3）**：漫步越过可爬窗口左/右侧边 → 沿侧边逐帧攀爬到顶 → 栖息站窗口顶边,x/y 跟随窗口移动(无 ID,按矩形邻近度逐帧匹配 `matchWindow`);窗口关闭/移走失配 → 解除 → 落回地面。`CollisionRect.collection`：窗口矩形 top→bottom 翻转 + wallpaper 过滤（喂 GPU 雪遮挡;也作 A3 爬墙候选）。`NoOpRuntimeClient`：测试 stub | 已落地（**Rust 退役 2026-06-06**；运动仲裁层 A1 + 漫步 A2 + 爬墙 A3 2026-06-06） |
| **Orchestrator（含 LLM/chat/上下文）** | `Sources/Orchestrator/`：`CompanionOrchestrator.swift`(replyStream/replyStreamOneShot/buildSystemPrompt/tick)、`BehaviorEngine.swift`、`ChatBehaviorStateMachine.swift`、`LLMProvider.swift` + `OpenAIProvider.swift` + `AnthropicProvider.swift` + `LLMProviderBox.swift`(运行时热换)、`ConversationStore.swift`(持久化 + rolling-window token 预算) + `ConversationMessage.swift`、`LiveContextBox.swift` + `PetContext.swift`、`DesktopContextFormatter.swift`(桌面窗口标题→system prompt)、`CompanionOrchestrator+Proactive.swift`(no-history 主动建议入口)、`Proactive/`：`ProactivityLevel.swift` + `TriggerKind.swift` + `ProactiveSettings.swift` + `ProactiveTriggerEvaluator.swift` + `ProactiveThrottleState.swift` + `ProactivePromptComposer.swift` + `ProactiveSuggestionGenerating.swift` + `ProactiveSuggestionEngine.swift`、`ToolModeBox.swift` + `OpenClawGatewayManager.swift` | bootstrap、tick、PresentationMapper、5 态 chat 行为状态机。**LLM chat 闭环已通**：OpenAI/Anthropic SSE 流式 + 持久化 + token 预算 + 桌面上下文注入(前台 app + 窗口标题列表 + 光标九宫格)。`buildSystemPrompt` 经 `DesktopContextFormatter` 注入可见窗口标题(感知加深·标题层 2026-06-04)。**主动协助引擎**（2026-06-04）：纯逻辑层（判定/节流/组词/设置，值类型+纯函数可单测）+ 编排 actor `ProactiveSuggestionEngine`（三入口 feedAppSwitch/feedSleepingChanged/tick → evaluate → 安全时机门 → 三道闸节流 + ignore-decay → no-history `proactiveSuggestion` LLM → sink 落气泡）；防打扰为第一性（4 级主动性 + 最坏 active 全开 ≤8 条/h），全程 additive 不写 ConversationStore / 不触发状态机 | 已落地（LLM chat 流式 + 双 provider + 工具模式路由全通；主动协助引擎 2026-06-04；旧 echo 占位已退役） |
| **ToolMode（工具引擎）** | `Sources/ToolMode/`：`ToolEngine.swift`(协议 + `ToolEngineError`)、`ToolModeRouter.swift`、`ClaudeCodeEngine.swift` + `CodexEngine.swift`(真子进程 spawn，watchdog 硬超时 + drain 防 EOF 竞态挂死 2026-06-04)、`StubClaudeCodeEngine.swift`、`CLIAvailability.swift` + `CLIProcessEnvironment.swift`、`SubprocessRegistry.swift` | 工具模式：`claude -p` / `codex exec` 子进程 stream-json/JSONL 增量 yield；按 `tool.engine.kind` 路由；app 退出统一 SIGTERM 收口 | 已落地（ClaudeCode + Codex 生产级；openCode 待 bundled runtime） |
| **AgentSensing（感知外部 agent 会话,P1）** | `Sources/AgentSensing/`(target deps `[]`,Foundation+os only)：`AgentEvent`(事件模型,旁挂 `attachments:[ImageAttachment]` P1-5 内联图片字节)、`ImageAttachment`(用户粘贴截图,base64→Data,廉价 Equatable)、`AgentActivityState`(`AgentActivityTracker` 折叠+跃迁)、`ParserHelpers`/`TranscriptParser` 协议、`ClaudeTranscriptParser`/`CodexTranscriptParser`(单行 jsonl→**0..N 事件**,P0-2:一条 assistant 消息 text+tool_use 各产一事件)、`JSONLTailer`(`FileTailer` 增量 tail + `SessionDiscovery` 按 mtime 找活跃)、`SessionMetadata`/`SessionMetadataScanner`(P3.8 G3:头尾扫 transcript 抽 标题/分支/消息数,带 64MB 预算上限 + mtime 缓存,供 picker 消歧)、`PinnedSessionRef`(钉住引用,Codable 持久化)/`SessionDirectoryBrowser`(2026-06-20 选目录扫历史会话,智能识别 cwd 编码 / projects 子目录直读)、`AgentSensingService`(actor 编排)。接线在 App 层 `MinimalAppDelegate+AgentSensingWiring.swift`(事件→气泡+一次性 `SignatureAction`,菜单栏开关) | **只读感知**「你那个**外部** Claude Code/Codex 编码会话在干嘛」(与 `ToolMode` 反方向:那是桌宠自己 spawn agent 当后端)。**走 transcript-tail 非 hook**:只读 tail `~/.claude/projects/**/*.jsonl` + `~/.codex/sessions/*.jsonl`,零 settings.json 改动、零本地 server、与其它 hook 工具零冲突、Claude+Codex 一套引擎。**感知层不依赖 AppKit/Rendering**,映射成桌宠反应放 App 接线层(气泡 + `SignatureAction`,**不碰 chat 状态机**)。 | P1 感知管线 + App 接线已落地 2026-06-12(60 测试,对真实 transcript 验过,实机验过);P2 权限应答(HTTP hook server + 弃权共存,schema 合 Claude Code 官方文档逐字节一致;弃权回**空 body**)已落地;**P3 统一陪伴卡片**(P3.1 tab 壳 + P3.2 会话流 + P3.3 权限内联 + P3.4 Codex 只读/tab 红点 + P3.6 会话切换 picker + **P3.7 工具详情查看(①数据层 detail + ②内联 accordion + ③侧宽卡 spring/halo + ④进场动画打磨 + ⑤Codex parser detail 对齐)全部已落地实机验过**;**P3.8 会话流完整化(G1 气泡全宽+diff 红绿 / G2 消息全文+折叠侧卡 / G3 会话元数据+popover picker / G4 增量加载「加载更早」字节游标窗口读+稳定 id prepend+锚定不跳+上滑 scroll-offset 自动加载/预加载,实机真实 1GB 验过)全部已落地**;本 target 含 `SessionHistoryReader`(`readWindow`/`HistoryWindow` 字节游标窗口读 + `readWindowSkippingNoise` 跳 attachment 噪音窗,G4 + `readEarlierRows` 2026-06-20 按可见 turn 行累积、32MB 预算根治重型会话滚不动)/`AgentConversation`(`build(idStart:)` 稳定 id + **`buildTurns`/`buildTurnItems` turn 模型** 2026-06-16:事件折叠成 `ConversationTurn`/`AssistantTurn`+`TurnStep`,主行=用户+模型一轮,思考/工具折进元数据栏,借 claude-devtools AIGroup;parser 捕 thinking/usage/model)/`SubagentIndex`(D2:扫 `<sid>/subagents/*.meta.json` 的 `toolUseId`→子 agent transcript,parser 捕获 tool_use id 关联,Task 行点开子 agent 侧卡)/`AgentSessionRef`/`SessionMetadata`/`SessionMetadataScanner`/`PermissionPrompt`/`PermissionDecision`/`PermissionHookServer`/`HookInstaller`,详情/子 agent/图片渲染在 Shell **列容器**(`ColumnContainer/*`,2026-06-18 取代已删的 `AgentDetailCardView`/`AgentDetailCardWindowController` 等多窗口侧卡));P3.5 打磨持续 |
| **SandboxPhysics（GPU 物理沙盒 target，deps[]；2026-06-12 从 Rendering 分出，可独立复用）** | CPU 参考：`Sources/SandboxPhysics/FallingSand/{FallingSandSpecies,FallingSandCell,FallingSandRandom,FallingSandGrid,FallingSandRules,FallingSandMovement,FallingSandPhase,FallingSandSimulation}.swift`；GPU 引擎 + 混合雪：`Sources/SandboxPhysics/FallingSand/{FallingSandUniforms,FallingSandKernels,FallingSandGPUEngine,FallingSandParticles,FallingSandParticleKernels,FallingSandDriver,FallingSandRenderPipeline,FallingSandParticleRenderPipeline,FallingSandTuning}.swift`（雪/雨/水/冰/汽 同一套 FallingSand:雪=kind0、雨=kind1 water 粒子,同源）；overlay 宿主 **留 Rendering**：`MetalSnowOverlayView.swift`（MTKView，`@_exported import SandboxPhysics` 透传 Shell/App，调用方零改动）；诊断留 Rendering：`SnowDiagnostics.swift`, `SnowFrameRecord.swift`。**退役的独立 `GPURainCoordinator`/`MetalRainRenderer`（Phase B 旧雨,overlay 永久隐藏）已于 2026-06-12 删除 —— 雨以 FS 为准** | **混合雪**：飞行雪 = GPU 浮点粒子（`fs_integrate_particles` 亚像素 + `fs_particle_land` 落地沉积到 CA）；落地积雪 = cell-CA（双缓冲 + atomic 认领 clear/claim/commit 三 pass + 位置哈希相变 + 深度负反馈升华平衡 `fs_compute_column_depth`，稳态 h*=√(S/k)）。**窗口碰撞**：2D 遮挡 mask（`fs_rasterize_occlusion`）。**雪堆 pet（B1）**：`fs_rasterize_pet` 把 pet 当前帧 alpha 轮廓 OR 进同一 occlusion buffer（窗口栅格化后、清遮挡前）→ 雪堆 pet 轮廓顶、内部每帧清；`FallingSandUniforms` 尾部 5 pet 字段 + `engine.uploadPetMask`/`disablePetOccluder` + `driver.pendingPetOccluder`。**扬雪（B2）**：`fs_integrate_particles` 加 pet AABB + 横速度（`FSParticleUniforms` 尾部 6 字段）→ 雪粒子在 AABB 内且 pet 明显横移 → 横扫上扬（踩雪喷散）；`driver.pendingPetSweep` + `particles.petSweep*`。**积雪堆高**（2026-06-03）：emit=40 / cap=24 / 升华 base=0.012 + k=0.0015（全屏 ~1512 列需够大 emit 支撑可见积雪，cap 兜底防 runaway）。**雨 = 一等公民 water**（2026-06-03）：雨粒子 kind=1 落地沉积 FS_WATER → 复用水漫流成水洼，温度耦合（温和保持液态 / 冷天 water→ice / 热天蒸发）。**雨视觉**（2026-06-03）：飞行雨蓝色 streak 沿 velocity 定向随风斜（`rainWindLean`）；落地按 `splashProbability` 转弹道 splash 水花（`kind=2`，横飞+上抛弧线消亡、不二次沉积）；积水洼 `wetness` 湿亮反光（下雨 lerp→1，停雨回落 `wetnessBaseline`）。`kind` = 0 雪 / 1 主雨 / 2 水花。 **实时调参**：`FallingSandTuning`（~23 参数单一真相源，Codable 持久化 UD）→ driver 每帧 apply → 设置→调试 面板拖滑块即时生效（省 edit→build→install 循环）。**CPU 参考**逐格对拍 GPU 移动。**接入**：`FallingSandDriver` → `MetalSnowOverlayView.encodeFrame` → `DesktopOverlayView`/`DesktopShellController` 透传 → 帧循环天气驱动 spawn（启动即启用，无开关）。 | 已落地（FS 转正 2026-06-02：旧 GPU 粒子雪 + Rust fallback 雪 + pile 持久化 + orb 积雪遮罩 + 雨水洼沉积 全部移除；调参面板 2026-06-03） |
| **Rendering（Pet 视觉 / A.5.1）** | 协议 + 插件：`Sources/Rendering/{PetRenderer,PetPlugin}.swift`；抽象形象（Metal SDF）：`{MetalPetRenderer,OrbMetalRenderer,SlimeMetalRenderer}.swift` + `Shaders/Orb.metal`；社区形象（sprite）：`{SpriteSheetPetRenderer,CodexSpritePackLoader,SpritePackGeometry}.swift`；Live2D（工作块 D D-1，SDK 无关安装+发现）：`{Live2DModelPackLoader,Live2DModelInstaller}.swift` | `PetRenderer` 协议（`view` + 五态 `updateForState` + `SignatureAction` + pause/resume）。**插件系统**：`PetPlugin`（类型式）+ `PetPluginEntry`（值类型，供运行时 sprite 包）+ `PetPluginRegistry`（`register`/`plugin(for:)`/`all`）。**抽象形象**走 `MetalPetRenderer` 基类（`shaderSource`/`encodeFrame` hook + CVDisplayLink 30Hz frame-skip + ease-out uniform 插值 + `updateForVelocity` squash）：Orb（单球 Fresnel metaball）/ Slime（3 招牌动画）。**社区形象**走 `SpriteSheetPetRenderer`：兼容 Codex/petdex pet 包（8 列 × 9 或 10 行、帧 192×208 spritesheet），`CALayer.contents = CGImage.cropping` 逐帧播放（`.nearest` 保像素感，9 状态行表移植 petdex + 可选 row 9 climb），非 Metal；**行数几何推导**：`SpritePackGeometry.rows(width:height:)` 按「8 列 + 192×208 cell 比例」推 sheet 行数（严丝合缝匹配 ≥10 才认 climb 行，否则回退 9 → 经典 8×9 包逐像素零回归，无需 pet.json 元数据），renderer/loader/缩略图统一用它切帧（取代旧写死 9 行）；`NamedState.climbing` 有专用行走 row 9（`climbing(.left)` 靠 layer 水平翻转）、否则回退 running 镜像；`CodexSpritePackLoader.discover()` 按 `PetLibrary` 扫**自有库** `~/.petagent/pets/<type>/`(codex/shimeji/live2d,类别由子目录定)+ **可选兼容目录** `~/.codex/pets/`(开关默认开,类别由 pet.json source 定),同 slug 自有优先去重,自动列出社区宠物（id 前缀 `codex:`）。**目录架构** `PetLibrary`(`PetLibrary.swift`):自有根/类型子目录/兼容根 + 加载兼容/装兼容双开关(UserDefaults)。**运动态走帧（工作块 A2）**：`updateForMotion(_:)` 把 `PetMotionController` 的 `PetMotionPhase` 映射到走帧行（`.walking(.right)`→running-right row1 / `.walking(.left)`→running-left row2 / `.falling`→jumping row4 / `.idle`/`.perching`→回落情绪态行）。**（2026-06-21 各格式原汁原味驱动:此「运动态映射走帧行 + 优先于情绪态」机制对 petdex 已删）** —— 引入 `PetDriveModel`(autonomousEngine/proceduralMotion/activityStateIndicator/selfAnimating,各 renderer 声明,帧循环 `switch driveModel` 分发,`drivesOwnWindowPosition` 由它派生仅 autonomousEngine→true);petdex sprite 走 `.activityStateIndicator`,`SpriteSheetPetRenderer` **去强转**改 most-recent-wins:`updateForActivity(PetActivityVisual)`(agent 活动态,App `AgentActivityVisualMapper` 映射 + `ActivityCoalescer` 250ms 防抖)vs `updateForState`(聊天态),`updateForMotion` 退化 no-op、位置固定不漫步(哆啦=Claude Code 活动指示器);Live2D 走 `.selfAnimating` 原地自驱,Orb/Slime 仍 PetMotionController。`PetActivityVisual`/`ActivityCoalescer`/`PetDriveModel` 同在 Rendering。一次性招牌动作不被打断（`refreshLoopAnimation` 仅行变化时重播,免每帧 reset）。**淋湿（工作块 B3）**：`updateForWetness(_:)` 按淋湿度（app 每帧按 isRainEnabled lerp）调蓝色水渍层不透明度,该层用当前帧 alpha 作 mask → 只染 pet 像素轮廓（非整框）。**雪堆 pet（工作块 B1）**：`currentFrameAlphaMask(cellSize:maxDim:)` 当前帧 CGImage 按 `.resizeAspect` 重绘取 alpha → `PetAlphaMask`（公开值类型,row0=sprite 顶,按帧缓存）,喂 falling-sand `fs_rasterize_pet` 作第二 occluder（雪堆轮廓顶）；Orb 等无轮廓形象返回 nil。`OrbBehaviorState` 五态镜像枚举防 Rendering→Orchestrator 反向依赖。**Live2D 模型插件化安装（工作块 D D-1）**：`Live2DModelPackLoader.discover()` 扫自有库 `~/.petagent/pets/live2d/<slug>/` 限深找 `*.model3.json` 包 → `PetPluginEntry(category:.live2d)`，model3 stem 当显示名，`makeRenderer` 回退 nil（Shell 走空 NSView placeholder，真渲染待 D-2）；`Live2DModelInstaller` 把 .zip/目录的 Live2D 包（model3.json+moc3+textures+motions）zip-slip 校验 + ditto 解压 + 定位包根 + 整包原样拷进 `live2d/<slug>/`（slug 净化防遍历、覆盖重装、`containsModel3` 供拖入路由探测）。Shell 端 `importLive2DModel`/`importDropped`（拖入按 `containsModel3` 自动分流 Live2D vs Shimeji）+ `rebuildPetList` 合并 Live2D 条目。**来源分类(PF3 picker)**：`PetCategory`(内置/Codex社区/Shimeji导入/Live2D,借鉴 AccountyCat `ACPortraitSource`)+ `PetIdentity.category` + `PetPluginEntry.thumbnail`(idle 首帧);`CodexSpritePackLoader` 按 pet.json `source` 字段判 `.shimejiImport` vs `.codexCommunity` + 裁首帧缩略图 → 设置面板按来源分组展示 | 已落地（Phase A 基类抽取 + Slime；Phase D sprite 包加载 2026-06-06；雪堆 pet B1 2026-06-06；picker 分组+缩略图 2026-06-06；pile→orb 接触染色随旧雪移除 2026-06-02） |
| **ShimejiImport（工作块 C）** | `Sources/ShimejiImport/{ShimejiFrameMapping,ShimejiActionsParser,ShimejiSpriteSheetPacker,ShimejiPackConverter}.swift`（仅 CoreGraphics/Foundation/ImageIO/XMLDocument）；CLI：`Sources/ShimejiConvert/main.swift`（executable `shimeji-convert`） | Shimeji-ee 包 → petdex sprite 包转换。**两条解析路径**(`makeSheet` 自动选)：① **帧号约定**(标准 Shimeji-ee 包，shimeN 覆盖 ≥4)走 `ShimejiFrameMapping`；② **actions.xml 解析**(自定义命名包，如火柴人 `dance01.png`，shimeN 稀疏)走 `ShimejiActionsParser`(`XMLDocument` → `[动作名:[Pose]]`，只取叶子动作 Stay/Move/Animate 的 Pose 帧序，跳过 Sequence/Select 编排 + Embedded 引擎动作) + `ShimejiActionRowMapping`(标准动作名→行候选表) → `ShimejiSpriteSheetPacker.packRows`(已 resolve 的每行帧拼图)。`ShimejiFrameMapping` 是「Shimeji 46 帧 → petdex 9/10 行」手工映射表（调研 canonical actions.xml 所得，必备行缺帧回退 shime1、左向行水平翻转；**`RowSpec.optional` 的 row 9 climb=shime12-14**，源帧全缺则整行省略）；`ShimejiSpriteSheetPacker.pack` 把 `[N:CGImage]` aspect-fit 进 192×208 cell 拼 8×`effectiveRows`(9 经典/10 含 climb) spritesheet（row0 在顶,与 `SpriteSheetPetRenderer` cropping 同系）+ `petJSON`（`rows` 字段报真实行数）；`ShimejiPackConverter.convert` / `convertZipOrDir`（接受 `.zip` 经 `ditto` 解压或目录;`findAllFrameDirectories` 限深递归容任意嵌套）端到端（扫 `img/<角色>/shimeN.png` → ImageIO 加载 → pack → 写 `spritesheet.png`+`pet.json` 到 `~/.petagent/pets/shimeji/<slug>/`）。**多角色包 → N 个独立包**(返回 `[URL]`):`findAllFrameDirectories` 收集**所有**含帧角色目录,`convert` 循环对每角色调 `writePack`(忠于 Shimeji-ee「每 img/<角色>=独立 mascot、默认全加载」语义,官方默认包即 Shimeji+KuroShimeji 双角色);`slug`/`displayName` 仅单角色生效;slug 冲突(全非 ASCII 名都兜底 `"shimeji"`)用 `stableHash4`(FNV-1a 4-hex)加稳定后缀 `shimeji-<hash>`(重复导入稳定可覆盖,不堆 `-2/-3`)。CLI `shimeji-convert`(循环打印 N 个输出);**应用内导入**:`Shell` 依赖本模块,`SettingsViewModel.importShimeji`(后台转换 → 主线程 discover+register+热刷新 picker,收 `[URL]` 自动选中首个角色)+ `SettingsPetSection` 拖拽/按钮入口。装好即被 `CodexSpritePackLoader.discover()` 发现(库层天然支持 N-slug,零改动) | Commit 1（打包核心）+ Commit 2（CLI）+ 应用内拖拽/按钮导入已落地 2026-06-06（真实包视觉验收通过）；多角色全转 N 包 2026-06-07；非标准包 XML 解析待续 |
| **Live2D 原生栈（工作块 D，可选/条件编译）** | 入库:`Sources/CubismCore/`(C 桥 shim + modulemap)、`Sources/Live2DBridge/{include/Live2DBridge.h,module.modulemap,Live2DBridge.mm,L2DLive2DModel.mm,L2DUserModel.{hpp,cpp}}`(ObjC++ 门面 + 模型渲染 + motion 引擎 C++ 子类)、`Sources/Live2D/{Live2DSmoke,Live2DModelProbe,Live2DPetRenderer,Live2DEmotionMap,Live2DSilhouetteExtractor,Live2DWetTintPass,Live2DThumbnailGenerator}.swift`、`scripts/build-cubism-metallibs.sh`；gitignored Vendor(setup-cubism.sh 解,**说明见 `Vendor/README.md`** —— git 状态/许可/闭源/安全/为何不迁 Vivarium):`Vendor/Cubism/{Core/lib+include, Framework/src, FrameworkMetallibs(477), Samples/Hiyori(测试 fixture)}`；`Tests/Live2DTests/` | **仅当 `Vendor/Cubism/` 存在时编**(Package.swift `hasCubism` 条件块,无 SDK 者 clone 照常 build)。分层:`CubismCore`(D-0,官方 Core C API 静态库 → SwiftPM 模块)→ `CubismFramework`(D-2.0,官方 Native Framework C++ 75 cpp + ObjC++ Metal renderer 7 mm;排除 D3D/GL/Vulkan + Metal/Shaders;`-fno-objc-arc` + C++14)→ `Live2DBridge`(ObjC++ 门面:`L2DBridge` 生命周期 StartUp+Initialize + `loadMocAtPath` 解析 + `probeMotionAtModel3Path` 无头跑 motion 引擎 + `L2DLive2DModel` 加载/逐帧 Metal 绘制 + `L2DUserModel`(继承 `CubismUserModel` 的 motion/呼吸/眨眼/物理/pose/表情引擎,D-3a);公开头仅 Foundation → Swift 原生 import;**Cubism 全局态非线程安全 → 所有入口 `@synchronized([L2DBridge class])` 共享锁**)→ `Live2D`(Swift:`Live2DModelProbe` 元信息 + motion 度量 + `Live2DPetRenderer: PetRenderer` 独立 CAMetalLayer+CVDisplayLink 透明渲染 + 情绪/速度→motion 映射(D-3b)+ 雪堆 occluder 离屏轮廓读回(D-4a)+ 雨天淋湿水渍 Metal tint pass(`Live2DWetTintPass`,B3))。**渲染管线**:Metal renderer 运行时从 `mainBundle/Contents/Resources/FrameworkMetallibs/` 按名加载 metallib(`build-cubism-metallibs.sh` 复刻 SDK CMake 编 16×5 blend 矩阵共 477,build.sh 拷进 .app)。**工厂注入**:`Live2DModelPackLoader.rendererFactory`(Rendering 不依赖 Live2D 避环)← App 启动 `#if canImport(Live2D)` wire。**前置**:Metal Toolchain。 | D-0 Core 链接 + D-1 模型插件化安装 + D-2.0 framework + D-2.1 模型解析 + D-2.2 真渲染(Hiyori 桌面验收)+ D-2.2c 窗口尺寸适配 + D-3a motion/呼吸/物理引擎(Hiyori「活起来」)+ D-3b 情绪态/速度映射(reaction motion + 看向)+ D-4a 雪堆 occluder(live 形变轮廓离屏读回 → Block B `fs_rasterize_pet`,实机验收)+ B3 淋湿水渍(`Live2DWetTintPass` Metal tint,跟随真渲像素)已落地 2026-06-07;D-4b GPU mesh occlusion(精度终态)待续 |
| **PetCatalog（PF3 在线安装）** | `Sources/PetCatalog/{RemotePet,PetCatalogClient,PetPackInstaller}.swift`（仅 Foundation，网络经 `AssetFetcher` 协议注入）；Shell 端 UI：`{PetBrowseModel,PetBrowseView}.swift` | Codex/petdex 在线 catalog 客户端(应用内一键装,蓝本 agentpet)。`PetCatalogClient.fetchManifest` 拉 `petdex.crafter.run/api/manifest`(lenient 解码 → `[RemotePet]`);`PetPackInstaller.install` 下 pet.json + spritesheet 到自有库 `~/.petagent/pets/codex/<slug>/`。**安全**:`TrustedAssetHosts` allowlist(防 SSRF)+ Referer 防盗链 + 429/5xx 退避 + 非 2xx 不落盘 + slug/文件名净化(防路径遍历)。`AssetFetcher` 协议 → mock 全测不碰真网。**UI**(2026-06-21 统一弹窗):`PetBrowseModel`(manifest 过滤 + 已装集 + 后台下载 + 装≠选)+ `PetBrowseContent`(搜索 + 分类段 + 获取/下载中/已装三态,从原 `PetBrowseView` 抽出薄壳已删)内嵌 **`CommunityPetsSheet`** 的 Codex tab(`CommunityPetsSheet` = Codex/Shimeji 两 tab:Codex 一键装 + 前往 petdex 社区链;Shimeji 因 shimeji.org 拒自动化只深链 `shimeji.org/u/5stf0k0c` + 拖入导入 + 合规说明,**零网络抓取**);`PetLibraryView`「获取社区桌宠…」单入口弹此 sheet;`OnboardingStarters`/`OnboardingStartersView`/`MinimalAppDelegate+Onboarding` 空库首启动推荐火柴人+哆啦(不 bundle 版权资产);`MinimalAppDelegate+Settings` 抽 `buildSettingsController`/`ensureSettingsWindowController`;装完 `rebuildPetList` 热刷新 picker | Commit 1（核心 + 8 测试）+ Commit 2（浏览 UI + Settings 接线）已落地 2026-06-06;**统一弹窗 + onboarding 2026-06-21** |
| **PetBehavior（P4 行为引擎，Vivarium target）** | `Packages/Vivarium/Sources/PetBehavior/`：行为图层 `{ShimejiBehavior,ShimejiBehaviorGraph,ShimejiBehaviorParser,ShimejiBehaviorScheduler,ConditionEvaluator}`；求值层 `{BehaviorEnvironmentModel,ShimejiScriptEngine,JSConditionEvaluator}`；动作执行层 `{ShimejiAction,ShimejiActionLibraryParser,ShimejiMascotRuntime,ShimejiEnvironmentBorders,ShimejiActionRuntime,ShimejiComplexRuntime,ShimejiEmbeddedRuntimes,ShimejiActionRuntimeFactory,ShimejiMascotEngine,ShimejiRuntimePackLoader}`（纯 Foundation + 链 JavaScriptCore，deps `[]`） | 数据驱动 Shimeji 完整运行时（1:1 移植 Shimeji-Desktop 语义）。**行为图(S1)**：behaviors.xml 两遍式解析 + `pickNext` 加权随机 NextBehavior（`buildNextBehavior` 移植）。**求值(S2/B-2)**：`ShimejiScriptEngine` 单 JSContext 常驻 + 每 tick `sync` 重绑 mascot 快照 + evalBool/Double 字面量快通道 + `VelocityX/FootDX` 变量写回；JS 对象图含各 area 四边 + 派生 floor/ceiling/wall（`isOn` 移植）+ cursor 半衰速度。**动作执行(B-1/B-3)**：actions.xml 全保真模型（全动作类型/多 Animation Condition 分支/IsTurn/引用参数覆盖/匿名内联）+ `ShimejiActionRuntime` 类族（Move 目标吸附+转向插播/Fall 物理积分+亚像素+路径分步碰撞/Jump/Dragged 弹簧/Regist/Look/Offset/Sequence/Select seek）+ `ShimejiMascotEngine` facade（tick=40ms：行为衔接 + hijack pointerPressed→Dragged/release→Thrown/LostGround→Fall + 出屏防护），每 tick 产出 `ShimejiMascotFrame`（image/imageAnchor/anchor/lookRight 纯数据）。**坐标 top-origin**（Shimeji 原生，B-5 host 翻转）。**多宠互动 = Hug(2026-06-11,忠实移植 Shimeji ScanMove,实机验拥抱成功)**：`ShimejiScanMoveRuntime`（跑向「广播了本动作 Affordance 的邻居」,到达置 `ctx.pendingInteraction`)+ 引擎暴露 `offeredAffordance`/`seekingAffordance`/`triggerBehavior`/`consumeOutgoingPairing` + `BehaviorEnvironment.scanTarget`(host 把广播者匹配给扫描者)。`Broadcast`/`Interact`→`Animate`(affordance 由引擎从当前 leaf 读)。App `driveDecorativePets`/`driveShimejiPet` 每帧建 affordance 注册表 → 为扫描者注入 `scanTarget` → tick 后落地配对(把目标 pet 切到 TargetBehavior,跨引擎)。火柴人包**自带的 Hug**(`HugAffordance` 广播 + `HugSearch`/ScanMove 扫描跑过去 + `HuggingSolid`/`HuggedSolid` 配对动画,专属 hug 帧)由此真跑起来。**之前的 `__MeetPeer` 凑数近似已删**。 | **S1+S2+B-1~B-5 已落地 2026-06-10(实机验收通过)**（349 测试含端到端叙事：半空→落地→反弹→行为图选 Walk→走到目标 / 拖拽→甩出带光标动量；真实 DefaultMascot conf 300 tick 不崩 + 行为流转；code-reviewer 10 等价点对抗审查 0 CRITICAL，F-1 已修）；B-1~B-5 全落地：含动作执行器 + 包保留 + 渲染/桌面接线;后续 polish(情绪/lip 映射、窗口拖拽 hijack 打磨)按需 |
| **Shimeji（P4-B-5 胶合，根包 App 侧 target）** | `Sources/Shimeji/{ShimejiPetRenderer,DesktopEnvironmentProvider,ShimejiWindowGeometry}.swift`（deps Vivarium 的 Rendering+PetBehavior+Context + AppKit） | Shimeji 原始帧引擎 ↔ app 的胶合层。`ShimejiPetRenderer: PetRenderer` 持 `ShimejiMascotEngine`,host 每帧 `advance(environment:)` → tick 引擎一拍 + 渲当前帧图到 CALayer（ImageAnchor 对齐 + 右向图翻转/锚点镜像 + 帧缓存）+ 返回 NSWindow frame；`DesktopEnvironmentProvider` 把 `DesktopSnapshot`（cursor bottom-origin / windows top-origin）翻成 top-origin `BehaviorEnvironment`（cursor 翻转+半衰速度 / workArea 翻转 / activeWindow CGWindow top-origin 直用）；`ShimejiWindowGeometry` anchor−imageAnchor → bottom-origin frame。落 App 侧（非 Vivarium/Rendering）避免渲染层反依赖 PetBehavior/JSC。`CodexSpritePackLoader.shimejiRendererFactory`（App 启动注入）让 `.shimejiImport` 含 conf/img 包优先走引擎;`MinimalAppDelegate.advanceRuntimeFrame` 检测 `ShimejiPetRenderer` → 引擎驱动窗口,PetMotionController 让位 | **B-5 已落地 2026-06-10**（8 测试 + 真实包 headless 全管线 + 实机截屏验收）;窗口拖拽 hijack ✅（PetRenderer 协议 drivesOwnWindowPosition + handlePointerDown/Up，down→Dragged 跟手 / up→Thrown 甩出） |
| **Weather** | `Sources/Weather/WeatherSnapshot.swift`, `WeatherConditionKind.swift`, `WeatherDataProvider.swift`, `SimulatedWeatherService.swift`, `WeatherStateManager.swift` | 天气数据层 — Foundation only,不引 WeatherKit / CoreLocation。`WeatherDataProvider` 协议 + `SimulatedWeatherService`(按本地小时数生成假天气,温度 -8...8°C / 风速 1...8 m/s) + `@MainActor WeatherStateManager` 15min Timer + 失败降级(provider throw → 用 simulated 兜底);默认 location 硬编码北京。`MinimalAppDelegate` 启动时 `setupWeatherStateManager` wire onUpdate 闭包 → 温度(°C→0..1)写 `fallingSandAmbientTemperature`（温度模式覆盖档非 auto 时用覆盖值）。`forcedCondition` 强制天气时温度也用 `representativeTemperatureC` 自洽（强制雪→-5°C 不融）。（旧 `gpuRainCoordinator.externalWindX` 风速接线随退役雨于 2026-06-12 删除；天气风速→FS wind 联动仍是 follow-up，见末列。）**温度模式覆盖档**（设置→天气）：`ThermalOverrideMode`（auto/winter/spring/sauna）覆盖 ambient | Phase 0 已落地;真实 WeatherKit 接入待 Apple Dev entitlement。天气风速→FS 雪动态 wind 联动是 follow-up |

## 4. Swift / Metal 职责边界

跨边界数据结构应保持窄，目前是 `RuntimeInput` / `RuntimeOutput`：

```text
RuntimeInput
  dt, cursor, pet_pose, collision_rects (z-order),
  is_snow_enabled, previous_particles[..], world_w, world_h, ax_trusted

RuntimeOutput
  pet_pose, particle_count, particles[..], contact_count, is_snow_enabled
```

### Swift / AppKit 负责「系统知道什么 + 角色该做什么」

- `NSWindow` / `NSPanel` / `MTKView` 生命周期和层级
- TCC（Accessibility / Screen Recording / Location / Apple Events，权限中心 `SettingsPermissionsView` 申请，已落地）
- 桌面上下文采集：window / cursor / frontmost app / accessibility
- AI 编排（LLM chat 流式 + 双 provider，已落地）、工具调用（`claude -p` / `codex exec` 子进程，已落地）、安全策略（API key 仍存 UserDefaults，未迁 Keychain）
- 行为决策（`BehaviorEngine`）

### pet 运动 runtime（纯 Swift `LocalRuntimeClient`，2026-06-06 起）

原 Rust `weather_motion_runtime` 已退役 —— 其唯一 live 逻辑（pet 朝光标恒速追踪 + contact_count，~40 行）移植进 Swift `LocalRuntimeClient`，雪粒子子系统（GPU falling-sand 重写后已死，`wantsParticles` 恒 false）随 Rust 一并删除。

- `LocalRuntimeClient.step(input)`:pet 以 160px/s（原 `PET_TRACKING_SPEED`）朝光标 clamp 移动（够近吸附消抖）+ 统计光标命中窗口数 `contact_count`，不再产出粒子。这是上游算出的「cursor-follow 候选位置」。
- **运动仲裁层 `PetMotionController`（工作块 A，2026-06-06）**:候选位置不直接落地,先经 `PetMotionController.resolved(previousPosition:physicsCandidate:input:)` 仲裁。它是 pet 位置的**唯一决策出口**(决策 D2):按 `idleSeconds`/窗口邻近度选模式（`.physics` 透传 / `.roaming` 漫步 / `.perched` 栖息 / `.dragged` 跟手），并产出形象无关的 `PetMotionPhase` 转发给各 renderer（`updateForMotion`，Orb no-op，sprite 切 running-left/right 走帧)。位置无状态:每帧由 App 传权威 `previousPosition`(= currentRenderState 上帧值,拖拽/不跟随也准)→ 免 staleness。**A2 漫步 + A3 爬墙已实装**:空闲 ≥8s → 重力降到地面 → 沿地面随机溜达 + 暂停;溜达中越过可爬窗口侧边按概率沿侧边攀爬到顶栖息,随窗口移动跟随、窗口消失则落回地面。A1 `.physics` 仍透传(零回归)。在 `MinimalAppDelegate.advanceRuntimeFrame` 的 `isFollowingEnabled` 分支内逐帧驱动(screenBounds 取 `currentScreenFrame()` visibleFrame,windows 取 `CollisionRect.collection`)。
- 雪/雨物理全在 GPU falling-sand（Metal compute），与 pet 运动 runtime 无关。
- `RuntimeInput`/`RuntimeOutput` 里残留的 particle 字段(`particles`/`particleCount`/`previousParticles`/`wantsParticles`)为退役遗留，恒空，待后续剥除。

### Metal 负责「天气/沙物理模拟 + 渲染」（falling-sand，全 Buffer 无离屏纹理）

CA 模拟数据**用 `atomic_uint` `MTLBuffer`，不用 `RWTexture`**，渲染直接画 drawable（无离屏 MRT 纹理）：`cellBufferA/B`（双缓冲 `atomic_uint` CA 网格，~127K cell @ 4px；payload pack species/age/clock）+ `reservationBuffer`（无锁移动认领）+ `temperatureBuffer`（per-cell Float，相变读）+ `occlusionBuffer`（per-cell UInt8 窗口遮挡 mask）+ `rectsBuffer`（窗口矩形）+ `columnDepthBuffer`（每列雪深）+ 粒子 buffer。部分 spawn / temperature 写入与回读走 CPU 路径（`storageModeShared` buffer 的 `.contents()`）。

- **模拟 — compute pass**（`FallingSandKernels` / `FallingSandParticleKernels`）：
  - 飞行粒子：`fs_integrate_particles`（亚像素重力/风/turbulence 积分）→ `fs_particle_land`（触支撑面沉积进 CA cell）
  - 落地积雪 CA：三 pass 无锁移动 `fs_clear_reservation` → `fs_claim_move`（原子认领目标格）→ `fs_commit_move`，双缓冲乒乓；`fs_apply_phase`（按温度 + 位置哈希做 snow↔water↔ice 相变）；`fs_compute_column_depth`（每列雪深 → 深度负反馈升华平衡，稳态 h\*=√(S/k)）
  - 窗口碰撞：`fs_rasterize_occlusion`（窗口矩形栅格化成 per-cell mask）+ `fs_clear_occluded`
- **渲染 — render pass**（`FallingSand{Render,ParticleRender}Pipeline`，**两道都直接画 drawable，无离屏 MRT 纹理**）：
  - 积雪：`fs_fullscreen_vertex`（3 顶点全屏三角）+ `fs_soft_fragment` —— 每 fragment **反查 `cellBuffer`** + 3×3 邻域采样累加柔边 alpha（`colorAccum/alphaAccum` 加权，孤立雪花软、雪堆实），species→颜色（snow 0.95 / water 0.26,0.52,0.92 / ice 0.72,0.85,0.95）+ `wetness` 湿亮 sheen mix；硬像素变体 `fs_pixel_fragment`
  - 飞行粒子：`fs_particle_vertex/fragment`，instanced quad（每粒 6 顶点），径向 alpha 软边
  - 透明叠桌面：`CAMetalLayer.isOpaque = false` + alpha blend
- **设计选择**：网格用 `atomic_uint` **Buffer** + 三 pass 无锁认领，而非 `RWTexture` —— atomic 操作 buffer 比 texture 顺手；渲染 fullscreen fragment 直接读 buffer，省一趟离屏纹理。
- **已落地**：pet alpha 轮廓堆雪（`fs_rasterize_pet`，工作块 B1）。温度驱动相变（snow↔water↔ice）已落地（`fs_apply_phase`）。**未落地**：像素级**窗口** alpha 轮廓碰撞（窗口仍按矩形遮挡）。

## 5. 关键数据流

### 5.1 启动流（同步 `@main`）

```text
OpenPetAgentApp.main (sync, on real main thread)
  ├─ AppBootstrap.makeLiveSnapshotSampler().sample()  // sync on main
  ├─ Task.detached { AppBootstrap(snapshot:).makeRootSystem() }
  │    ↳ orchestrator.bootstrap → CompanionBootstrap
  └─ semaphore.wait()
     ↓ now on a clean main thread
  launchReadyApp
     ↓
  NSApplication.shared.finishLaunching() + .run()
     ↓
  MinimalAppDelegate.applicationDidFinishLaunching
     ↓ start frame loop (DispatchSourceTimer on .main, 60 Hz)
```

### 5.2 桌宠位置流（每帧）

```text
DispatchSourceTimer (60 Hz)
  → MinimalAppDelegate.advanceRuntimeFrame
     ├─ DesktopSnapshotSampler.sample()
     │   (DisplayTracker, WindowTracker[100ms TTL], SpaceTracker, AX)
     ├─ rootSystem.runtimeTicker.tick(dt)
     │   → orchestrator.tick
     │     → RuntimeBridgeService.step
     │       → LocalRuntimeClient.step  // 纯 Swift: pet 追光标 candidate + contact_count
     │     → presentationMapper.map → behaviorEngine.behavior
     │
     ├─ if isFollowingEnabled:
     │   ├─ petMotionController.resolved(physicsCandidate, input)  // 运动仲裁(决策 D2)
     │   │   → frame.position(最终位置) + frame.phase(walking/idle/falling/perching)
     │   ├─ shellController.applyPetMotion(frame.phase)  // → renderer.updateForMotion
     │   └─ shellController.syncPetPosition(frame.position)
     └─ shellController.syncCompanionBehavior(.idle/.tracking/.snowing)
```

### 5.3 雪流（falling-sand 唯一路径）

```text
MinimalAppDelegate.advanceRuntimeFrame (per frame)
  ├─ rootSystem.runtimeTicker.tick(wantsParticles: false) → (renderState, snapshot)
  │   (LocalRuntimeClient 只算 pet pose + contact_count；雪走 GPU FS，不回传 particle buffer)
  ├─ if weatherEffectsEnabled:
  │   ├─ CollisionRect.collection(from: snapshot)
  │   │   (wallpaper filter + CGWindow top→bottom origin flip; front-to-back z-order)
  │   ├─ fallingSandRects(...)  // world px → FS cell 坐标遮挡矩形 (≤64)
  │   ├─ shellController.tickFallingSand(spawnSnow, spawnRain, ambient, rects)
  │   │     → MetalSnowOverlayView (driver.spawn/ambient/pendingRects + setNeedsDisplay)
  │   ├─ shellController.applyPetOccluder(enabled: isSnowEnabled, cellSize, originCell)  // B1
  │   │     → petRenderer.currentFrameAlphaMask → driver.pendingPetOccluder
  │   └─ shellController.applyPetSnowSweep(enabled, cellSize, originCell, velX=Δx/dt)  // B2
  │         → driver.pendingPetSweep → particles.petSweep*
  └─ MetalSnowOverlayView.draw → encodeFrame → FallingSandDriver.tick:
        emit 飞行粒子 → fs_integrate_particles(亚像素 + B2 pet 扬雪) → fs_particle_land(沉积到 CA)
        → uploadRects/uploadPetMask → CA step: fs_rasterize_occlusion(窗口遮挡)
        → fs_rasterize_pet(B1 pet 轮廓 OR 进遮挡) → clear_occluded(窗口+pet 内清)
        → claim/commit 移动 + 相变 + 升华 → 渲染两层(CA 积雪 + 粒子 instanced 软圆)
```

### 5.4 权限刷新流 + 天气坐标源选择

```text
// 权限刷新:设置窗口变为 key / onAppear → viewModel.onRefreshPermissions()
//   → SystemPermissionProbe 查四项实时态(AX/屏幕录制/位置/Apple Events)
//   → viewModel.permissionStatuses 更新 → SettingsPermissionsView 重渲染

// 天气坐标源(autoFollowLocation UD key):
//   autoFollowLocation=false(默认): WeatherStateManager 始终用 CityCatalog 城市坐标
//   autoFollowLocation=true + CL 已授权:
//     启动时: 城市坐标建 manager → start() → 异步取一次 CL 坐标 updateLocation(coord)
//     运行时开关: onCommitAutoFollowLocation(true)
//               → locationAdapter.requestAuthorization()
//               → locationAdapter.requestOneShotLocation { coord → manager.updateLocation(coord) }
//     关闭:    onCommitAutoFollowLocation(false)
//               → manager.updateLocation(CityCatalog 城市坐标)
```

## 6. 已知陷阱与设计教训

这一节锁住已经踩过的坑，每条对应回归测试。

### 6.1 `CGWindowList .optionOnScreenOnly` ≠「用户能看见」

`onScreen + layer == 0 + alpha >= 0.05` 仍然返回**被遮挡的窗口**、**DevTools 浮动面板**、layered popup。我们目前的应对：

- 把 wallpaper 全屏窗口过滤掉（`width >= worldWidth * 0.9 && height >= worldHeight * 0.9`）
- 遮挡是**纯 2D 矩形**：cell 落在**任意**窗口矩形内即被清除/阻挡（`fs_rasterize_occlusion`），**不看 z-order**。雪堆在窗口顶；浮动窗口**不**夹断其下方敞开的地面；但前景窗口**不会**阻止它视觉遮住的后方窗口顶上堆雪（CGWindowList z-order 仅保留在几何中、**不参与可见性判定**）。pet alpha 轮廓（`fs_rasterize_pet`，B1）作第二个 occluder OR 进同一 mask，每帧重清。
- `WindowTracker` 100ms TTL（关窗事件不可靠时强制重读）

回归：`clearsOccludedSnow`（`FallingSandGPUPhaseTests`）、`FallingSandPetOccluderTests`、`windowTrackerRefreshesVisibleWindowsAfterCacheLifetimeExpires`。

### 6.2 CGWindow top-origin vs runtime bottom-origin

CGWindow `bounds.y` 从屏幕顶向下增加，NSScreen / runtime y 从底向上增加。所有 collision 计算都要翻转：`bottomY = worldHeight - topY - height`。

回归：`runtimeBridgeFlipsTopOriginWindowBoundsIntoBottomOriginCollisionRects`。

### 6.3 `@main async` + `NSApplication.run()` 主队列失活

Swift `@main async` 把启动放进 Task，进入 `NSApplication.run()` 时主线程被 Task 占用——AppKit event 仍能 dispatch，但 `Timer.scheduledTimer` / `DispatchQueue.main.async` / `Task { @MainActor in ... }` 全部不被泵。

应对：`OpenPetAgentApp.main()` 同步入口，bootstrap 在 `Task.detached` 跑，主线程 `DispatchSemaphore.wait()`，最后纯净进入 `NSApplication.run()`。

回归：`minimalAppDelegateDefaultFrameLoopTicksWithoutRunLoopModeDependence`。

### 6.4 `MTKView` 默认 `isOpaque == true`

仅设 `clearColor` alpha=0 不够，`CAMetalLayer` 默认 opaque 会把内容涂黑。必须 `layer?.isOpaque = false` + `(layer as? CAMetalLayer)?.isOpaque = false`。

回归：`desktopOverlayViewHidesNSTextFieldSnowflakesWhenMetalLayerIsActive`。

### 6.5 `MTKView.drawableSize` 是物理像素，粒子是点

`drawableSize` 在 Retina 2x = `bounds.size * 2`。如果 vertex shader 拿 `drawableSize` 做 viewport，粒子 y=1100 会映射到 NDC ≈ 0（屏幕中段）而不是屏顶。要用 `bounds.size`（点）做 viewport，NDC 计算才跟粒子单位一致。

### 6.6 桌宠默认跟随光标 → 用户右键不到它

`MenuBarController.isFollowingEnabled` 默认 `false`，菜单栏 ❄ 状态项里可勾选；frame loop 在 `isFollowingEnabled == false` 时跳过 `syncPetPosition`。

回归：`minimalAppDelegateKeepsPetStationaryWhenFollowingDefaultsToOff`、`minimalAppDelegateFollowsCursorWhenMenuBarFollowingIsEnabled`。

### 6.7 ~~Swift FFI 链接 Rust 静态库依赖 cwd~~（已消除 2026-06-06）

原本 `Package.swift` 用相对路径链接 Rust `libweather_motion_runtime.a`,从子目录跑 swift 会 linker 报 `_wmr_step` undefined。**Rust 退役后此坑消失** —— 纯 Swift,`swift build` 一条命令全量构建,无 FFI 链接、无 cwd 依赖、无 cargo 预构建。

## 7. 演进策略

### 已经在做：GPU 物理通路落地

阶段 A（GPU compute 粒子模拟）已经默认开启，目标 4K 粒子。剩余工作：

- ~~收敛 Rust FFI 粒子数组冗余~~ → ✅ Rust 整体退役 2026-06-06；残留 Swift particle 字段待剥
- 验证 4K → 20K 粒子下 point sprite 是否还撑得住（fillrate / blend overdraw）
- compute kernel 调试与 ping-pong 同步稳定性

### 短期：把 Noita 级硬标准在 GPU 通路上落地

堆积层（falling-sand CA：列深 / 沉积 / 硬上限 `maxColumnDepth=24` / 三 pass 无锁流动）、相变（融/冻/蒸发/凝结 `fs_apply_phase`）、升华稳态、来自 Open-Meteo 实测 °C 的温度消费均已落地。仍真正未落地的两条：

- **窗口遮挡保真度**：当前是 sharp-corner 轴对齐矩形遮挡（`fs_rasterize_occlusion`，不识别 macOS 圆角、无 z-order）。分阶段提升：① 识别**圆角矩形**（四角按 corner-radius SDF 不计遮挡，性价比最高、先做）→ ② z-order 可见性（前景窗口挡住的后方窗口顶不堆雪）→ ③ ScreenCaptureKit 抓前景窗口 alpha 做**逐像素真实轮廓**。pet 轮廓 B1 已落地，差的是窗口侧
- **CA 网格风场 / 动态天气风**：粒子级风（`particles.windX = rainWindLean`）已被消费，但 **CA 网格风 `engine.windX` 在生产里恒为 0**（snow fall pass 强制 `windX:0`）；天气风速→FS 动态 wind 联动仍是 follow-up

### 中期：桌面交互能力

- 桌宠 ↔ 窗口弹球（依赖前面 occlusion 信号，已有）
- 真实可见窗口信号升级（不止 CGWindowList，加 AX 列窗口）
- Screen Capture + OCR 进 `Context`

### 长期：AI 助理升维

> LLM chat 闭环（OpenAI/Anthropic SSE 流式 + 持久化 + 桌面上下文注入 + 工具模式路由）已落地，不在未来工作里。旧 echo reply 现仅作**无状态兜底**——未配置 provider / store 时才回。

- 工具调用框架（窗口操作、文件、剪贴板、Apple 系应用）
- 桌面感知 → 主动建议（基于 AX / OCR / 活动模式）

## 8. 工程债务

- API key 仍存 UserDefaults，未迁 Keychain（见 §4 安全策略）

## 9. 历史决策（保留作背景）

### 9.1 为什么不是纯 Godot

OpenPetAgent 真正难的是「像系统一样活在桌面上」，不是「像游戏一样渲染一个角色」。Godot 不善于：

- 透明叠加层 + 点击穿透
- 多窗口桌面助手模型（overlay / pet / chat / 权限提示协作）
- 桌面感知与系统权限链路（Accessibility、Screen Capture、AppleScript、CoreLocation、WeatherKit、NSWorkspace、FSEvents）
- 长期会把「助手产品」做成「游戏壳套系统能力」

结论不是 Godot 不好，而是 Godot 更适合「游戏化表现层」，不适合做产品的总架构中心。

### 9.2 Big-bang rewrite 已收口（2026-05-08）

七阶段 big-bang rewrite 已经全部落地，详见 commit `c0abdfa`、`56e1c68`、`d6e19f0`。旧的 `Sources/Core/*`、`Sources/Plugins/{Snow,Obstacle}`、`Sources/LiquidFunWrapper/*`、`Sources/TaichiWrapper/*`、`Tests/OpenPetAgentTests/*` 已物理删除，仓库不再依赖 LiquidFun / Taichi / SpriteKit。当前主干完全由本文档第 3 节列出的 Swift 模块构成（Rust crate 已于 2026-06-06 退役）。

## 10. 代码组织（架构视角）

> 本节只描述本架构特有的拆分原则。

### 10.1 拆分必须对齐分层

文件归属必须对齐 §2 总体分层（Shell / Context / Orchestrator / RuntimeBridge / Rendering）。

- 跨层 helper 抽到**对应层**的子目录，不要塞进任意一层的"杂项"文件
- 一个文件不允许同时引入多于一层的概念（如：Shell 文件不直接调 FFI、Rendering 文件不直接读 AX 权限）
- 跨层数据契约只走 §4 列出的 FFI struct（`RuntimeInput` / `RuntimeOutput`）或 `DesktopSnapshot`，不要私通

### 10.2 ~~FFI 边界文件必须最薄~~（已不适用 2026-06-06）

原指 Rust FFI 入口文件(`ffi.rs`)只放 C ABI 声明 + POD struct,算法放子模块。**Rust 退役后无 FFI 边界** —— pet 运动纯 Swift(`LocalRuntimeClient`)。若将来引入 C++ 依赖(如 Live2D Cubism),此「桥接层最薄」原则仍适用于届时的 Swift/C++ interop 边界。

### 10.3 新模块的目录约定

- 一个新模块（plugin / subsystem）放在对应层的子目录下，**入口文件命名为模块名**：`Sources/<Layer>/<Module>/<Module>.swift`
- 模块内部按职责拆 ≥ 2 个文件：`<Module>.swift`（公开 API）+ `<Module>Internal.swift` / `<Module>State.swift` / `<Module>Renderer.swift`
- 测试镜像源码结构：`Tests/<Layer>Tests/<Module>Tests.swift`
