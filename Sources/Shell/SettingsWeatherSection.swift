import SwiftUI
import Weather

/// 设置 → 天气 section。让用户挑一个内置城市,Weather 数据层会拉那个城市的
/// 真实天气(Open-Meteo),驱动 GPUSnowCoordinator 物理沙盒。
///
/// 挂哈尔滨 / 海拉尔 / 雷克雅未克 → 冬季触发 snowy → 雪 simulation 起飞。
/// 挂三亚 / 广州 → 夏季高温 → 物理沙盒展示 melt 主导。
@MainActor
struct SettingsWeatherSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // 自动跟随位置开关(开后城市 Picker 灰显)
                    Toggle("自动跟随当前位置", isOn: $viewModel.autoFollowLocation)
                        .toggleStyle(.checkbox)
                        .onChange(of: viewModel.autoFollowLocation) { on in
                            // 即时提交:写 UD + 按开关状态切坐标源(CL / 城市)
                            viewModel.onCommitAutoFollowLocation(on)
                        }

                    Picker("城市", selection: $viewModel.selectedCityID) {
                        ForEach(viewModel.cities) { city in
                            Text(city.displayName).tag(city.id)
                        }
                    }
                    .pickerStyle(.menu)
                    // 自动跟随开时禁用城市 Picker(坐标由 CoreLocation 提供)
                    .disabled(viewModel.autoFollowLocation)
                    .onChange(of: viewModel.selectedCityID) { newID in
                        // Preview: 切城市立刻拉新天气数据看效果,**不写 UD**
                        // 取消则回滚, 保存才持久化 (macOS 13 兼容旧 .onChange API)
                        viewModel.onCityPreview(newID)
                    }

                    if viewModel.autoFollowLocation {
                        // 自动跟随:显示逆地理编码的真实当前城市 + 坐标,让用户判断定位是否准确
                        // (而非显示上面灰显的手选城市的旧坐标)。
                        Text("当前位置:\(viewModel.autoFollowLocationLabel ?? "定位中…")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let coord = viewModel.selectedCity.coordinate
                        Text(String(format: "坐标:%.4f°N, %.4f°E", coord.latitude, coord.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            } label: {
                Label("位置", systemImage: "mappin.and.ellipse")
                    .font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.currentWeatherDescription)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            } label: {
                Label("当前天气", systemImage: "thermometer.sun")
                    .font(.headline)
            }

            // 「天气控制」—— 强制天气 + 温度模式 两个手动覆盖收拢到一张卡。
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("天气效果", selection: $viewModel.forcedConditionRaw) {
                            ForEach(viewModel.forcedConditionOptions, id: \.id) { opt in
                                Text(opt.displayName).tag(opt.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.forcedConditionRaw) { newRaw in
                            // Preview: 切完立刻看效果，**不写 UD**，保存持久化、取消回滚
                            viewModel.onForcedConditionPreview(newRaw)
                        }
                        Text("关闭天气效果 = 不渲染雪/雨，桌面干净；自动 = 跟随真实天气；选具体天气 = 强制对应降水。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("温度模式", selection: $viewModel.thermalOverrideRaw) {
                            ForEach(viewModel.thermalOverrideOptions, id: \.id) { opt in
                                Text(opt.displayName).tag(opt.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.thermalOverrideRaw) { newRaw in
                            // Preview: 切档立刻覆盖物理沙盒 ambient 看效果，**不写 UD**
                            viewModel.onThermalOverridePreview(newRaw)
                        }
                        Text("跟随天气 = 用真实/强制天气的温度。选具体档 = 手动覆盖：❄️ 雪天不融、🌤️ 早春光标融、🔥 烤箱全融。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("切完即时预览，点保存持久化、取消回滚。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            } label: {
                Label("天气控制", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("天气数据由 [Open-Meteo](https://open-meteo.com) 提供 — 完全免费、无需 API key。每 15 分钟自动刷新一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("切城市 / 强制天气**预览**立刻拉新数据。点保存才持久化,点取消回滚到原数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            } label: {
                Label("数据源", systemImage: "globe")
                    .font(.headline)
            }

            Spacer(minLength: 0)
        }
    }
}
