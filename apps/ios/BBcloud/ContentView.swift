// apps/ios/BBcloud/ContentView.swift
import SwiftUI
import Combine
import NetworkExtension

// 根视图：有会话进主界面（4 Tab 底部导航），否则进登录页。
// 4 个 Tab 共享同一个 AppState（内含唯一的 TunnelController 与 XboardAPI 实例，
// 以及节点/订阅/选中态），通过 @StateObject 持有、.environmentObject 下发。
struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var isLoggedIn = Persistence.session != nil
    @AppStorage("bbcloud.theme") private var themeRaw = ThemeMode.system.rawValue

    private var theme: ThemeMode { ThemeMode(rawValue: themeRaw) ?? .system }

    var body: some View {
        Group {
            if isLoggedIn {
                TabView {
                    HomeView()
                        .tabItem { Label("首页", systemImage: "bolt.shield.fill") }
                    NodeListView()
                        .tabItem { Label("节点", systemImage: "globe") }
                    SubscriptionView()
                        .tabItem { Label("订阅", systemImage: "chart.bar.fill") }
                    SettingsView(isLoggedIn: $isLoggedIn)
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }
                }
                .environmentObject(appState)
                .tint(.blue)
            } else {
                LoginView(isLoggedIn: $isLoggedIn)
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: isLoggedIn)
    }
}

// MARK: - 全局状态

// 所有 Tab 共享的应用状态：唯一的 TunnelController、唯一的 XboardAPI，
// 以及节点列表 / 选中节点 / 订阅信息。@MainActor 保证所有可变状态在主线程更新。
@MainActor
final class AppState: ObservableObject {
    // 唯一的隧道控制器（VPN 控制面）。
    let tunnel = TunnelController()
    // 唯一的面板 API 客户端；每次网络请求前用 syncCredentials() 从 Persistence 同步凭证。
    let api = XboardAPI()

    @Published var nodes: [AppNode] = []
    @Published var selectedNode: AppNode?
    @Published var selectedNodeID: String?
    @Published var subscription: SubscribeData?
    @Published var isLoadingNodes = false
    @Published var nodeError = ""

    // 节点延迟测速结果（key = NodeListItem.id）。切 Tab 不丢，刷新节点列表时保留，
    // 因为 id 是稳定拼接（type|host|port|name），同一节点跨刷新仍能命中。
    @Published var latency: [String: NodeLatencyTester.Outcome] = [:]
    @Published var isTestingAll = false

    // 路由模式（规则/全局/直连），持久化到 App Group 供扩展读取。
    @Published var routingMode: RoutingMode = Persistence.routingMode

    private var cancellables = Set<AnyCancellable>()

    init() {
        // TunnelController 是独立的 ObservableObject，嵌套持有时其 @Published 变更
        // 不会自动触发本对象观察者刷新，这里手动转发一次 objectWillChange。
        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 启动时恢复上次选中的节点 id（节点列表拉回后再据此定位真正的节点）。
        selectedNodeID = Persistence.lastSelectedNodeId
    }

    // 便捷透传：连接状态。
    var connectionState: NEVPNStatus { tunnel.connectionState }

    // MARK: 数据加载

    // 拉节点：先 getSubscription 拿 subscribe_url，再 fetchProxyNodes 取节点列表。
    func loadNodes() async {
        guard syncCredentials() else {
            nodeError = "登录信息缺失，请退出后重新登录"
            return
        }
        isLoadingNodes = true
        nodeError = ""
        defer { isLoadingNodes = false }
        do {
            let sub = try await api.getSubscription()
            subscription = sub
            nodes = try await api.fetchProxyNodes(subscribeUrl: sub.subscribe_url)
            restoreSelection()
        } catch {
            nodeError = "获取节点失败：\(error.localizedDescription)"
        }
    }

    // 只刷新订阅信息（订阅页下拉刷新用，无需重拉整份节点列表）。
    func loadSubscription() async {
        guard syncCredentials() else {
            nodeError = "登录信息缺失，请退出后重新登录"
            return
        }
        do {
            subscription = try await api.getSubscription()
        } catch {
            nodeError = "获取订阅信息失败：\(error.localizedDescription)"
        }
    }

    // MARK: 选择与连接

    func selectNode(_ node: AppNode, id: String) {
        selectedNode = node
        selectedNodeID = id
        Persistence.lastSelectedNodeId = id
    }

