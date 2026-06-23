# Vendor/ — 第三方 vendored SDK

> 放**外部第三方 SDK 的本地副本**（当前仅 Live2D Cubism）：**参与编译的真实依赖**，但因许可限制不能走 SwiftPM、也不能入库。

## 能不能被 git 管理？——**不能（已 gitignore）**

`Vendor/Cubism/` 整个目录被 `.gitignore` 排除（`.gitignore:59`），**绝不入库**。原因见下「闭源/许可」。

- ✅ **入库的**：本 `Vendor/README.md`（`Vendor/` 目录本身没被忽略，只忽略 `Vendor/Cubism/`）。
- ❌ **不入库的**：`Vendor/Cubism/`（SDK 二进制 + 源）、`Sources/CubismCore/include/Live2DCubismCore.h`（setup 脚本从 SDK 拷的头，也算 SDK 内容）。

每个开发者**自己装自己的那份 SDK**（见下「怎么装」），所以仓库里只有这份说明、没有 SDK 本体。

## 是否安全？——**安全**

- 来源是 Live2D **官方** SDK（https://www.live2d.com/en/sdk/download/native/ ），开发者自行下载（需接受官方许可，免费）。不是来历不明的二进制。
- **无密钥 / 无敏感数据**：纯渲染 SDK（C API + C++ 框架 + Metal shader）。
- 不入库 → 不会把专有二进制误推上 GitHub、不会有许可/分发风险。
- `setup-cubism.sh` 只解压官方 zip 到本地，不执行网络/特权操作。

## 是否闭源？——**Cubism Core 是闭源专有，Framework 源码可见**

- **Cubism Core**（`Core/lib/libLive2DCubismCore.a` + `Core/include/*.h`）：Live2D **专有许可的预编译二进制**（闭源）。按 Live2D 官方许可免费使用，但**二进制不可随本仓库再分发** → 这是它必须 gitignore 的根本原因。许可全文见 SDK 内 `Core/LICENSE.md` / `Framework/LICENSE.md`（在 gitignored Vendor 里，装完可查）。
- **Cubism Framework**（`Framework/src/*.cpp`）：C++ 源码可见（但仍受 Live2D 许可约束，不入我们的仓）。

> 一句话：和哆啦A梦/动漫同人皮肤的 IP 风险同理 —— **专有、免费用、不可随我们的仓再分发**。

## 作用是什么？

让 PetAgent 能渲染 **Live2D 形象**（`.model3.json` Cubism 模型，如桌宠 hiyori）。没有它，app 照常 build + 运行，只是没有 Live2D 这种形象（Orb / sprite / Shimeji 不受影响）。

**编译链**（全是**根包** target，`Package.swift` 的 `if hasCubism` 块）：
```
CubismCore(C shim,暴露 Core C API)
  → CubismFramework(官方 C++ 框架源,Vendor/Cubism/Framework/src)
  → Live2DBridge(我们的 ObjC++ 门面,入库)
  → Live2D(Swift 后端 Live2DPetRenderer)  ──依赖──▶  Vivarium.Rendering(跨包)
```
`Package.swift` 顶部 `hasCubism = FileManager...exists(Vendor/Cubism/Core/lib/libLive2DCubismCore.a)` → 存在才编 Live2D 簇，不存在优雅跳过。

## 目录结构

| 子目录 | 内容 | 入库? |
|---|---|---|
| `Cubism/Core/{include,lib}` | Core C API 头 + macOS 静态库（闭源二进制） | ❌ gitignore |
| `Cubism/Framework/src` | Cubism Native Framework C++ 源 | ❌ |
| `Cubism/FrameworkMetallibs` | 预编译 Metal shader（`build-cubism-metallibs.sh` 产出） | ❌ |
| `Cubism/Samples/Hiyori` | 官方示例模型，`Live2DTests` 本地无头测 fixture | ❌ |

## 怎么装

```bash
# 1. 去 https://www.live2d.com/en/sdk/download/native/ 下 CubismSdkForNative-*.zip(接受许可,免费)
# 2. 解进 gitignored Vendor/Cubism/:
scripts/setup-cubism.sh ~/Downloads/CubismSdkForNative-*.zip
# (缺省自动找 ~/Downloads/CubismSdkForNative-*.zip)
# 3. 如需重建 Metal shader:
scripts/build-cubism-metallibs.sh
```
之后 `swift build` / `./install.sh` 自动检测并编进 Live2D。

## 为什么不迁进 `Packages/Vivarium`？

> （回应「Cubism 是否只被 Vivarium 引用、要不要迁过去」）

**不迁。** 调查结论：`Vendor/Cubism` **只被根包的 Cubism 簇引用**（`Package.swift` 的 `CubismCore`/`CubismFramework`/`Live2DBridge` target + `setup-cubism.sh`），**Vivarium 零引用 Vendor/Cubism**。

- Vivarium.Rendering 里确实有 `Live2DModelPackLoader` / `Live2DModelInstaller`，但它们是**SDK 无关**的（只扫 `*.model3.json` + 装 zip，不碰 Cubism），通过 `rendererFactory` 注入钩子在运行时接真渲染。
- 真正用 Cubism 的 `Live2DPetRenderer` + Cubism 簇在**根包**，因为 `Package.swift` 的 `Vendor/` 路径是 `pkgDir`-相对根包的，且 `hasCubism` 条件编译逻辑在根。
- 故 Vendor/Cubism 正确地与根包 Cubism 簇同处，**不属于 Vivarium 的依赖**。

**未来**：若把 Live2D 做成完整的 `VivariumRender` 后端（render 层重组时），可把 Cubism 簇 + `Vendor/Cubism` 一并移进 `Packages/Vivarium/`（含其内部的 `hasCubism` 条件）。那是个耦合的后续步骤，现在不做。
