import Orchestrator
import SwiftUI

/// 设置 → 主动协助 section。
///
/// 让用户控制桌宠的主动性级别（关/克制/适度/积极）和四个触发场景开关，
/// 以及 dwell 判定阈值（仅 dwell 开时显示）。
/// 改动即时 preview（热更新引擎），点保存才持久化到 UserDefaults。
///
/// 数据流：控件绑定 `viewModel.proactiveSettings.<字段>` → section 级 onChange
/// → `onProactiveSettingsPreview(settings)` → app → engine.updateSettings。
@MainActor
struct SettingsProactiveSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - 主动性级别
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("主动性级别", selection: $viewModel.proactiveSettings.level) {
                        ForEach(ProactivityLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.proactiveSettings.level != .off {
                        // 频率预览（只读，计算属性推导）
                        let minMinutes = Int(viewModel.proactiveSettings.minIntervalSeconds / 60)
                        let maxPerHour = viewModel.proactiveSettings.maxPerHour
                        Text("每 \(minMinutes) 分钟最多一条，每小时上限 \(maxPerHour) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("已关闭：桌宠不会主动发起建议")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            } label: {
                Label("主动性级别", systemImage: "brain.head.profile").font(.headline)
            }

            // MARK: - 称呼与语气（persona：注入主动建议 system prompt，让它更贴你）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("一句话告诉桌宠怎么称呼你、你的身份或喜欢的语气，它主动开口时会更贴合你（只影响语气，不会照搬这句话）。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(
                        "例：叫我老王，后端工程师，说话随意点",
                        text: $viewModel.proactiveSettings.personaText,
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.proactiveSettings.level == .off)
                }
                .padding(8)
            } label: {
                Label("称呼与语气", systemImage: "person.text.rectangle").font(.headline)
            }

            // MARK: - 触发场景
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $viewModel.proactiveSettings.triggerAppSwitch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("切换 App 时")
                            Text("切到新应用时，结合上下文给出相关建议")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)

                    Toggle(isOn: $viewModel.proactiveSettings.triggerIdleReturn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Idle 回来时")
                            Text("离开 3 分钟以上回来后，主动打招呼或续接上下文")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)

                    Toggle(isOn: $viewModel.proactiveSettings.triggerDwell) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("卡同一窗口很久时（Dwell）")
                            Text("信号最模糊，容易误触发；建议仅在积极模式下开启")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)

                    // dwell 阈值滑块：仅 dwell 开且 level 非 off 时显示
                    if viewModel.proactiveSettings.triggerDwell &&
                       viewModel.proactiveSettings.level != .off {
                        HStack(spacing: 10) {
                            Text("Dwell 判定阈值")
                                .font(.system(size: 12))
                                .frame(width: 120, alignment: .leading)
                            Slider(
                                value: $viewModel.proactiveSettings.dwellThresholdSeconds,
                                in: 120...900,
                                step: 60
                            )
                            Text("\(Int(viewModel.proactiveSettings.dwellThresholdSeconds / 60)) 分钟")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                        .padding(.leading, 20)
                    }

                    Toggle(isOn: $viewModel.proactiveSettings.triggerLateNight) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("深夜关怀")
                            Text("凌晨工作时，发一条轻量关怀提醒注意休息")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)
                }
                .padding(8)
            } label: {
                Label("触发场景", systemImage: "list.bullet.clipboard").font(.headline)
            }

            // MARK: - 自主开口（非等事件，pet 自己周期性主动说话）
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $viewModel.proactiveSettings.chatterEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("碎碎念（生命感）")
                            Text("pet 每隔几分钟随口说句轻松的话（按当前应用/时段选，不耗 AI）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)

                    Toggle(isOn: $viewModel.proactiveSettings.triggerAutonomous) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("主动闲聊（AI 自发）")
                            Text("pet 偶尔基于当前桌面自发用 AI 说一句关心或建议（仅积极级别，更费 token）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(viewModel.proactiveSettings.level == .off)
                }
                .padding(8)
            } label: {
                Label("自主开口", systemImage: "bubble.left.and.bubble.right").font(.headline)
            }

            // MARK: - 重置
            GroupBox {
                HStack(spacing: 10) {
                    Button("重置默认") { viewModel.resetProactiveSettings() }
                    Spacer()
                    Text("改动即时预览，点保存持久化。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        // 任一字段变化 → 实时 preview（不写 UD）。
        .onChange(of: viewModel.proactiveSettings) { newValue in
            viewModel.onProactiveSettingsPreview(newValue)
        }
    }
}
