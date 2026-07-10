// swift-tools-version: 5.9
import PackageDescription
import Foundation

// 工作块 D:Live2D 可选集成 —— Cubism SDK 是 Live2D 专有许可二进制,不入库(见 .gitignore)。
// 仅当 `Vendor/Cubism/`(开发者自跑 scripts/setup-cubism.sh 用自己下的官方 SDK 装)存在时,
// 才编进 `CubismCore` + `Live2D` target;不存在则优雅跳过 —— 没 SDK 的人 clone 照常 build,
// 只是没 Live2D 形象。这样 SDK 二进制永不进仓、每人用自己的 SDK、build 不被它卡住。
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasCubism = FileManager.default.fileExists(
    atPath: pkgDir + "/Vendor/Cubism/Core/lib/libLive2DCubismCore.a")

// App 依赖:有 Cubism 时加 Live2D(D-2.2b:App 启动注入 Live2DPetRenderer 工厂到 Rendering 的
// Live2DModelPackLoader.rendererFactory)。无 Cubism 时不依赖 → `#if canImport(Live2D)` 自动跳过。
var appDependencies: [Target.Dependency] = [.product(name: "Context", package: "Vivarium"), .product(name: "PetBehavior", package: "Vivarium"), "Shell", "Orchestrator", "AgentMode", "Weather", "Shimeji", "AgentSensing"]
if hasCubism { appDependencies.append("Live2D") }

