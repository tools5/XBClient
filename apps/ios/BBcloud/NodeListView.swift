// apps/ios/BBcloud/NodeListView.swift
import SwiftUI

// 节点页：顶部搜索栏 + 按分组的节点列表 + 下拉/按钮刷新。
// 数据与选中态来自共享的 AppState（EnvironmentObject）。
struct NodeListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    // 长按失败徽章时展示的错误详情（非 nil 即弹窗）。
    @State private var latencyErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingNodes && appState.nodes.isEmpty {
                    loadingView
                } else if appState.nodes.isEmpty {
                    emptyView
                } else {
                    nodeList
                }
            }
            .navigationTitle("节点")
            .searchable(text: $searchText, prompt: "搜索节点名或协议")
            .refreshable { await appState.loadNodes() }
            .alert(
                "测速失败",
                isPresented: Binding(
                    get: { latencyErrorMessage != nil },
                    set: { if !$0 { latencyErrorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(latencyErrorMessage ?? "")
            }
            .task {
                if appState.nodes.isEmpty && !appState.isLoadingNodes {
                    await appState.loadNodes()
                }
            }
            .toolbar {
                // ⚡ 一键测速：全部置“测试中”后逐个出结果（Rust 侧串行）。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.testAllLatency() }
                    } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .disabled(appState.isTestingAll || appState.nodes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.isLoadingNodes {
                        ProgressView()
                    } else {
                        Button {
                            Task { await appState.loadNodes() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 列表

    private var nodeList: some View {
        List {
            ForEach(groupedSections) { section in
                Section {
                    ForEach(section.items) { item in
                        nodeRow(item)
                    }
                } header: {
                    Text("\(section.title) · \(section.items.count)")
                }
            }
            if groupedSections.isEmpty {
                Section {
                    Text("没有匹配「\(searchText)」的节点")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nodeRow(_ item: NodeListItem) -> some View {
        let isSelected = appState.selectedNodeID == item.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.node.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                // 只展示协议徽章，不暴露服务器地址与端口。
                NodeTypeBadge(type: item.node.type)
            }
            Spacer(minLength: 8)
            // 延迟徽章：点徽章单测该节点；测速失败后长按徽章看错误详情。
            LatencyBadge(outcome: appState.latency[item.id] ?? .idle)
                .onTapGesture {
                    Task { await appState.testLatency(item) }
                }
                .onLongPressGesture {
                    if case .failed(let message) = appState.latency[item.id] {
                        latencyErrorMessage = message
                    }
                }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.blue : Color(.systemGray4))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                appState.selectNode(item.node, id: item.id)
            }
        }
    }

    // MARK: - 状态视图

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载节点…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("暂无节点", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(appState.nodeError.isEmpty ? "下拉刷新重试" : appState.nodeError)
        } actions: {
            Button("重新加载") { Task { await appState.loadNodes() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 分组与过滤

    // 先按搜索词过滤（节点名 / 协议类型 / 主机），再按 group 分组保持面板返回顺序。
    private var groupedSections: [NodeGroup] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let items = appState.nodeItems.filter { item in
            guard !keyword.isEmpty else { return true }
            let node = item.node
            return node.name.lowercased().contains(keyword)
                || node.type.lowercased().contains(keyword)
                || NodeTypeBadge.label(for: node.type).lowercased().contains(keyword)
                || node.host.lowercased().contains(keyword)
        }

        var order: [String] = []
        var map: [String: [NodeListItem]] = [:]
        for item in items {
            let title = groupTitle(item.node.group)
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(item)
        }
        return order.map { NodeGroup(title: $0, items: map[$0]!) }
    }

    private func groupTitle(_ group: String?) -> String {
        let title = (group ?? "").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "默认分组" : title
    }
}

// MARK: - 延迟徽章

// 显示 NodeLatencyTester 的测速结果：<100ms 绿 / <300ms 黄 / ≥300ms 橙 / 失败红。
// 未测时显示灰色“测速”，点击可单测（手势挂在使用方）。
struct LatencyBadge: View {
    let outcome: NodeLatencyTester.Outcome

    var body: some View {
        Group {
            switch outcome {
            case .idle:
                capsuleText("测速", color: .gray)
            case .testing:
                ProgressView()
                    .controlSize(.small)
            case .ok(let ms):
                capsuleText("\(ms) ms", color: Self.color(forLatency: ms))
            case .failed:
                capsuleText("超时", color: .red)
            }
        }
        // 固定最小宽度，避免测速中/出结果时行内元素跳动。
        .frame(minWidth: 52, alignment: .trailing)
    }

    private func capsuleText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    static func color(forLatency ms: Int) -> Color {
        if ms < 100 { return .green }
        if ms < 300 { return .yellow }
        return .orange
    }
}

// MARK: - 协议徽标（全 App 共用）

struct NodeTypeBadge: View {
    let type: String

    var body: some View {
        let color = Self.color(for: type)
        Text(Self.label(for: type))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    static func label(for type: String) -> String {
        switch type.lowercased() {
        case "ss", "shadowsocks": return "SS"
        case "vmess": return "VMess"
        case "vless": return "VLESS"
        case "trojan": return "Trojan"
        case "hysteria2": return "Hy2"
        case "hysteria": return "Hy"
        case "tuic": return "TUIC"
        case "anytls": return "AnyTLS"
        case "naive": return "Naive"
        case "mieru": return "Mieru"
        case "socks5": return "SOCKS5"
        case "http": return "HTTP"
        case "direct": return "直连"
        case "block": return "拦截"
        default: return type.uppercased()
        }
    }

    static func color(for type: String) -> Color {
        switch type.lowercased() {
        case "ss", "shadowsocks": return .blue
        case "vmess": return .purple
        case "vless": return .indigo
        case "trojan": return .red
        case "hysteria2", "hysteria": return .orange
        case "tuic": return .teal
        case "anytls": return .pink
        case "naive", "mieru": return .mint
        case "socks5", "http": return .brown
        default: return .gray
        }
    }
}