    // 按路由模式连接：direct 用直连伪节点（不依赖节点列表）；rule/global 用选中节点，
    // 并附上全部节点主机名供 TunnelController 预解析排除路由。
    func connect() async {
        if routingMode == .direct {
            await tunnel.connect(nodeJSON: #"{"type":"direct","name":"DIRECT"}"#)
            return
        }
        guard let node = selectedNode else {
            nodeError = "请先选择节点"
            return
        }
        await tunnel.connect(node: node, allHosts: nodes.map(\.host))
    }

    func disconnect() {
        tunnel.disconnect()
    }

    // 切换路由模式：立即持久化；已连接/连接中时自动重连生效。
    func setRoutingMode(_ mode: RoutingMode) {
        guard mode != routingMode else { return }
        routingMode = mode
        Persistence.routingMode = mode
        if connectionState == .connected || connectionState == .connecting {
            Task { await reconnect() }
        }
    }

    // 断开 → 等待落定（最多 5 秒）→ 重连。超时未落定则不强行重连，
    // 避免在 disconnecting 状态上叠加 startVPNTunnel。
    private func reconnect() async {
        disconnect()
        for _ in 0..<50 {
            if connectionState == .disconnected || connectionState == .invalid { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connectionState == .disconnected || connectionState == .invalid else { return }
        await connect()
    }

    // 退出登录时清空全部账号态：AppState 是根视图上的 @StateObject，跨登录/登出存活，
    // 不清会导致下一个账号看到上一账号的节点、订阅与测速结果。
    func reset() {
        disconnect()
        generation += 1
        nodes = []
        selectedNode = nil
        selectedNodeID = nil
        subscription = nil
        latency = [:]
        nodeError = ""
        isTestingAll = false
    }

    // MARK: 延迟测速

    // 代际计数：reset() 后在途的测速任务不得把旧账号的结果写回。
    private var generation = 0

    // 测单个节点。aerion_test_node 在 Rust 侧有互斥锁，天然串行，无需 Swift 侧限流。
    func testLatency(_ item: NodeListItem) async {
        let gen = generation
        latency[item.id] = .testing
        let outcome = await NodeLatencyTester.testWithSettings(node: item.node)
        guard gen == generation else { return }
        latency[item.id] = outcome
    }

    // 一键全测：先全部置为“测试中”（转圈），再逐个出结果——与 Nextin 行为一致。
    func testAllLatency() async {
        guard !isTestingAll else { return }
        isTestingAll = true
        defer { isTestingAll = false }
        let gen = generation
        let items = nodeItems
        for item in items { latency[item.id] = .testing }
        for item in items {
            let outcome = await NodeLatencyTester.testWithSettings(node: item.node)
            guard gen == generation else { return }
            latency[item.id] = outcome
        }
    }

    // MARK: 列表项与选中恢复

    // 稳定 id：type|host|port|name，重名追加 #序号，跨刷新可恢复选中。
    static func makeItems(_ nodes: [AppNode]) -> [NodeListItem] {
        var counts: [String: Int] = [:]
        return nodes.map { node in
            let base = "\(node.type)|\(node.host)|\(node.port)|\(node.name)"
            let n = counts[base, default: 0]
            counts[base] = n + 1
            return NodeListItem(id: n == 0 ? base : "\(base)#\(n)", node: node)
        }
    }

    var nodeItems: [NodeListItem] { Self.makeItems(nodes) }

    // 刷新后恢复选中：优先当前选中 id，其次上次持久化 id，最后取第一个节点。
    private func restoreSelection() {
        let items = nodeItems
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
            Persistence.lastSelectedNodeId = items[0].id
        }
    }

    // 每次网络请求前把最新面板地址 / 鉴权同步到共享的 api 实例。
    private func syncCredentials() -> Bool {
        guard let base = Persistence.panelURL, let session = Persistence.session else { return false }
        api.baseURL = base
        api.authData = session.authData
        return true
    }
}

// MARK: - 共享列表模型

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

// MARK: - 主题模式

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - NEVPNStatus 展示映射（全 App 共用）

extension NEVPNStatus {
    var bbDisplayText: String {
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

    var bbIndicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .disconnecting, .reasserting: return .orange
        default: return Color(.systemGray2)
        }
    }

    var bbIsBusy: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}
