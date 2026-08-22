// apps/ios/BBcloud/SubscriptionView.swift
import SwiftUI

// 订阅页：用户信息 + 套餐/流量（圆形进度环）+ 到期时间。
// 订阅数据来自 AppState.subscription（XboardAPI.getSubscription），
// 字段语义与面板一致：u/d/transfer_enable 为字节，expired_at 为 Unix 秒（null 长期有效）。
struct SubscriptionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                userSection
                if let sub = appState.subscription {
                    trafficSection(sub)
                    expirySection(sub)
                } else if appState.isLoadingNodes {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在加载订阅信息…").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.nodeError.isEmpty ? "暂无订阅信息，下拉刷新重试" : appState.nodeError)
                                .font(.footnote)
                                .foregroundStyle(appState.nodeError.isEmpty ? .secondary : .red)
                            Button("重新加载") { Task { await appState.loadSubscription() } }
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("订阅")
            .refreshable { await appState.loadSubscription() }
            .task {
                if appState.subscription == nil { await appState.loadSubscription() }
            }
        }
    }

    // MARK: - 用户信息

    private var userSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Persistence.session?.email ?? "未知用户")
                        .font(.subheadline.weight(.semibold))
                    Text(Persistence.panelURL ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 流量（圆形进度环）

    private func trafficSection(_ sub: SubscribeData) -> some View {
        let used = Double(sub.u) + Double(sub.d)
        let total = Double(sub.transfer_enable)
        let fraction = total > 0 ? min(max(used / total, 0), 1) : 0
        let percent = Int((fraction * 100).rounded())

        return Section("套餐与流量") {
            HStack {
                Label("套餐", systemImage: "shippingbox")
                Spacer()
                Text(sub.plan?.name ?? "无套餐")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 18) {
                trafficRing(fraction: fraction, percent: percent, total: total)

                HStack(spacing: 12) {
                    trafficTile(icon: "arrow.up.circle.fill", title: "上行", value: formatBytes(Double(sub.u)), tint: .green)
                    trafficTile(icon: "arrow.down.circle.fill", title: "下行", value: formatBytes(Double(sub.d)), tint: .blue)
                }

                if total > 0 {
                    HStack {
                        Text("已用 \(formatBytes(used))")
                        Spacer()
                        Text("剩余 \(formatBytes(max(total - used, 0)))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("已用 \(formatBytes(used)) · 无限制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func trafficRing(fraction: Double, percent: Int, total: Double) -> some View {
        let ringColor: Color = fraction > 0.9 ? .red : (fraction > 0.7 ? .orange : .blue)
        return ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 12)
            Circle()
                .trim(from: 0, to: total > 0 ? fraction : 0)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: fraction)
            VStack(spacing: 2) {
                if total > 0 {
                    Text("\(percent)%")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("已用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "infinity")
                        .font(.system(size: 30, weight: .bold))
                    Text("不限量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 150, height: 150)
    }

    private func trafficTile(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 到期时间

    private func expirySection(_ sub: SubscribeData) -> some View {
        let expiry = expiryInfo(fromUnixSeconds: Double(sub.expired_at ?? 0))
        return Section("到期时间") {
            HStack {
                Label("到期", systemImage: "calendar")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(expiry.text)
                        .foregroundStyle(expiry.isExpired ? .red : .primary)
                    if !expiry.detail.isEmpty {
                        Text(expiry.detail)
                            .font(.caption)
                            .foregroundStyle(expiry.isExpired ? .red : .secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 格式化

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
