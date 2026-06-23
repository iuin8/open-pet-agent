# 签名与安装(TCC 权限稳定)

OpenPetAgent 涉及 Accessibility(前景窗口探测)/ 截屏 / 位置等 macOS TCC 权限。
不正确签名会导致 **每次重 build 后权限失效要重弹授权**,严重打断开发体验。
本文档记录如何配置签名让权限永久稳定。

借鉴 HermesPet (https://github.com/basionwang-bot/HermesPet) 决策 #4:**TCC 不认 CDHash,
认 (TeamID + BundleID)**。

> OpenPetAgent 是**可插拔的多形态桌宠平台**(默认 Orb 弹力球 + Slime + Codex/petdex sprite + Shimeji + 可选 Live2D),
> 弹力球只是默认皮肤。无论装哪个版本,签名/权限的逻辑都一样。

## macOS 版本要求

最低 **macOS 15.0**(由 `Package.swift` 与 `Info.plist` 的 `LSMinimumSystemVersion 15.0` 锁定)。

## 安装预编译版本(从 GitHub Releases)

不想从源码构建可直接下 Releases 里的 `OpenPetAgent.zip`。注意:**预编译 `.app` 没有走 App Store
公证(notarization)**,只做了 ad-hoc 或 Apple Development 本地签名 → 首次打开会被 Gatekeeper
拦下(隔离属性 `com.apple.quarantine`),需手动放行一次:

```bash
# 1. 从 Releases 下载并解压
unzip OpenPetAgent.zip
# 2. 拖进 /Applications（或命令行）
mv OpenPetAgent.app /Applications/
# 3. 清除 Gatekeeper 隔离属性（-r 因为 .app 是目录包，-d 删除该属性）
xattr -dr com.apple.quarantine /Applications/OpenPetAgent.app
# 4. 启动
open /Applications/OpenPetAgent.app
```

不想用命令行也行:**访达里右键 `OpenPetAgent.app` → 打开 → 弹窗里再点「打开」**,系统会记住放行。

启动后到 **系统设置 → 隐私与安全性** 授予 **辅助功能(Accessibility)** 与 **屏幕录制(Screen Recording)**
权限(窗口标题 `kCGWindowName` 需要屏幕录制)。预编译版的权限稳定性取决于打包时用的签名:
Apple Development 证书签的 → 永久稳定;ad-hoc 签的 → 重装可能重弹(见下文)。

---

以下是**从源码构建**的流程。

## 三种签名状态对比

| 签名方式 | 命令 | 权限稳定性 |
|---|---|---|
| **无签名 / `swift run` 裸 binary** | `swift run` | ❌ 每次 build CDHash 变 → 每次启动重弹权限 |
| **ad-hoc 签名** | `codesign --sign -` | ⚠️ 比 unsigned 稳一些,但 CDHash 仍每次变,可能重弹 |
| **Apple Development 证书签名(推荐)** | `codesign --sign "Apple Development: ..."` | ✅ TCC 认 (TeamID + BundleID),CDHash 变也认得 → **永久稳定** |

## 配置 Apple Development 证书(一次性,5 分钟)

**完全免费**。不需要 Apple Developer Program($99/年)— 用任何 Apple ID 都能
通过 Xcode 生成 Apple Development 证书。

### 步骤(Xcode 14+ / 26+ 都适用)

1. **Xcode → Settings**(`⌘,`)→ **Accounts** tab
2. 左下 **+** → **Apple ID** → 用任何 Apple ID 登录(可用现有 iCloud 账号)
3. 登录后**点中左栏那一行 Apple ID** → 右侧主面板列你的 Teams
4. **选中其中一个 Team 行** → 右下角 **Manage Certificates...** 按钮
5. 弹窗左下 **+** → **Apple Development**
6. 完成 → 关 Xcode

### 验证证书已装

```bash
security find-identity -v -p codesigning
```

应输出类似:

```
1) D5909D48F7BE22C6B64144DE769F665BEEB2AD78 "Apple Development: youremail@example.com (TEAMID)"
   1 valid identities found
```

### Xcode 26 找不到 Manage Certificates 按钮?

Apple 偶尔会在 Xcode 新版调整 Settings UI。备用路径:

1. **Xcode → File → New → Project** → macOS → App
2. 填 Product Name = `TempForCert`,Team 选你的 Apple ID Personal Team
3. 保存到 `/tmp/` → 打开项目 → 左侧选项目 → **Signing & Capabilities** tab
4. 勾 ✅ **Automatically manage signing** → Xcode 自动联网申请 Apple Development 证书
5. 完成后看到 `Signing Certificate: Apple Development: ...` → 关 Xcode → `/tmp/TempForCert` 可以删
6. 跑 `security find-identity -v -p codesigning` 验证

## 从源码构建

> **必须递归 clone 子模块**:运动/行为/渲染等核心在 `Packages/Vivarium`(git 子模块)。
>
> ```bash
> git clone --recurse-submodules <repo-url>
> # 已经普通 clone 过的话补一句:
> git submodule update --init --recursive
> ```

### 可选:Live2D 形象(需 Cubism SDK)

Live2D 依赖 Live2D Cubism SDK,**专有许可、已 gitignore、不随仓库/发布分发**。需要 Live2D 形象的用户
自行用 `scripts/setup-cubism.sh` 安装(它落到 `Vendor/Cubism/`,其中
`Vendor/Cubism/Core/lib/libLive2DCubismCore.a` 是构建时是否启用 Live2D 的开关文件)。
**干净 clone 不装 Cubism 也能正常 build/运行**,只是 Live2D 形象渲染为占位(Orb / Slime / sprite / Shimeji 不受影响)。
预编译 `.app` 仅当打包者构建时本机有 Cubism SDK 才内置 Live2D。

### 一键 build + 装 + 启动

```bash
./install.sh
```

内部步骤:

1. `./build.sh` — `swift build -c release --arch arm64`(仅 arm64)→ 手工拼 `OpenPetAgent.app` bundle
   (拷 binary + `Info.plist` + `PkgInfo`;若 `Vendor/Cubism/FrameworkMetallibs/*.metallib` 存在则一并拷进
   `Contents/Resources/FrameworkMetallibs/`)→ 清扩展属性(`find OpenPetAgent.app -exec xattr -c {} +`
   再针对性 `xattr -d com.apple.FinderInfo` / `xattr -d 'com.apple.fileprovider.fpfs#P'`)→
   `codesign --force --deep` 优先用 Apple Development 证书签名(检测不到则 fallback ad-hoc)
2. `pkill -x OpenPetAgent` 退出当前在跑的版本
3. `cp -R OpenPetAgent.app /Applications/OpenPetAgent.app`
4. `open /Applications/OpenPetAgent.app`
5. 显示签名 authority — 看到 "Apple Development:" 开头就是成功的稳定签名

### 仅构建不安装

```bash
./build.sh
```

产物在项目根目录 `OpenPetAgent.app`。可以 `open OpenPetAgent.app` 直接运行,不影响
`/Applications` 里的版本。

### 临时验证(`swift run`)

```bash
swift build && swift run
```

debug binary 在 `.build/arm64-apple-macosx/debug/OpenPetAgent`,**没签名 → 每次
build CDHash 变 → Accessibility 权限会重弹**。仅适合短时调试,不推荐日常用。

## 没 Apple Development 证书时

`build.sh` 检测不到证书时 fallback ad-hoc 签名 + 警告(实际打印,见 `build.sh:84-87`):

```
🔐 未找到 Apple Development 证书,退回 ad-hoc 签名
   ⚠️  每次重 build 后 CDHash 变,可能需要重新授权 Accessibility/截屏
   💡 免费配置 (5 分钟,任意 Apple ID 即可,不需付费 $99 Developer Program):
      详见 docs/signing-and-install.md
```

仍可正常启动 OpenPetAgent.app,只是权限不稳定。强烈建议补上 Apple Development 证书。

## 调试签名问题

### 查看 .app 当前签名

```bash
codesign -dvvv /Applications/OpenPetAgent.app 2>&1 | grep -E "Identifier|Authority|TeamIdentifier"
```

预期输出(签名稳定时):

```
Identifier=io.openpetagent
Authority=Apple Development: youremail@example.com (TEAMID)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=XXXXXXXXXX
```

`Authority=Apple Development: ...` 是关键 — 没有这行 = ad-hoc 签名 = 权限不稳定。

### `codesign` 报 "resource fork / Finder information not allowed"

原因:`.app` 内部有扩展属性(xattr),通常是 iCloud Drive 自动加的
`com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P`。

`build.sh` 已经自动处理(3 次重试 clean + sign),如果仍失败:

```bash
find OpenPetAgent.app -exec xattr -c {} +
xattr -d com.apple.FinderInfo OpenPetAgent.app
xattr -d 'com.apple.fileprovider.fpfs#P' OpenPetAgent.app
./build.sh
```

### 系统设置 → 隐私与安全性 → Accessibility 有"死掉"的旧条目

如果之前给 `.build/.../OpenPetAgent`(ad-hoc 路径)授权过,系统设置里可能有指向
旧 binary 的 Accessibility 条目。手动删除:

1. **系统设置 → 隐私与安全性 → 辅助功能**
2. 找到指向 `.build/...` 路径的 OpenPetAgent 条目
3. 选中 → 左下 **-** 删除
4. 重启 OpenPetAgent.app,弹新的授权请求,授权一次后永久稳定

## 证书过期

免费的 Apple Development 证书有效期 **1 年**。到期前 Xcode 会自动提示续签,
**5 秒 1 个按钮搞定**,不影响日常用。续签后 TeamID 不变 → TCC 权限继续认。

## 完整 build pipeline 参考

- `build.sh` — 单纯 build + 签名 + 不装
- `install.sh` — `./build.sh` + 装 `/Applications` + 启动
- `Info.plist` — Bundle ID `io.openpetagent`,LSUIElement=true(无 Dock
  icon,仅菜单栏 + 桌面层 pet/灵动岛)
- HermesPet (https://github.com/basionwang-bot/HermesPet) `build.sh` / `install.sh` — 同款架构,
  OpenPetAgent 借鉴
