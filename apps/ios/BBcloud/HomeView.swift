// apps/ios/BBcloud/HomeView.swift
import SwiftUI
import NetworkExtension

// 首页：连接仪表盘。大圆形连接按钮 + 状态/时长 + 当前节点卡片 + 实时速度 + 错误。
// 状态与操作全部来自共享的 AppState（EnvironmentObject）。
struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    // 本地记录进入“已连接”的时刻，用于计算连接时长（扩展未回传连接起始时间）。
    @State private var connectedAt: Date?

    // 首页节点选择面板。
    @State private var showNodePicker = false

    // 速度计算：上一次流量采样（累计上/下行字节 + status.updatedAt）与当前速率。
    @State private var lastTrafficSample: (up: Int64, down: Int64, at: Double)?
    @State private var uploadSpeed: Double = 0
    @State private var downloadSpeed: Double = 0
    // 每秒重算一次速度；扩展侧流量写盘也是 1 秒节流，节奏匹配。
    private let speedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                // 新会话：清掉上一会话的流量采样，避免跨会话算出脏速率。
                lastTrafficSample = nil
                uploadSpeed = 0
                downloadSpeed = 0
            case .disconnected, .invalid:
                connectedAt = nil
                lastTrafficSample = nil
                uploadSpeed = 0
                downloadSpeed = 0
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
                Text("请先选择节点")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 当前节点卡片（点击弹出节点选择面板）

    private var nodeCard: some View {
        Button {
            showNodePicker = true
        } label: {
            HStack(spacing: 10) {
                if let node = appState.selectedNode {
                    Image(systemName: "globe.asia.australia.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text(node.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    NodeTypeBadge(type: node.type)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("选择节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showNodePicker) {
            NodePickerSheet()
                .environmentObject(appState)
        }
    }

    // MARK: - 实时速度与本次会话流量

    private var speedRow: some View {
        let status = appState.tunnel.status
        return HStack(spacing: 12) {
            speedTile(
                icon: "arrow.up", title: "上行",
                speed: uploadSpeed,
                total: status.uploadBytes,
                tint: .green
            )
            speedTile(
                icon: "arrow.down", title: "下行",
                speed: downloadSpeed,
                total: status.downloadBytes,
                tint: .blue
            )
        }
        .onReceive(speedTimer) { _ in updateSpeeds() }
    }

    private func speedTile(icon: String, title: String, speed: Double, total: Int64?, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(formatBytes(speed))/s")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // 本次会话累计用量；旧版扩展无此字段时显示 --。
            Text(total.map { "共 \(formatBytes(Double($0)))" } ?? "共 --")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // 速度 = 相邻两次流量采样的字节差 / 时间差。扩展只在有流量时写盘，
    // 静默 3 秒以上视为无流量，速率归零。
    private func updateSpeeds() {
        let status = appState.tunnel.status
        guard state == .connected, let up = status.uploadBytes, let down = status.downloadBytes else {
            lastTrafficSample = nil
            uploadSpeed = 0
            downloadSpeed = 0
            return
        }
        guard let prev = lastTrafficSample else {
            lastTrafficSample = (up, down, status.updatedAt)
            return
        }
        if status.updatedAt > prev.at {
            let dt = status.updatedAt - prev.at
            uploadSpeed = max(0, Double(up - prev.up) / dt)
            downloadSpeed = max(0, Double(down - prev.down) / dt)
            lastTrafficSample = (up, down, status.updatedAt)
        } else if Date().timeIntervalSince1970 - status.updatedAt > 3 {
            uploadSpeed = 0
            downloadSpeed = 0
        }
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

// MARK: - 首页节点选择面板

// 轻量选择器：名称 + 协议徽章 + 延迟徽章，点击即选中并收起。
// 完整功能（搜索、分组、一键测速）仍在「节点」Tab。
private struct NodePickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if appState.nodes.isEmpty {
                    ContentUnavailableView {
                        Label("暂无节点", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text(appState.nodeError.isEmpty ? "正在加载或订阅为空" : appState.nodeError)
                    } actions: {
                        Button("重新加载") { Task { await appState.loadNodes() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(appState.nodeItems) { item in
                            row(item)
                        }
                    }
                }
            }
            .navigationTitle("选择节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: NodeListItem) -> some View {
        let isSelected = appState.selectedNodeID == item.id
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.blue : Color(.systemGray4))
            Text(item.node.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            NodeTypeBadge(type: item.node.type)
            Spacer(minLength: 8)
            LatencyBadge(outcome: appState.latency[item.id] ?? .idle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectNode(item.node, id: item.id)
            dismiss()
        }
    }
}
