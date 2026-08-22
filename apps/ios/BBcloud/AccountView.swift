import SwiftUI
import Foundation

// 账户页：邮箱 + 订阅信息（套餐/流量/到期）+ 退出登录。
// 订阅数据来自 XboardAPI.getSubscription()，字段语义与面板一致：
// u/d/transfer_enable 为字节数，expired_at 为 Unix 秒，null 表示长期有效。
struct AccountView: View {
    @Binding var isLoggedIn: Bool
    @StateObject private var viewModel = AccountViewModel()
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // 用户信息
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.blue.gradient)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.userEmail.isEmpty ? "未知用户" : viewModel.userEmail)
                                .font(.subheadline.weight(.semibold))
                            Text(Persistence.panelURL ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 订阅信息
                Section("订阅信息") {
                    if let sub = viewModel.subscription {
                        subscriptionRows(sub)
                    } else if viewModel.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在加载订阅信息…").foregroundStyle(.secondary)
                        }
                    } else if !viewModel.errorMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(viewModel.errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Button("重试") {
                                Task { await viewModel.load() }
                            }
                            .font(.footnote)
                        }
                    }
                }

                // 退出登录
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("账户")
            .refreshable { await viewModel.load() }
            .task { await viewModel.load() }
            .confirmationDialog("确定要退出登录吗？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    viewModel.logout()
                    isLoggedIn = false
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func subscriptionRows(_ sub: SubscribeData) -> some View {
        let used = asDouble(sub.u) + asDouble(sub.d)
        let total = asDouble(sub.transfer_enable)
        let expiry = expiryInfo(fromUnixSeconds: asDouble(sub.expired_at))

        HStack {
            Label("套餐", systemImage: "shippingbox")
            Spacer()
            Text(sub.plan?.name ?? "无套餐")
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("流量", systemImage: "chart.bar")
                Spacer()
                if total > 0 {
                    Text("\(formatBytes(used)) / \(formatBytes(total))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("已用 \(formatBytes(used))")
                        .foregroundStyle(.secondary)
                }
            }
            if total > 0 {
                let fraction = min(max(used / total, 0), 1)
                ProgressView(value: fraction)
                    .tint(fraction > 0.9 ? .red : (fraction > 0.7 ? .orange : .blue))
                HStack {
                    Text("已用 \(Int((fraction * 100).rounded()))%")
                    Spacer()
                    Text("剩余 \(formatBytes(max(total - used, 0)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)

        HStack {
            Label("到期时间", systemImage: "calendar")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(expiry.text)
                    .foregroundStyle(expiry.isExpired ? .red : .secondary)
                if !expiry.detail.isEmpty {
                    Text(expiry.detail)
                        .font(.caption)
                        .foregroundStyle(expiry.isExpired ? .red : .secondary)
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var subscription: SubscribeData?
    @Published var userEmail: String = ""
    @Published var isLoading = false
    @Published var errorMessage = ""

    func load() async {
        userEmail = Persistence.session?.email ?? ""
        guard let base = Persistence.panelURL, let session = Persistence.session else {
            errorMessage = "登录信息缺失，请退出后重新登录"
            return
        }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            let api = XboardAPI(baseURL: base, authData: session.authData)
            subscription = try await api.getSubscription()
        } catch {
            errorMessage = "获取订阅信息失败：\(error.localizedDescription)"
        }
    }

    func logout() {
        Persistence.session = nil
        Persistence.lastSelectedNodeId = nil
        // 保留 panelURL，方便下次登录预填。
    }
}

// MARK: - 格式化

// 面板数值字段在不同模型定义下可能是 Int64/Int/Double（可空），统一收敛为 Double。
private func asDouble(_ v: Int64?) -> Double { Double(v ?? 0) }
private func asDouble(_ v: Int?) -> Double { Double(v ?? 0) }
private func asDouble(_ v: UInt64?) -> Double { Double(v ?? 0) }
private func asDouble(_ v: Double?) -> Double { v ?? 0 }

// 字节数 → "1.2 GB" 风格文本，1024 进制，与面板展示一致。
private func formatBytes(_ bytes: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = max(0, bytes)
    var index = 0
    while value >= 1024 && index < units.count - 1 {
        value /= 1024
        index += 1
    }
    let text = (index == 0 || value >= 100) ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return "\(text) \(units[index])"
}

private struct ExpiryInfo {
    let text: String
    let detail: String
    let isExpired: Bool
}

private let expiryDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// expired_at：0/null 视为长期有效；已过期标红；未过期给出剩余天数。
private func expiryInfo(fromUnixSeconds ts: Double) -> ExpiryInfo {
    guard ts > 0 else {
        return ExpiryInfo(text: "长期有效", detail: "", isExpired: false)
    }
    let date = Date(timeIntervalSince1970: ts)
    let now = Date()
    if date <= now {
        return ExpiryInfo(text: expiryDateFormatter.string(from: date), detail: "已过期", isExpired: true)
    }
    let days = Int(ceil(date.timeIntervalSince(now) / 86400))
    return ExpiryInfo(text: expiryDateFormatter.string(from: date), detail: "剩余 \(days) 天", isExpired: false)
}
