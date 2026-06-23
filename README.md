# OpenPetAgent 🐾

> 一只住在 macOS 桌面上的 AI 伴侣 —— **可换装**、懂你在干嘛、会造雪下雨、能聊天，还能感知 Claude Code / Codex 正在跑什么。

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Metal](https://img.shields.io/badge/GPU-Metal-1a73e8)
![License MIT](https://img.shields.io/badge/license-MIT-blue)

OpenPetAgent 是一个**纯原生 macOS 桌宠平台**：AppKit 壳层 + Metal GPU 渲染/物理 + Swift runtime，零跨平台抽象。它不是「一颗写死的弹力球」——而是一个 `PetRenderer` 协议之上的**可插拔多形象平台**：弹力球只是默认皮肤，你可以随时换成史莱姆、Codex/petdex 精灵宠物、Shimeji 看板娘，或 Live2D 模型。在此之上，它叠了**桌面感知 + GPU 物理沙盒 + LLM 对话 + 外部 Agent 感知**四层能力。

> 长期目标：从「桌宠」演进为 macOS 桌面级个人助理。

## ✨ 一眼看懂

- 🧩 **可换装多形象**：一个 `PetRenderer` 协议，五种已落地形象，运行时热切换——弹力球只是其中之一。
- 🛒 **一键装社区宠物**：应用内直连 [petdex](https://petdex.crafter.run) 社区库一键安装；拖入 Shimeji 包 / Live2D 模型即可导入。
- 🧊 **GPU falling-sand 雪/雨物理**：每粒亚像素积分、堆积、相变（融雪/结冰/蒸发），随实时天气联动，约 3ms/帧。
- 🪟 **桌面感知**：前台应用 + 窗口标题 + 光标方位实时注入 LLM，让它知道「你正在看什么」。
- 🛰️ **外部 Agent 感知**：只读 tail Claude Code / Codex 的会话日志，把它们的活动映射成桌宠情绪——**零侵入**，不装 hook、不改 settings.json、不起服务。
- 💬 **多 provider LLM**：OpenAI 兼容 + Anthropic 原生，运行时热切换，无第三方依赖的流式 SSE。

## 🧩 可换装的桌宠平台

核心是一个 `PetRenderer` 协议 + `PetPluginRegistry` 注册表，`DesktopShellController.replacePetRenderer` 在运行时热切换形象。**当前已落地五种形象**：

| 形象 | 实现 | 说明 |
|:---|:---|:---|
| 🏀 **Orb 弹力球**（默认） | `OrbMetalRenderer`（Metal SDF） | Fresnel 内部 metaball 流光 + 速度向量各向异性 squash + 5 态情绪 |
| 🫠 **Slime 史莱姆** | `SlimeMetalRenderer`（Metal SDF） | 独立情绪映射与招牌动作 |
| 🎞️ **Codex / petdex 精灵** | `SpriteSheetPetRenderer` | 播放 8×9 spritesheet（`pet.json` 格式），自动发现 `~/.petagent/pets/codex/` 与 `~/.codex/pets/` |
| 🧸 **Shimeji 看板娘** | `ShimejiPetRenderer` + 行为引擎 | 真行为图引擎：走/落/坐/爬墙、抓起甩出、多宠拥抱互动 |
| 🎀 **Live2D 模型** | `Live2DPetRenderer`（Cubism Metal） | 待机动作/呼吸/眨眼/物理摆动 + 情绪驱动动作（需自备 Cubism SDK，见下） |

**桌宠库与社区生态**：

- **桌宠库 GUI**（设置 → *管理桌宠库…* → `PetLibraryView`）：分类网格、缩略图、即时切换、删除确认、搜索；每只宠物可单独缩放 0.5×–2.0×。
- **社区一键获取**（*获取社区桌宠…* → `CommunityPetsSheet`）：直连 petdex 在线库下载安装，含 Codex / Shimeji 分页。
- **拖拽导入**：把 Shimeji `.zip`/文件夹或 Live2D 模型包拖进桌宠库即自动转换安装；命令行另有 `shimeji-convert` 工具。
- **多宠同屏**：选一只主宠，再把若干 Shimeji 作为「装饰伙伴」一起漫步。
- **安全下载**：可信主机白名单（防 SSRF）+ 防盗链 Referer + 退避重试 + 路径穿越净化，每个下载包都过一遍。

> **Live2D 是可选项**：Cubism SDK 为专有许可，不随仓库分发。想用 Live2D 形象需自备官方 [Cubism SDK for Native](https://www.live2d.com/en/sdk/download/native/) 后运行 `scripts/setup-cubism.sh`；不安装时 `swift build` 会优雅跳过 Live2D，其余形象与功能照常。诚实边界：Live2D 暂不做假口型同步（接入 TTS 音频后再驱动）。

## 🪟 桌面感知（AppKit）

- **三窗口模型**：全屏透明 overlay（点击穿透，承载雪粒子层）+ 桌宠 `NSPanel`（可拖拽 / 右键）+ 锚定在桌宠旁的对话卡片（`ChatCardWindowController`）。
- **零轮询**：窗口列表 100ms TTL 缓存 + `NSWorkspace`/AX 事件硬失效；显示器/Space 仅在系统通知时重算。全部依赖注入，可脱离真实桌面单测。
- **跨 Space 自动跟随**；wallpaper 级全屏窗口自动从碰撞集中过滤；CGWindowList 前到后 z-order 端到端保留并喂给 GPU 雪遮挡。
- **看你在干嘛**：前台应用 + 可见窗口（属主 + 标题，按 z-order、限额预算）+ 光标九宫格方位注入 LLM system prompt，且把 OpenPetAgent 自身按 PID 与名字过滤两遍。

## 🧊 物理沙盒（Metal GPU compute）

- **GPU falling-sand 唯一路径**：亚像素飞行粒子（重力 + 风）落地沉积进双缓冲 CA 网格；三 pass 无锁 CA（重力 + 左右流动，原子预约）+ 相变（融雪/结冰/蒸发/凝结）+ 升华深度反馈（自限稳态雪深）+ 逐列硬上限防爆堆。
- **遮挡感知 settle**：雪堆在窗口顶部与桌宠**真实 alpha 轮廓**上；悬浮窗下方的开阔地照常落雪；窗口移动 / 关闭 / 切 Space 时逐帧重新评估，立刻掉雪。
- **温度联动**：消费实时 Open-Meteo 天气 °C，驱动屏上积雪融化 / 结冰 / 升华；另有雨水积洼、溅射、倾斜与湿润反光。
- 约 3ms/帧（1px 分辨率），另带一套 CPU 参考模拟做确定性单测。

> **诚实标注**：当前遮挡是逐格**矩形**遮挡（被前景窗口盖住的后方窗口顶仍会落雪，暂不做前后 z-order 可见性判定）；距项目自设的 Noita 级硬标准仍有差距——缺逐像素窗口轮廓碰撞、CA 栅格风场（仅 particle 级风生效）、空间变化的温度场。详见 [docs/architecture.md](docs/architecture.md)。

## 💬 AI 助理（`LLMProvider` 抽象）

- **多 provider**：OpenAI 兼容（OpenAI / DeepSeek / Groq / Ollama，改 base URL 即可）+ Anthropic 原生，设置里运行时切换，**改完下一条消息即生效，无需重启**。
- **无第三方依赖的流式 SSE**：手写在 `URLSession.bytes` 上，用 `Data` 缓冲按事件切分，跨 HTTP 分块保住多字节 UTF-8（中文不乱码）。
- **工具模式**：把整条 prompt 交给 `claude -p`（stream-json）或 `codex exec`（json）子进程，带看门狗超时、取消即 SIGTERM、进程注册表清理。
- **对话持久化**：原子写 + `.bak` 损坏恢复 + 滚动窗口 token 预算（按 model 估算上下文窗口，不拆散一问一答）。
- 入口：⌥Space 召唤锚定在桌宠旁的多轮对话卡片；⌘⇧Space 带当前选中文本快问、预填到同一张卡片；桌宠头顶另有 Bonded 流式气泡。

## 🛰️ 外部 Agent 感知

只读 tail `~/.claude/projects/**/*.jsonl` 与 `~/.codex/sessions/**/rollout-*.jsonl`（递归，仅读新追加的字节、从不回放历史），把 Claude Code / Codex 的会话活动映射成桌宠情绪态（写代码→工作、读文件→审阅、报错→沮丧、等输入→等待、完成→庆祝）。**默认开启，纯文件读取**——不注册 hook、不改 `settings.json`、不起常驻服务，与其它 hook 工具零冲突。

> 注：另有一个**默认关闭**的「在卡片上回答权限」功能会起本地回环服务并写入 `settings.json`，与上述只读感知是两个相互独立的特性。

## 🍎 菜单栏

系统状态栏 ❄ 图标，菜单含：跟随光标、桌面漫游、感知编码会话、在卡片上回答权限 / 问题、交互时冻结 pet、打开聊天浮窗、截图分享、设置…、**天气子菜单**（关闭 / 自动 / 强制 sunny·cloudy·rainy·snowy·windy + 立即清除积雪）、退出。

## 🚀 快速开始

**系统要求**：macOS 15+（会话流用原生 scroll API）、Apple Silicon（release 为 arm64）、Swift 5.9+ / Xcode。

### 方式 A：下载预编译版本（GitHub Releases）

预编译 `.app` 未经 App Store 公证，首次启动会被 Gatekeeper 拦下——清掉隔离属性即可：

```bash
# 1. 从 Releases 下载并解压
unzip OpenPetAgent.zip

# 2. 拖进 /Applications（或用命令行）
mv OpenPetAgent.app /Applications/

# 3. 清除 Gatekeeper 隔离属性（-r 因为 .app 是目录包，-d 删除该属性）
xattr -dr com.apple.quarantine /Applications/OpenPetAgent.app

# 4. 启动
open /Applications/OpenPetAgent.app
```

> 也可在访达里右键 `OpenPetAgent.app` → **打开** → 在弹窗里再点「打开」，效果等同（系统会记下这次放行）。

### 方式 B：从源码构建（开发推荐）

```bash
# clone 时务必递归拉子模块（Vivarium 引擎是 submodule，否则 Packages/Vivarium 为空、build 失败）
git clone --recurse-submodules https://github.com/iuin8/open-pet-agent.git
cd open-pet-agent

# 一键 build + 签名 + 装到 /Applications + 启动
./install.sh

# （备选）仅临时验证：swift build && swift run
```

> `./install.sh` 用**免费** Apple Development 证书签名后，Accessibility / 截屏 / 位置权限永久稳定（重 install 不丢，因为 TCC 认 TeamID+BundleID 而非每次变的 CDHash）；无证书时退回 ad-hoc 签名 + 警告。证书生成与签名细节见 [docs/signing-and-install.md](docs/signing-and-install.md)，完整构建 / 调试流程见 [docs/development-guide.md](docs/development-guide.md)。

### 权限

- **辅助功能**（必需）：读取前台窗口与遮挡感知。首次运行后到 *系统设置 → 隐私与安全性 → 辅助功能* 勾选 OpenPetAgent。
- **屏幕录制**：桌面快照与窗口标题感知需要。
- **LLM**：调用前在 *菜单栏 → 设置* 配置 base URL / API key / model（热重载，无需重启）。

## 🎮 操作

| 动作 | 效果 |
|:---|:---|
| 拖拽桌宠 | 抓住、甩出；Orb/Slime 速度映射为各向异性 squash，Shimeji 触发抓起动作 |
| ⌥ + Space | 召唤锚定在桌宠旁的多轮对话卡片 |
| ⌘ + ⇧ + Space | 带当前选中文本快问，预填到同一张卡片 |
| 右键桌宠 | 菜单：显示聊天 / 截图分享 / 设置 / 跟随光标 / 桌面漫游 / 天气 / 退出 |
| 菜单栏 ❄ | 跟随光标、桌面漫游、感知编码会话、天气子菜单、设置…等 |
| 管理桌宠库… | 切换 / 导入 / 删除 / 搜索宠物，一键装社区宠物 |

## 📁 架构

纯 Swift Package Manager 项目，无 Xcode workspace。引擎内核（物理 / 渲染 / 桥接 / 行为 / 编目）抽成独立公开子模块 [Vivarium](https://github.com/iuin8/pet-agent-vivarium)。

```text
Sources/                       # app 壳层（本仓）
├── App/                       # @main 入口、frame loop、LLMProvider 装配、多宠编排
├── Shell/                     # 三窗口、菜单栏、对话卡片、桌宠库 UI、⌥Space 热键
├── Orchestrator/              # CompanionOrchestrator、对话/凭证存储、OpenAI/Anthropic Provider
├── ToolMode/                  # claude / codex 子进程引擎抽象
├── AgentSensing/              # 只读感知外部 Claude Code / Codex 会话（transcript tail）
├── Weather/                   # 城市 / 天气配置
├── Shimeji/ ShimejiConvert/   # Shimeji 帧引擎渲染器 + 导入 CLI
└── Live2D/ Live2DBridge/ CubismCore/   # 可选 Live2D 形象（需自备 Cubism SDK）

Packages/Vivarium/Sources/     # 引擎子模块（独立公开仓）
├── Context/                   # 桌面快照（窗口/光标/Space/AX），TTL + 事件驱动
├── RuntimeBridge/             # pet 运动 runtime
├── Rendering/                 # PetRenderer 协议 + Orb/Slime/Sprite 渲染器 + Metal GPU 雪
├── SandboxPhysics/            # falling-sand CA 引擎
├── PetCatalog/                # 在线宠物库客户端 + 安全安装器（petdex）
└── PetBehavior/ ShimejiImport/   # 行为图 / Shimeji 导入转换
```

完整分层、数据流、已知陷阱见 [docs/architecture.md](docs/architecture.md)；当前已落地功能见 [docs/features.md](docs/features.md)。

## 🧪 测试

```bash
swift test                                      # 根包（壳层 / 编排 / 感知 / 天气 / Shimeji / …）
swift test --package-path Packages/Vivarium     # 引擎子包（物理 / 渲染 / 桥接 / 行为 / 编目 / 导入）
```

均使用 Swift Testing（`@Test` / `#expect`）。`Live2DTests` 仅在自备 Cubism SDK 后才会编入。

## 🤝 贡献

欢迎 issue 与 PR。这是一个还在快速演进的项目——物理沙盒离 Noita 级还有差距、智能助理层刚起步、桌宠平台还能接更多形象后端，有大量可参与的方向。第三方代码归属见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

## 📄 License

[MIT](LICENSE)
