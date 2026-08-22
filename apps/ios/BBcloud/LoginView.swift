import SwiftUI

// 登录页：邮箱 + 密码 → XboardAPI.login → 会话落盘（Persistence）。
// 面板地址默认内置（defaultPanelURL），普通用户无需关心。
// 长按 Logo 5 次可显示面板地址编辑框，用于域名被墙后手动切换。
struct LoginView: View {
    @Binding var isLoggedIn: Bool

    /// 内置默认面板地址。域名变更时发版更新此值即可。
    private static let defaultPanelURL = "https://web.bbqaq.com"

    @State private var panelURL: String = Persistence.panelURL ?? LoginView.defaultPanelURL
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage = ""

    /// 长按 Logo 计数器：达到 5 次后显示面板地址输入框。
    @State private var logoTapCount = 0
    @State private var showPanelField = false

    @FocusState private var focusedField: Field?
    private enum Field { case panel, email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 顶部品牌区——长按 5 次解锁面板地址编辑
                VStack(spacing: 10) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .onTapGesture(count: 1) {
                            logoTapCount += 1
                            if logoTapCount >= 5 && !showPanelField {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showPanelField = true
                                }
                            }
                        }
                    Text("BBcloud")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("VPN 客户端")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 64)
                .padding(.bottom, 40)

                // 表单区
                VStack(spacing: 14) {
                    // 面板地址：默认隐藏，长按 Logo 5 次后显示
                    if showPanelField {
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            TextField("https://your-panel.com", text: $panelURL)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .panel)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .email }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TextField("邮箱", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    HStack(spacing: 10) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { if canSubmit { Task { await login() } } }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    if !errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        focusedField = nil
                        Task { await login() }
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("登录").font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .background(canSubmit ? Color.blue : Color.blue.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .disabled(!canSubmit || isLoading)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    // 规范化面板地址：无协议默认 https，去掉尾部斜杠。
    private func normalizedPanelURL() -> String? {
        var raw = panelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            raw = "https://" + raw
        }
        while raw.hasSuffix("/") { raw = String(raw.dropLast()) }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return raw
    }

    private func login() async {
        errorMessage = ""
        guard let base = normalizedPanelURL() else {
            errorMessage = "面板地址无效"
            return
        }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        defer { isLoading = false }
        do {
            let api = XboardAPI(baseURL: base, authData: nil)
            let data = try await api.login(email: mail, password: password)
            Persistence.panelURL = base
            Persistence.session = UserSession(authData: data.auth_data, email: mail)
            isLoggedIn = true
        } catch {
            errorMessage = "登录失败：\(error.localizedDescription)"
        }
    }
}
