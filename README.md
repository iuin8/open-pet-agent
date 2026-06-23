# OpenPetAgent 🏀

macOS 桌面 AI 物理沙盒桌宠 — 一颗与窗口交互、会造雪、能聊天的弹力球。纯原生 AppKit 壳层 + Metal GPU 渲染 + Swift 物理 runtime。

> 长期目标：从「桌宠」演进为 macOS 桌面级个人助理。当前已落地物理沙盒（GPU falling-sand 雪/雨 + 窗口感知碰撞）+ LLM 对话闭环 + 外部 AI agent（Claude Code / Codex）会话感知。

## ✨ 核心特性

### 🪟 桌面感知（AppKit）
- **三窗口模型**：全屏透明 overlay（点击穿透，承载雪粒子层）+ 桌宠球 `NSPanel`（可拖拽 / 右键）+ 附着旁侧的聊天浮层
- 窗口 / 光标 / 前台应用 / Active Space 全量 TTL 缓存、事件驱动，无轮询；跨 Space 自动跟随
- 前到后 z-order 感知遮挡，wallpaper 全屏窗口自动从碰撞集中过滤

### 🧊 物理沙盒（Metal GPU compute）
- **GPU falling-sand 唯一路径**：`fs_*` compute kernel —— 粒子积分 + 沉积 + 三 pass 无锁 CA + 相变 + 升华 + 窗口遮挡，全在 GPU 显存
- **遮挡感知 settle**：粒子只停在视觉上没被前面窗口盖住的窗口顶（z-order scan + per-column visibility）
- **pet 运动**：纯 Swift `LocalRuntimeClient`（朝光标追踪 + 接触计数）

### 🏀 弹力球（Metal SDF）
- Metal SDF + Fresnel 内部 metaball 流光，`CVDisplayLink` 驱动
- **速度向量 squash**：拖拽 / 反弹 / 自由落体 / 撞墙均触发各向异性形变
- 多态行为机，与 chat 状态（idle / listening / talking…）联动

### 💬 AI 助理（`LLMProvider` 抽象）
- **多 provider**：OpenAI 兼容（OpenAI / DeepSeek / Groq / Ollama）+ Anthropic 原生，运行时切换
- **流式 SSE 原生解析**（URLSession，无第三方依赖）
- **桌面上下文注入**：前台应用 + 窗口标题列表 + 光标九宫格自动进 system prompt（过滤掉 OpenPetAgent 自身）
- **工具模式**：`claude -p` / `codex exec` 子进程
- 入口：QuickAsk Spotlight 浮窗（⌥Space）+ pet 头顶 Bonded 气泡；对话持久化（rolling-window token 预算）

### 🛰️ 外部 Agent 感知
- 只读 tail `~/.claude/projects/**/*.jsonl` + `~/.codex/sessions/*.jsonl`，把 Claude Code / Codex 会话活动映射成桌宠情绪态（**不改 settings.json、不起 server、与其它 hook 工具零冲突**）

### 🍎 菜单栏
- 系统状态栏 ❄ 图标：跟随光标开关 / 启停雪 / 设置 / 退出

## 🚀 快速开始

```bash
# 1. clone（含 Vivarium 引擎子模块）
git clone --recurse-submodules https://github.com/iuin8/open-pet-agent.git
cd open-pet-agent

# 2. 一键 build + 签名 + 装到 /Applications + 启动（日常推荐）
./install.sh

# （备选）仅临时测试：
# swift build && swift run
```

**系统要求**：macOS 15+、Swift 5.9+、Xcode（含**免费** Apple Development 证书，用于签名让 TCC 权限稳定）。

> `./install.sh` 用 Apple Development 证书签名后，Accessibility / 截屏 / 位置权限永久稳定（重 install 不丢）；无证书时 fallback ad-hoc 签名 + 警告。证书生成步骤详见 [docs/signing-and-install.md](docs/signing-and-install.md)。完整构建 / 调试流程见 [docs/development-guide.md](docs/development-guide.md)。

### 权限

- **辅助功能**（必需）：用于读取前台窗口与遮挡感知。首次运行后到 *系统设置 → 隐私与安全性 → 辅助功能* 勾选 OpenPetAgent。
- LLM 调用前需要在 *菜单栏 → 设置* 配置 base URL / API key / model。

## 🎮 操作

| 动作 | 效果 |
|:---|:---|
| 拖拽小球 | 抓住、甩出，速度映射为 squash 形变 |
| ⌥ + Space | 全局热键，召唤 QuickAsk 输入框到鼠标位置 |
| 右键小球 | 菜单（显示聊天 / 下雪 / 退出） |
| 菜单栏 ❄ | 跟随光标开关、启停雪、设置 |
| 聊天输入 | 与 LLM 对话，reply 流式回填到桌宠头顶气泡 |

## 📁 架构

纯 Swift Package Manager 项目，无 Xcode workspace。引擎内核（物理 / 渲染 / 桥接 / 行为）抽成独立子模块 [Vivarium](https://github.com/iuin8/pet-agent-vivarium)。

```text
Sources/                       # app 壳层（本仓）
├── App/                       # @main 入口、frame loop、LLMProvider 装配
├── Shell/                     # 三窗口、菜单栏、Bonded 气泡链、⌥Space 热键
├── Orchestrator/              # CompanionOrchestrator、对话/凭证存储、OpenAI/Anthropic Provider
├── ToolMode/                  # claude / codex 子进程引擎抽象
├── AgentSensing/              # 只读感知外部 Claude Code / Codex 会话（transcript tail）
├── Weather/                   # 城市 / 天气配置
├── Shimeji/ ShimejiConvert/   # Shimeji 帧引擎胶合 + 导入 CLI
└── Live2D/ Live2DBridge/ CubismCore/   # 可选 Live2D（需自备 Cubism SDK，详见 Vendor/README.md）

Packages/Vivarium/Sources/     # 引擎子模块（独立公开仓）
├── Context/                   # 桌面快照（窗口/光标/Space/AX），TTL + 事件驱动
├── RuntimeBridge/             # pet 运动 runtime
├── Rendering/                 # Metal GPU 雪模拟 + SDF orb
├── SandboxPhysics/            # falling-sand CA
└── PetBehavior/ PetCatalog/ ShimejiImport/   # 行为 / 编目 / Shimeji 导入
```

完整分层、数据流、已知陷阱见 [docs/architecture.md](docs/architecture.md)；当前已落地功能见 [docs/features.md](docs/features.md)。

## 🧪 测试

```bash
swift test                                      # 根包（壳层 / 编排 / 感知 / 天气 / …）
swift test --package-path Packages/Vivarium     # 引擎子包（物理 / 渲染 / 桥接 / 行为 / …）
```

均使用 Swift Testing（`@Test` / `#expect`）。

## 🤝 贡献

欢迎 issue 与 PR。这是一个还在快速演进的项目——物理沙盒离 Noita 级还有差距、智能助理层刚起步，有大量可参与的方向。第三方代码归属见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

## 📄 License

[MIT](LICENSE)
