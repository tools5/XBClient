// apps/ios/BBcloud/SettingsView.swift
import SwiftUI
import UIKit

// 设置页：连接设置（DNS 占位）/ 通用（主题）/ 关于（版本）/ 账号（退出登录）。
// 主题写入 @AppStorage("bbcloud.theme")，由 ContentView 读取并应用到整个 App。
struct SettingsView: View {
    // 退出登录需要清 Persistence 并把根视图切回登录页。
    @Binding var isLoggedIn: Bool
    @EnvironmentObject private var appState: AppState

    @AppStorage("bbcloud.theme") private var themeRaw = ThemeMode.system.rawValue
    @AppStorage("bbcloud.dnsMode") private var dnsRaw = DNSMode.system.rawValue

    // 测速设置：NodeLatencyTester.testWithSettings 从同名 UserDefaults 键读取。
    @AppStorage(NodeLatencyTester.testURLDefaultsKey)
    private var latencyTestURL = NodeLatencyTester.defaultTestURL
    @AppStorage(NodeLatencyTester.timeoutDefaultsKey)
    private var latencyTimeoutMs = NodeLatencyTester.defaultTimeoutMs

    @State private var showLogoutConfirm = false
    @State private var showCopied = false

    // 测速 URL 输入框焦点：键盘工具栏「完成」与滚动收起键盘都靠它。
    @FocusState private var latencyURLFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                latencySection
                generalSection
                aboutSection
                accountSection
            }
            .navigationTitle("设置")
            // 编辑测速 URL 时：滚动即收键盘；键盘上方也有「完成」按钮。
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { latencyURLFocused = false }
                }
            }
            .confirmationDialog("确定要退出登录吗？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { logout() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 连接设置

    private var connectionSection: some View {
        Section {
            Picker("DNS 模式", selection: $dnsRaw) {
                ForEach(DNSMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
        } header: {
            Text("连接设置")
        } footer: {
            Text("DNS 模式为占位设置，功能开发中。")
        }
    }

    // MARK: - 测速设置

    private var latencySection: some View {
        Section {
            HStack {
                Text("测速 URL")
                Spacer()
                TextField("http://…/generate_204", text: $latencyTestURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .focused($latencyURLFocused)
                    .submitLabel(.done)
            }
            Picker("超时", selection: $latencyTimeoutMs) {
                Text("1 秒").tag(1000)
                Text("2 秒").tag(2000)
                Text("3 秒").tag(3000)
                Text("5 秒").tag(5000)
            }
        } header: {
            Text("延迟测速")
        } footer: {
            Text("测速走节点的代理协议本身（非 ping），未连接 VPN 也可测。")
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section("通用") {
            Picker("主题", selection: $themeRaw) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("构建号")
                Spacer()
                Text(Self.buildNumber)
                    .foregroundStyle(.secondary)
            }
            Button {
                // 检查更新：占位，后续接入面板镜像更新源。
            } label: {
                HStack {
                    Text("检查更新")
                    Spacer()
                    Text("已是最新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)

            // 面板地址：只读，长按复制。
            HStack {
                Text("面板地址")
                Spacer()
                Text(showCopied ? "已复制" : (Persistence.panelURL ?? "未设置"))
                    .font(.caption)
                    .foregroundStyle(showCopied ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onLongPressGesture {
                guard let url = Persistence.panelURL, !url.isEmpty else { return }
                UIPasteboard.general.string = url
                withAnimation(.easeInOut(duration: 0.25)) { showCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeInOut(duration: 0.25)) { showCopied = false }
                }
            }
        } header: {
            Text("关于")
        } footer: {
            Text("长按「面板地址」可复制。")
        }
    }

    // MARK: - 账号

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Text("退出登录")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 逻辑

    private func logout() {
        // reset() 内部先断隧道，并清空节点/订阅/测速等全部账号态（AppState 跨登录存活）；
        // 保留 panelURL 方便下次登录预填。
        appState.reset()
        Persistence.session = nil
        Persistence.lastSelectedNodeId = nil
        isLoggedIn = false
    }

    // MARK: - 版本信息

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    private static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}

// MARK: - DNS 模式（占位）

enum DNSMode: String, CaseIterable, Identifiable {
    case system, doh, dot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统 DNS"
        case .doh: return "DoH (DNS over HTTPS)"
        case .dot: return "DoT (DNS over TLS)"
        }
    }
}
