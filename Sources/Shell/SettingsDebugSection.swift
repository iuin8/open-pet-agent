import AppKit
import Rendering
import SwiftUI

/// 设置 → 调试 section。把 falling-sand 雪物理的所有可调字面量（密度/风/重力/大小/
/// 积雪上限/升华/相变阈值/温度覆盖）做成实时滑块——拖一下立即生效，省掉
/// edit→build→install→截图 的慢循环。
///
/// 数据流：滑块绑定 `viewModel.fallingSandTuning.<字段>` → section 级 onChange
/// → `onFallingSandTuningPreview(tuning)` → app → driver.tuning（每帧 apply）。
/// 「重置默认」回工厂值；「导出当前值」把当前调好的值打到控制台 + 拷贝到剪贴板，
/// 方便粘进 `FallingSandRules` / `FallingSandParticles` / `FallingSandDriver` 固化。
@MainActor
struct SettingsDebugSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("降雪", icon: "cloud.snow.fill") {
                intRow("雪密度 emit/帧", $viewModel.fallingSandTuning.snowEmitPerFrame, 0...120)
                intRow("雨密度 emit/帧", $viewModel.fallingSandTuning.rainEmitPerFrame, 0...120)
                floatRow("风力", $viewModel.fallingSandTuning.windStrength, 0...6, "%.2f")
                floatRow("重力", $viewModel.fallingSandTuning.gravity, 10...300, "%.0f")
                floatRow("雪花最小尺寸", $viewModel.fallingSandTuning.sizeMin, 0.2...6, "%.2f")
                floatRow("雪花最大尺寸", $viewModel.fallingSandTuning.sizeMax, 0.5...12, "%.2f")
                floatRow("下落概率", $viewModel.fallingSandTuning.snowFallProbability, 0...1, "%.2f")
            }

            group("雨视觉（水花 / 随风斜 / 湿亮）", icon: "cloud.rain.fill") {
                floatRow("splash 水花概率", $viewModel.fallingSandTuning.splashProbability, 0...1, "%.2f")
                floatRow("雨随风斜 lean（±直落）", $viewModel.fallingSandTuning.rainWindLean, -40...40, "%.0f")
                floatRow("积水湿亮基线", $viewModel.fallingSandTuning.wetnessBaseline, 0...1, "%.2f")
            }

            group("积雪", icon: "square.stack.3d.up.fill") {
                intRow("硬上限 maxColumnDepth", $viewModel.fallingSandTuning.maxColumnDepth, 1...120)
                floatRow("升华 base/秒", $viewModel.fallingSandTuning.snowSublimatePerSec, 0...0.2, "%.4f")
                floatRow("升华深度系数 k", $viewModel.fallingSandTuning.snowDepthSublimateCoeff, 0...0.02, "%.4f")
            }

            group("相变温度（归一化 0..1）", icon: "thermometer.medium") {
                floatRow("融化阈值 melt", $viewModel.fallingSandTuning.meltThreshold, 0...1, "%.2f")
                floatRow("结冰阈值 freeze", $viewModel.fallingSandTuning.freezeThreshold, 0...1, "%.2f")
                floatRow("蒸发阈值 evap", $viewModel.fallingSandTuning.evaporateThreshold, 0...1, "%.2f")
                floatRow("凝结阈值 condense", $viewModel.fallingSandTuning.condenseThreshold, 0...1, "%.2f")
                floatRow("融化速率/秒", $viewModel.fallingSandTuning.meltRatePerSec, 0...10, "%.1f")
                floatRow("结冰速率/秒", $viewModel.fallingSandTuning.freezeRatePerSec, 0...10, "%.1f")
                floatRow("蒸发速率/秒", $viewModel.fallingSandTuning.evaporateRatePerSec, 0...10, "%.1f")
                floatRow("凝结速率/秒", $viewModel.fallingSandTuning.condenseRatePerSec, 0...10, "%.1f")
                floatRow("steam 消散/秒", $viewModel.fallingSandTuning.steamDissipatePerSec, 0...1, "%.3f")
            }

            group("调试温度覆盖", icon: "wand.and.rays") {
                floatRow("环境温度覆盖（<0 = 关，用天气）", $viewModel.fallingSandTuning.ambientOverride, -0.05...1, "%.2f")
            }

            group("弹力球抛射（甩动回弹）", icon: "circle.dashed") {
                doubleRow("重力 gravity", $viewModel.ballisticTuning.gravity, 500...6000, "%.0f")
                doubleRow("弹性系数 restitution", $viewModel.ballisticTuning.restitution, 0...0.95, "%.2f")
                doubleRow("空气阻力 airDrag/s", $viewModel.ballisticTuning.airDrag, 0...2, "%.2f")
                doubleRow("切向摩擦 tangentFriction", $viewModel.ballisticTuning.tangentFriction, 0.5...1, "%.2f")
                doubleRow("落定速度阈值 settleSpeed", $viewModel.ballisticTuning.settleSpeed, 10...300, "%.0f")
                doubleRow("甩出速度上限 maxLaunch", $viewModel.ballisticTuning.maxLaunchSpeed, 1000...8000, "%.0f")
                HStack {
                    Button("重置弹力球默认") { viewModel.resetBallisticTuning() }
                    Spacer()
                    Text("拖滑块即时生效。甩起弹力球看回弹手感。").font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(spacing: 10) {
                    Button("重置默认") { viewModel.resetFallingSandTuning() }
                    Button("导出当前值") { exportTuning() }
                    Spacer()
                    Text("拖滑块即时生效，点保存持久化。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        // 任一字段变化 → 实时 preview（不写 UD）。
        .onChange(of: viewModel.fallingSandTuning) { newValue in
            viewModel.onFallingSandTuningPreview(newValue)
        }
        .onChange(of: viewModel.ballisticTuning) { newValue in
            viewModel.onBallisticTuningPreview(newValue)
        }
    }

    // MARK: - 导出

    private func exportTuning() {
        let snippet = viewModel.fallingSandTuning.swiftCodeSnippet()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        print("[FallingSandTuning] 导出（已拷贝到剪贴板）：\n\(snippet)")
    }

    // MARK: - 复用控件

    @ViewBuilder
    private func group(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(8)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }

    private func floatRow(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ fmt: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 200, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Float($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: fmt, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }

    private func doubleRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 200, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }

    private func intRow(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 200, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(value.wrappedValue)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }
}
