import SwiftUI

// 根视图：有会话进主界面（连接 + 账户两个 Tab），否则进登录页。
struct ContentView: View {
    @State private var isLoggedIn = Persistence.session != nil

    var body: some View {
        Group {
            if isLoggedIn {
                TabView {
                    MainView()
                        .tabItem { Label("连接", systemImage: "bolt.shield") }
                    AccountView(isLoggedIn: $isLoggedIn)
                        .tabItem { Label("账户", systemImage: "person.circle") }
                }
                .tint(.blue)
            } else {
                LoginView(isLoggedIn: $isLoggedIn)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isLoggedIn)
    }
}
