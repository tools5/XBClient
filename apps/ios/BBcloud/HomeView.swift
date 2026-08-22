// apps/ios/BBcloud/HomeView.swift
import SwiftUI
import NetworkExtension

// 首页：连接仪表盘。大圆形连接按钮 + 状态/时长 + 当前节点卡片 + 实时速度 + 错误。
// 状态与操作全部来自共享的 AppState（EnvironmentObject）。
struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    // 本地记录进入“已连接”的时刻，用于计算连接时长（扩展未回传连接起始时间）。
    @State private var connectedAt: Date?

    private var state: NEVPNStatus { appState.connectionState }
    private var isConnected: Bool { state == .connected }
    private var canConnect: Bool { appState.selectedNode != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    connectButton
                    statusBlock
                    nodeCard
                    if isConnected { speedRow }
                    errorSection
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("首页")
        }
        .onAppear {
            // 冷启动时若已处于连接态，补上一个起始时刻（不精确，仅用于展示）。
            if isConnected && connectedAt == nil { connectedAt = Date() }
        }
        // 首页是冷启动/登录后的第一个 Tab：这里必须兜底拉一次节点，
        // 否则 selectedNode 恢复不了，连接按钮一直灰着，得先去节点页才激活。
        .task {
            if appState.nodes.isEmpty && !appState.isLoadingNodes {
                await appState.loadNodes()
            }
        }
        .onChange(of: state) { _, newValue in
            switch newValue {
            case .connected:
                if connectedAt == nil { connectedAt = Date() }
            case .disconnected, .invalid:
                connectedAt = nil
            default:
                break
            }
        }
    }

    // MARK: - 大圆形连接按钮（直径 160pt）

    private var connectButton: some View {
        let color = state.bbIndicatorColor
        let enabled = canConnect || isConnected || state == .connecting || state == .reasserting
        return Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.85), color],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 160, height: 160)
                    .shadow(color: color.opacity(0.45), radius: 22, y: 8)
                if state.bbIsBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || state == .disconnecting)
        .opacity((!canConnect && !isConnected && !state.bbIsBusy) ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.25), value: state)
        .padding(.top, 12)
    }

    // MARK: - 状态文字 + 连接时长

    private var statusBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.bbIndicatorColor)
                    .frame(width: 10, height: 10)
                Text(state.bbDisplayText)
                    .font(.title3.weight(.semibold))
            }
            if isConnected {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(durationText(now: context.date))
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            } else if !canConnect {
                Text("请在节点页选择节点")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 当前节点卡片

    private var nodeCard: some View {
        VStack(spacing: 12) {
            if let node = appState.selectedNode {
                HStack(spacing: 10) {
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(node.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            NodeTypeBadge(type: node.type)
                        }
                        // String(port)：SwiftUI Text 的 Int 插值会按 locale 加千分位（42,051）。
                        Text("\(node.host):\(String(node.port))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("请在节点页选择节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - 实时速度（连接后显示，暂为占位）

    private var speedRow: some View {
        HStack(spacing: 12) {
            speedTile(icon: "arrow.up", title: "上行", value: "--", tint: .green)
            speedTile(icon: "arrow.down", title: "下行", value: "--", tint: .blue)
        }
    }

    private func speedTile(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 错误信息

    @ViewBuilder
    private var errorSection: some View {
        // App 侧错误（DNS 预解析 / 启动隧道失败等）。
        if !appState.tunnel.lastError.isEmpty {
            errorText(appState.tunnel.lastError)
        }
        // 扩展侧失败信息（status.json 回传），与 App 侧错误分开展示。
        if appState.tunnel.status.state == .failed && !appState.tunnel.status.message.isEmpty {
            errorText("隧道错误：\(appState.tunnel.status.message)")
        }
    }

    private func errorText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 逻辑

    private func toggle() {
        switch state {
        case .connected, .connecting, .reasserting:
            appState.disconnect()
        case .disconnecting:
            break
        default:
            guard canConnect else { return }
            Task { await appState.connect() }
        }
    }

    private func durationText(now: Date) -> String {
        guard let start = connectedAt else { return "00:00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
    }
}
