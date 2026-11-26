import AppKit
import KIPPULaunchCore
import SwiftUI

struct AccountSheet: View {
    @Bindable var controller: AccountController
    var prefilledServer: String?

    private enum Mode: Equatable {
        case list
        case addYggdrasil
        case microsoft
        case addOffline
    }

    @State private var mode: Mode = .list
    @State private var didApplyPrefill = false

    @State private var clientID = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var server = "littleskin.cn"
    @State private var username = ""
    @State private var password = ""
    @State private var offlineName = ""

    @FocusState private var focusedField: LoginField?

    private enum LoginField { case username, password, offline }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let problem = controller.problem {
                problemBanner(problem)
            }

            Group {
                switch mode {
                case .list:
                    if controller.accounts.isEmpty { emptyState } else { accountList }
                case .microsoft: microsoftForm
                case .addYggdrasil:
                    yggdrasilForm
                case .addOffline:
                    offlineForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if mode == .list {
                Divider()
                footer
            }
        }
        .frame(width: 540, height: 480)
        .onChange(of: mode) { _, newMode in
            guard newMode == .list else { return }
            username = ""
            password = ""
        }
        .onDisappear { loginTask?.cancel() }
        .onAppear {
            guard !didApplyPrefill, let prefilledServer, !prefilledServer.isEmpty else { return }
            server = prefilledServer
            mode = .addYggdrasil
            didApplyPrefill = true
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .list ? "账号" : "添加账号")
                    .font(.headline)
                Text("密码不会被保存。登录后只有服务端签发的令牌会进 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mode != .list {
                Button("返回") { backToList() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("还没有账号")
                .font(.title3)
            Text("没有账号时，游戏会以离线身份启动。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountList: some View {
        List {
            ForEach(controller.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: controller.activeAccountID == account.id
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            controller.activeAccountID == account.id
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.headline)
                        if let detail = account.detailLine {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if account.kind == .yggdrasil, account.availableProfiles.count > 1 {
                        Menu("切换角色") {
                            ForEach(account.availableProfiles, id: \.id) { profile in
                                Button(profile.name) {
                                    Task { await controller.selectProfile(profile, for: account) }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Button("移除", role: .destructive) {
                        Task { await controller.remove(account) }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await controller.setActive(account) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Button("Microsoft 登录") {
                clientID = controller.microsoftClientID
                mode = .microsoft
                if !clientID.isEmpty { requestMicrosoftCode() }
            }
            Button {
                mode = .addYggdrasil
            } label: {
                Label("外置登录", systemImage: "person.badge.key")
            }
            Button {
                offlineName = controller.activeAccount?.playerName ?? ""
                mode = .addOffline
            } label: {
                Label("离线账户", systemImage: "person")
            }
            Spacer()
        }
        .padding(12)
    }

    private var microsoftForm: some View {
        Form {
            if let code = controller.deviceCode {
                LabeledContent("登录码") {
                    Text(code.user_code).font(.title2.monospaced()).textSelection(.enabled)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.user_code, forType: .string)
                    }
                }
                Link("打开 Microsoft 登录网页", destination: code.verification_uri)
                ProgressView("等候浏览器授权…")
            } else if controller.isSigningIn {
                ProgressView("正在向 Microsoft 申请登录码…")
            } else {
                if controller.microsoftClientID.isEmpty {
                    TextField("应用程序（客户端）ID", text: $clientID)
                    Text("项目维护者需要为启动器注册应用并取得 Minecraft Java 服务的访问资格。").font(.caption)
                    Link("注册 Microsoft 应用", destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                    Link("申请 Minecraft Java 服务访问权限", destination: URL(string: "https://aka.ms/mce-reviewappid")!)
                } else {
                    DisclosureGroup("启动器应用配置") { TextField("应用程序（客户端）ID", text: $clientID) }
                }
                Button("获取登录码", action: requestMicrosoftCode)
                    .disabled(UUID(uuidString: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            }
        }.formStyle(.grouped)
    }

    private func requestMicrosoftCode() {
        loginTask = Task {
            if await controller.microsoftSignIn(clientID: clientID) { backToList() }
        }
    }

    private var yggdrasilForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("外置登录")
                    .font(.title3.weight(.semibold))

                Text("支持 LittleSkin 等 Yggdrasil 服务。只填域名也可以，会自动发现 API 地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("服务器") {
                    TextField("littleskin.cn", text: $server)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("邮箱或用户名") {
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                }
                LabeledContent("密码") {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                        .onSubmit { submitYggdrasilLogin() }
                }

                Text("密码仅用于这次登录，不会被写入磁盘。如果这个账号开启了双重验证，请使用皮肤站生成的专用密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if controller.isSigningIn {
                        ProgressView().controlSize(.small)
                        Text("正在登录…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消") { backToList() }
                    Button("登录") { submitYggdrasilLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || password.isEmpty || controller.isSigningIn)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear {
            // 表单挂载后焦点请求才会生效
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedField = .username
            }
        }
    }

    private var offlineForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("离线账户")
                    .font(.title3.weight(.semibold))

                Text("离线身份下，玩家名会决定你的 UUID —— 它决定加载哪一份玩家数据。请填写你平时用的名字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("玩家名") {
                    TextField("", text: $offlineName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .offline)
                        .onSubmit { submitOfflineAccount() }
                }

                HStack {
                    Spacer()
                    Button("取消") { backToList() }
                    Button("添加") { submitOfflineAccount() }
                        .buttonStyle(.borderedProminent)
                        .disabled(offlineName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedField = .offline
            }
        }
    }

    private func submitYggdrasilLogin() {
        guard !username.isEmpty, !password.isEmpty, !controller.isSigningIn else { return }
        let server = self.server
        let name = self.username
        let secret = self.password
        Task {
            await controller.signIn(server: server, username: name, password: secret)
            if controller.problem == nil { backToList() }
        }
    }

    private func submitOfflineAccount() {
        let name = offlineName
        Task {
            await controller.addOfflineAccount(playerName: name)
            if controller.problem == nil { backToList() }
        }
    }

    private func backToList() {
        loginTask?.cancel()
        mode = .list
        focusedField = nil
        controller.problem = nil
    }

    private func problemBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.problem = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.orange.opacity(0.10))
    }
}
