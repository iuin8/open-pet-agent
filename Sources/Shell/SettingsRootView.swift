import SwiftUI

/// 设置面板顶层 SwiftUI 视图 — macOS Sonoma 系统设置风格:
/// - 左侧 ~156pt 侧栏分类列表(5 类)
/// - 右侧 ScrollView 详情区(GroupBox 卡片) + 底部 safeAreaInset 按钮行
///
/// **架构注**:跟 HermesPet `SettingsView` 同款路线,采用 `HStack` + 固定
/// `.frame` 而非 `NavigationSplitView`。理由:
/// 1. `NavigationSplitView` 在 macOS 13 上会主动请求 NSWindow 调 frame,
///    跟我们要塞进 floating `NSPanel` (`styleMask: [.titled, .closable]`)的
///    固定 contentRect 不兼容,容易触发 HermesPet 决策 #1/#6 同款"NSHostingView
///    反推 setFrame → 嵌套 layout 崩"。
/// 2. 设置面板尺寸固定 620×480,不需要 split view 的 resize 行为。
@MainActor
struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var selectedCategory: Category = .backend
    /// 「桌宠库」overlay 卡片是否展开(顶层 ZStack 弹出;点暗背景空白处 / Esc 关)。
    @State private var showingLibrary = false

    enum Category: String, CaseIterable, Identifiable {
        case backend, persona, pet, weather, tool, proactive, debug, system, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .backend:   return "AI 后端"
            case .persona:   return "人格"
            case .pet:       return "桌宠"
            case .weather:   return "天气"
            case .tool:      return "外部 Agent"
            case .proactive: return "主动协助"
            case .debug:     return "调试"
            case .system:    return "系统"
            case .about:     return "关于"
            }
        }
        var icon: String {
            switch self {
            case .backend:   return "cpu"
            case .persona:   return "person.text.rectangle"
            case .pet:       return "pawprint.fill"
            case .weather:   return "cloud.sun.fill"
            case .tool:      return "wrench.and.screwdriver.fill"
            case .proactive: return "brain.head.profile"
            case .debug:     return "slider.horizontal.below.square.filled.and.square"
            case .system:    return "gearshape.fill"
            case .about:     return "info.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .backend:   return .blue
            case .persona:   return .teal
            case .pet:       return .pink
            case .weather:   return .cyan
            case .tool:      return .orange
            case .proactive: return .indigo
            case .debug:     return .purple
            case .system:    return .gray
            case .about:     return Color(white: 0.55)
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
            if showingLibrary {
                // 暗背景:点空白处退出(modeless,无「完成」按钮)。覆盖整窗,NSOpenPanel 导入不受影响。
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { showingLibrary = false }
                PetLibraryView(viewModel: viewModel, isPresented: $showingLibrary)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: 640, height: 520)
        .animation(.easeOut(duration: 0.15), value: showingLibrary)
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Category.allCases) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: cat.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                selectedCategory == cat ? .white : cat.color
                            )
                            .frame(width: 18)
                        Text(cat.label)
                            .font(.system(size: 13))
                            .foregroundStyle(
                                selectedCategory == cat ? .white : .primary
                            )
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        if selectedCategory == cat {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 156)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    // MARK: - 详情区

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selectedCategory.label)
                    .font(.system(size: 21, weight: .semibold))
                    .padding(.top, 2)

                Group {
                    switch selectedCategory {
                    case .backend:   SettingsBackendSection(viewModel: viewModel)
                    case .persona:   SettingsPersonaSection(viewModel: viewModel)
                    case .pet:       SettingsPetSection(viewModel: viewModel, showingLibrary: $showingLibrary)
                    case .weather:   SettingsWeatherSection(viewModel: viewModel)
                    case .tool:      SettingsAgentSection(viewModel: viewModel)
                    case .proactive: SettingsProactiveSection(viewModel: viewModel)
                    case .debug:     SettingsDebugSection(viewModel: viewModel)
                    case .system:    SettingsSystemSection(viewModel: viewModel)
                    case .about:     SettingsAboutSection(viewModel: viewModel)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Modeless(macOS Ventura+「系统设置」范式):无「保存」按钮,改动即时生效并持久化。
        // 关窗走 ⌘W / Esc / 标题栏关闭按钮(controller 在 windowWillClose flush LLM 文本框)。
    }
}