var targets: [Target] = [
    .target(
        name: "Shell",
        // Orchestrator: BondedSession + QuickAsk 等需要 ConversationStore /
        //   replyStream 等 API。Weather: SettingsViewModel / WeatherSection 等
        //   需要 CityCatalog / WeatherConditionKind 等。
        //   debug build 能从 transitive 拿到, release build 严格必须显式声明。
        // AgentSensing: 统一陪伴卡片的 Claude Code/Codex tab 需 ConversationItem/AgentEvent 值类型
        //   (P3.2 会话流渲染)。AgentSensing deps=[] 纯 Foundation,单向无环;Shell 只用值类型与
        //   AgentConversation.build 纯变换,不做 tail/discovery(感知仍在 App 接线层驱动)。
        dependencies: [.product(name: "Context", package: "Vivarium"), .product(name: "RuntimeBridge", package: "Vivarium"), .product(name: "Rendering", package: "Vivarium"), "Orchestrator", "AgentMode", "Weather", .product(name: "ShimejiImport", package: "Vivarium"), .product(name: "PetCatalog", package: "Vivarium"), "AgentSensing"],
        path: "Sources/Shell",
        linkerSettings: [
            .linkedFramework("AppKit")
        ]
    ),
    .target(
        name: "AgentMode",
        dependencies: [],  // 暂不依赖其他模块, 单纯抽象层
        path: "Sources/AgentMode"
    ),
    // AgentSensing(P1):只读「感知外部 Claude Code / Codex 会话在干嘛」。
    // tail ~/.claude/projects/**/*.jsonl + ~/.codex/sessions/*.jsonl(transcript),
    // 解析成 AgentEvent / AgentActivityState。deps[](Foundation only)→ 不碰
    // settings.json、不起 server、与其它 hook 工具零冲突、好无头单测。映射成
    // 桌宠情绪(PetEmotionState)放 App/Shell 接线层,不让本 target 反依赖 Rendering。
    .target(
        name: "AgentSensing",
        dependencies: [],
        path: "Sources/AgentSensing"
    ),
    // 工作块 C/P4-B-5:Shimeji 原始帧引擎 ↔ app 的胶合层(ShimejiPetRenderer + DesktopEnvironmentProvider
    // + 窗口几何)。同时用 PetRenderer(Rendering)+ ShimejiMascotEngine(PetBehavior)+ AppKit 桌面态,
    // 故落 App 侧独立 target,不让 Vivarium/Rendering 反依赖 PetBehavior/JSC。
    .target(
        name: "Shimeji",
        dependencies: [
            .product(name: "Rendering", package: "Vivarium"),
            .product(name: "PetBehavior", package: "Vivarium"),
            .product(name: "Context", package: "Vivarium"),
        ],
        path: "Sources/Shimeji",
        linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(
        name: "ShimejiConvert",
        dependencies: [.product(name: "ShimejiImport", package: "Vivarium")],   // 工作块 C：CLI 薄壳，编排在 ShimejiPackConverter
        path: "Sources/ShimejiConvert"
    ),
    .target(
        name: "Weather",
        dependencies: [],  // Foundation only — 不引 WeatherKit / CoreLocation
        path: "Sources/Weather"
    ),
    .target(
        name: "Orchestrator",
        dependencies: [.product(name: "Context", package: "Vivarium"), .product(name: "RuntimeBridge", package: "Vivarium"), "AgentMode"],
        path: "Sources/Orchestrator",
        linkerSettings: [
            .linkedFramework("Security")
        ]
    ),
    .executableTarget(
        name: "App",
        dependencies: appDependencies,
        path: "Sources/App",
        linkerSettings: [
            .linkedFramework("AppKit")
        ]
    ),
    // ACP-1a 冒烟:用真 ACPStdioTransport spawn opencode acp,验证自写 client 真互操作。
    // swift run ACPSmoke "你的 prompt"
    .executableTarget(
        name: "ACPSmoke",
        dependencies: ["AgentMode"],
        path: "Sources/ACPSmoke"
    ),
    .testTarget(
        name: "AppTests",
        dependencies: ["App", .product(name: "Context", package: "Vivarium"), "Orchestrator"],
        path: "Tests/AppTests"
    ),
    .testTarget(
        name: "ShellTests",
        dependencies: ["Shell", "AgentMode", .product(name: "Context", package: "Vivarium"), .product(name: "RuntimeBridge", package: "Vivarium"), .product(name: "Rendering", package: "Vivarium"), "AgentSensing"],
        path: "Tests/ShellTests"
    ),
    .testTarget(
        name: "OrchestratorTests",
        dependencies: ["Orchestrator", .product(name: "Context", package: "Vivarium"), "AgentMode"],
        path: "Tests/OrchestratorTests"
    ),
    .testTarget(
        name: "AgentModeTests",
        dependencies: ["AgentMode"],
        path: "Tests/AgentModeTests"
    ),
    .testTarget(
        name: "WeatherTests",
        dependencies: ["Weather"],
        path: "Tests/WeatherTests"
    ),
    .testTarget(
        name: "AgentSensingTests",
        dependencies: ["AgentSensing"],
        path: "Tests/AgentSensingTests"
    ),
    .testTarget(
        name: "ShimejiTests",
        dependencies: ["Shimeji", .product(name: "PetBehavior", package: "Vivarium"), .product(name: "Context", package: "Vivarium")],
        path: "Tests/ShimejiTests"
    )
]

// 工作块 D:Vendor/Cubism 存在 → 编进 Live2D 相关 target。
// 分层:CubismCore(C 桥,D-0)→ CubismFramework(C++/ObjC++ 框架源,D-2.0)→
//       Live2DBridge(我们的 ObjC++ 门面,入库)→ Live2D(Swift)。
if hasCubism {
    targets += [
        .target(
            name: "CubismCore",
            // 我们的 shim(入库)暴露 Cubism Core C API 成模块;Core C 头由 setup 脚本拷进
            // include/(本地,gitignored),静态库在 gitignored Vendor。
            path: "Sources/CubismCore",
            linkerSettings: [
                .unsafeFlags(["-L\(pkgDir)/Vendor/Cubism/Core/lib", "-lLive2DCubismCore"])
            ]
        ),
        .target(
            name: "CubismFramework",
            // 官方 Cubism Native Framework C++ 源(gitignored Vendor,setup 脚本解入)。
            // 仅编核心框架 + Metal renderer,排除其它平台 renderer(D3D/GL/Vulkan)+ Metal
            // shader 源(.metal 由 D-2.2 metallib 管线单独编,非 SwiftPM 编)。
            dependencies: ["CubismCore"],
            path: "Vendor/Cubism/Framework/src",
            exclude: [
                "CMakeLists.txt",
                "Effect/CMakeLists.txt", "Id/CMakeLists.txt", "Math/CMakeLists.txt",
                "Model/CMakeLists.txt", "Motion/CMakeLists.txt", "Physics/CMakeLists.txt",
                "Type/CMakeLists.txt", "Utils/CMakeLists.txt",
                "Rendering/CMakeLists.txt",
                "Rendering/D3D9", "Rendering/D3D11", "Rendering/OpenGL", "Rendering/Vulkan",
                "Rendering/Metal/CMakeLists.txt", "Rendering/Metal/Shaders",
                "Rendering/CubismClippingManager.tpp",   // 模板,被 .hpp #include,非独立编译单元
            ],
            // 头在 src 根(非 include/);Live2DBridge 经 headerSearchPath 直接 #include,不经本
            // 模块。publicHeadersPath "." 满足 SwiftPM clang target 约定(模块从不被 import)。
            publicHeadersPath: ".",
            cxxSettings: [
                .headerSearchPath("."),                       // Framework/src(解析 "Math/..." 等)
                .headerSearchPath("../../Core/include"),       // Live2DCubismCore.h
                .unsafeFlags(["-fno-objc-arc"]),               // Cubism Metal renderer 要求关 ARC
            ],
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"), .linkedFramework("QuartzCore"),
            ]
        ),
        .target(
            name: "Live2DBridge",
            // 我们的 ObjC++ 门面(入库):公开头仅 Foundation,Swift 原生 import;.mm 内 #include
            // Cubism C++ 头驱动框架。D-2.0 仅 StartUp smoke,后续加模型加载 / Metal 渲染。
            dependencies: ["CubismFramework", "CubismCore"],
            path: "Sources/Live2DBridge",
            cxxSettings: [
                .headerSearchPath("../../Vendor/Cubism/Framework/src"),   // Cubism C++ 头
                .headerSearchPath("../../Vendor/Cubism/Core/include"),    // Live2DCubismCore.h
                .unsafeFlags(["-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"), .linkedFramework("Metal"),
                .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"),
            ]
        ),
        .target(
            name: "Live2D",
            // Live2D 形象后端(D-0 Core smoke + D-2.0 framework startup smoke;D-2.2 接 Metal renderer)。
            dependencies: [.product(name: "Rendering", package: "Vivarium"), "CubismCore", "Live2DBridge"],
            path: "Sources/Live2D"
        ),
        .testTarget(
            name: "Live2DTests",
            dependencies: ["Live2D"],
            path: "Tests/Live2DTests"
        ),
    ]
}

let package = Package(
    name: "OpenPetAgent",
    platforms: [.macOS("15.0")],   // P3.8:升 macOS 15 用原生 scroll API(defaultScrollAnchor/onScrollGeometryChange)重写会话流
    products: [
        .executable(name: "OpenPetAgent", targets: ["App"]),
        .executable(name: "shimeji-convert", targets: ["ShimejiConvert"])
    ],
    dependencies: [.package(path: "Packages/Vivarium")],
    targets: targets,
    // 工作块 D:Cubism Native Framework Metal sample 用 C++14(swift-cubism 同);仅影响
    // CubismFramework / Live2DBridge(无 Cubism 时无 C++ target,此设置无副作用)。
    cxxLanguageStandard: .cxx14
)
