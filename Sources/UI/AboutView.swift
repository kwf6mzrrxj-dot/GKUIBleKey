import SwiftUI

/// 关于页面 —— 展示 App 版本、项目说明与技术支持信息。
///
/// ⚠️ **当前没有任何入口打开它**（v2.9 起）：原「关于」入口只显示版本号，
/// 已并入「开发者」页底部的版本行，少一次跳转。此文件保留备用，
/// 若将来需要展示完整项目说明，把入口加回 `DeveloperMenuView` 即可。
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    infoSection
                    techSection
                    footer
                }
                .padding(20)
            }
            .background(background)
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 背景

    private var background: some View {
        Group {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [Color(red: 0.11, green: 0.12, blue: 0.16),
                             Color(red: 0.06, green: 0.07, blue: 0.10)],
                    startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.93, green: 0.95, blue: 0.98),
                             Color(red: 0.84, green: 0.87, blue: 0.92)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部：图标 + 名称 + 版本

    private var header: some View {
        VStack(spacing: 12) {
            // App 图标占位（无独立图标资源，用车锁符号表达数字钥匙身份）
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                Image(systemName: "car.side.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .blue.opacity(0.35), radius: 12, y: 6)

            Text("蓝牙钥匙")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text("版本 \(AppInfo.versionString)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("构建 \(AppInfo.buildNumber)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    // MARK: - 基本信息

    private var infoSection: some View {
        card("应用信息") {
            infoRow("应用名称", "蓝牙钥匙")
            Divider().overlay(Color.secondary.opacity(0.3))
            infoRow("版本号", AppInfo.versionString)
            Divider().overlay(Color.secondary.opacity(0.3))
            infoRow("构建号", AppInfo.buildNumber)
            Divider().overlay(Color.secondary.opacity(0.3))
            infoRow("支持车型", "吉利 博越 PRO")
        }
    }

    // MARK: - 技术说明

    private var techSection: some View {
        card("关于本项目") {
            VStack(alignment: .leading, spacing: 8) {
                Text("一款纯软件方案的数字钥匙 App，通过蓝牙与车辆钥匙模块通信，"
                     + "完成认证后实现车门解锁 / 闭锁、后备箱、车窗、寻车，"
                     + "以及车辆状态（门锁、后备箱、上电、发动机、ACC）实时显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("协议实现严格对齐原厂 App（GKUI / 小卡）反汇编逻辑，"
                     + "密码学实现经独立实现 + 官方测试向量交叉验证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        Text("版本号按 0.1 步进更新")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    // MARK: - 复用组件

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Text(v)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}
