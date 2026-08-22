import SwiftUI
import NetworkExtension

// 单屏：粘贴 node JSON → 连接/断开 → 状态标签 + 滚动日志（读扩展写回的 status.json）。
struct ContentView: View {
    @StateObject private var controller = TunnelController()
    @State private var nodeJSON = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("粘贴节点 JSON（StartVpnRequest.node）")
                    .font(.headline)
                TextEditor(text: $nodeJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))

                HStack(spacing: 12) {
                    Button("连接") {
                        Task { await controller.connect(nodeJSON: nodeJSON) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("断开") { controller.disconnect() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text(stateLabel).foregroundStyle(.secondary)
                }

                if !controller.lastError.isEmpty {
                    Text(controller.lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("扩展状态：\(controller.status.state.rawValue) \(controller.status.message)")
                    .font(.footnote)

                Text("日志").font(.headline)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(controller.status.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: controller.status.logs.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary))
            }
            .padding()
            .navigationTitle("BBcloud")
        }
    }

    private var stateLabel: String {
        switch controller.connectionState {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnecting: return "断开中"
        case .disconnected: return "未连接"
        case .reasserting: return "重连中"
        case .invalid: return "未配置"
        @unknown default: return "未知"
        }
    }
}
