import SwiftUI

// MARK: - OnboardingStartersView

/// 开箱推荐卡：首次启动空社区库时展示，引导用户安装火柴人或哆啦 A 梦。
///
/// 设计原则：
/// - 纯回调式（dumb view），不持有任何业务状态，调用方完成所有副作用。
/// - 不 bundle 任何版权图片，用 SF Symbol 占位 + 文案说明。
@MainActor
public struct OnboardingStartersView: View {

    /// 用户点击「选火柴人」→ 打开 CommunityPetsSheet Shimeji tab。
    public var onSelectShimeji: () -> Void
    /// 用户点击「选哆啦」→ 打开 CommunityPetsSheet Codex tab。
    public var onSelectCodex: () -> Void
    /// 用户点击「以后再说」→ 写 UD dismissed + 关闭面板。
    public var onDismiss: () -> Void

    public init(
        onSelectShimeji: @escaping () -> Void,
        onSelectCodex: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSelectShimeji = onSelectShimeji
        self.onSelectCodex = onSelectCodex
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleSection
            Divider().padding(.horizontal, 16)
            tilesSection
            footerSection
        }
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 6)
    }

    // MARK: 标题区

    private var titleSection: some View {
        VStack(spacing: 4) {
            Text("开箱推荐")
                .font(.title3).fontWeight(.semibold)
            Text("装一只桌宠开始")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: 两个 tile

    private var tilesSection: some View {
        VStack(spacing: 10) {
            // 火柴人 tile → Shimeji tab
            StarterTile(
                icon: "figure.walk",
                name: "火柴人 (Alan Becker)",
                description: "社区热门皮肤，浏览器下载 + 拖入导入",
                action: onSelectShimeji
            )
            // 哆啦 A 梦 tile → Codex tab
            StarterTile(
                icon: "sparkles",
                name: "哆啦 A 梦",
                description: "来自 petdex 社区，一键安装",
                action: onSelectCodex
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 底部「以后再说」

    private var footerSection: some View {
        VStack(spacing: 0) {
            Divider()
            Button("以后再说") { onDismiss() }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }
}

// MARK: - StarterTile

/// 单个推荐宠物 tile：图标 + 名称 + 描述 + 操作按钮。
@MainActor
private struct StarterTile: View {
    let icon: String
    let name: String
    let description: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // SF Symbol 占位（不 bundle 版权图片）
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("安装") { action() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
