import SwiftUI
import Combine
import NetworkExtension

// 连接页：状态卡片（开关按钮 + 当前节点）+ 按分组的节点列表。
// 节点来自 XboardAPI.fetchProxyNodes()，连接走 TunnelController（node.rawJson 直传扩展）。
struct MainView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if viewModel.isLoading && viewModel.items.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在加载节点…").foregroundStyle(.secondary)
                        }
                    }
                } else if viewModel.items.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "暂无节点",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text(viewModel.errorMessage.isEmpty ? "下拉刷新重试" : viewModel.errorMessage)
                        )
                    }
                } else {
                    ForEach(viewModel.grouped) { section in
                        Section {
                            ForEach(section.items) { item in
                                nodeRow(item)
                            }
                        } header: {
                            Text("\(section.title) · \(section.items.count)")
                        }
                    }
                }
            }
            .navigationTitle("连接")
            .refreshable { await viewModel.loadNodes() }
            .task {
                if viewModel.items.isEmpty && !viewModel.isLoading {
                    await viewModel.loadNodes()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await viewModel.loadNodes() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        let state = viewModel.connectionState
        return VStack(spacing: 20) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.indicatorColor)
                    .frame(width: 10, height: 10)
                Text(state.displayText)
                    .font(.title3.weight(.semibold))
            }

            Button {
                toggleConnection()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [state.indicatorColor.opacity(0.85), state.indicatorColor],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 132, height: 132)
                        .shadow(color: state.indicatorColor.opacity(0.4), radius: 18, y: 6)
                    if state.isBusy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(state == .disconnecting)
            .animation(.easeInOut(duration: 0.25), value: state)

            Divider().padding(.horizontal, 32)

            if let node = viewModel.selectedNode {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        NodeTypeBadge(type: node.type)
                    }
                    Text("\(node.host):\(node.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("请在下方列表选择节点")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            // 扩展侧失败信息（status.json 回传），与 App 侧错误分开展示。
            if viewModel.tunnel.status.state == .failed && !viewModel.tunnel.status.message.isEmpty {
                Text("隧道错误：\(viewModel.tunnel.status.message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func toggleConnection() {
        switch viewModel.connectionState {
        case .connected, .connecting, .reasserting:
            viewModel.disconnect()
        case .disconnecting:
            break
        default:
            Task { await viewModel.connect() }
        }
    }

    // MARK: - 节点行

    private func nodeRow(_ item: NodeListItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.node.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                NodeTypeBadge(type: item.node.type)
            }
            Spacer()
            // 延迟占位：测速功能后续接入。
            Text("--")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Image(systemName: viewModel.selectedNodeID == item.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(viewModel.selectedNodeID == item.id ? Color.blue : Color(.systemGray4))
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.select(item) }
    }
}

// MARK: - ViewModel

@MainActor
final class MainViewModel: ObservableObject {
    @Published var nodes: [AppNode] = []
    @Published private(set) var items: [NodeListItem] = []
    @Published var selectedNode: AppNode?
    @Published var selectedNodeID: String?
    @Published var isLoading = false
    @Published var errorMessage = ""

    let tunnel: TunnelController
    private var cancellables = Set<AnyCancellable>()

    init() {
        tunnel = TunnelController()
        // TunnelController 是独立的 ObservableObject，嵌套时其变更不会自动
        // 触发本对象的视图刷新，这里手动转发。
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var connectionState: NEVPNStatus { tunnel.connectionState }

    // 按 group 字段分组，保持面板返回的先后顺序。
    var grouped: [NodeGroup] {
        var order: [String] = []
        var map: [String: [NodeListItem]] = [:]
        for item in items {
            let title = groupTitle(item.node.group)
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(item)
        }
        return order.map { NodeGroup(title: $0, items: map[$0]!) }
    }

    func loadNodes() async {
        guard let base = Persistence.panelURL, let session = Persistence.session else {
            errorMessage = "登录信息缺失，请退出后重新登录"
            return
        }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            let api = XboardAPI(baseURL: base, authData: session.authData)
            // 先拿订阅信息（含 subscribe_url），再用 subscribe_url 拉节点列表。
            let sub = try await api.getSubscription()
            nodes = try await api.fetchProxyNodes(subscribeUrl: sub.subscribe_url)
            items = Self.makeItems(nodes)
            restoreSelection()
        } catch {
            errorMessage = "获取节点失败：\(error.localizedDescription)"
        }
    }

    func select(_ item: NodeListItem) {
        selectedNode = item.node
        selectedNodeID = item.id
        Persistence.lastSelectedNodeId = item.id
    }

    func connect() async {
        guard let node = selectedNode else {
            errorMessage = "请先选择一个节点"
            return
        }
        errorMessage = ""
        // 走 connect(node:) 路径：App 侧先做 DNS 预解析（host→IP、sni←原域名），
        // 避免扩展进程在隧道路由生效后再走系统 DNS 造成回环。
        await tunnel.connect(node: node)
        if !tunnel.lastError.isEmpty { errorMessage = tunnel.lastError }
    }

    func disconnect() {
        tunnel.disconnect()
    }

    // 刷新后恢复选中：优先当前选中 id，其次上次持久化的 id，最后取第一个节点。
    private func restoreSelection() {
        guard !items.isEmpty else {
            selectedNode = nil
            selectedNodeID = nil
            return
        }
        if let current = selectedNodeID, let match = items.first(where: { $0.id == current }) {
            selectedNode = match.node
            return
        }
        if let saved = Persistence.lastSelectedNodeId, let match = items.first(where: { $0.id == saved }) {
            selectedNode = match.node
            selectedNodeID = match.id
        } else {
            selectedNode = items[0].node
            selectedNodeID = items[0].id
        }
    }

    private func groupTitle(_ group: String?) -> String {
        let title = (group ?? "").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "默认分组" : title
    }

    // 稳定 id：type|host|port|name，重名追加序号，跨刷新可恢复选中。
    private static func makeItems(_ nodes: [AppNode]) -> [NodeListItem] {
        var counts: [String: Int] = [:]
        return nodes.map { node in
            let base = "\(node.type)|\(node.host)|\(node.port)|\(node.name)"
            let n = counts[base, default: 0]
            counts[base] = n + 1
            return NodeListItem(id: n == 0 ? base : "\(base)#\(n)", node: node)
        }
    }
}

// 列表条目包装：给 AppNode 提供稳定的 Identifiable id。
struct NodeListItem: Identifiable {
    let id: String
    let node: AppNode
}

// 分组：标题即 id（分组标题在构造时已去重）。
struct NodeGroup: Identifiable {
    let title: String
    let items: [NodeListItem]
    var id: String { title }
}

// MARK: - 协议徽标

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

// MARK: - NEVPNStatus 展示映射

private extension NEVPNStatus {
    var displayText: String {
        switch self {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnecting: return "断开中…"
        case .reasserting: return "重连中…"
        case .disconnected: return "未连接"
        case .invalid: return "未连接"
        @unknown default: return "未知"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .disconnecting, .reasserting: return .orange
        default: return Color(.systemGray2)
        }
    }

    var isBusy: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}
