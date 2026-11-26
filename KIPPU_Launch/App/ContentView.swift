import KIPPULaunchCore
import SwiftUI

struct ContentView: View {
    let library: InstanceLibrary
    @Environment(LauncherBackgrounds.self) private var backgrounds
    @Environment(DownloadCenter.self) private var downloads
    @State private var launcher = LaunchController()
    @State private var accounts = AccountController()

    @State private var navigation = LauncherNavigation()
    @AppStorage("launchHomeInstanceID") private var preferredInstanceID = ""

    private var activeInstance: InstanceRecord? {
        library.instances.first { $0.id.uuidString == preferredInstanceID }
            ?? library.instances.first { !$0.isMissing } ?? library.instances.first
    }
    private struct BackgroundEditor: Identifiable {
        let id = UUID()
        let scope: BackgroundScope
        let instanceID: UUID?
        let instanceName: String?
    }
    @State private var backgroundEditor: BackgroundEditor?
    @State private var isShowingAccounts = false
    @State private var isSidebarVisible = true
    @State private var prefilledServer: String?

    @State private var pendingCard: AuthlibInjectorCard?
    private struct DroppedPack: Identifiable {
        let url: URL
        var id: URL { url }
    }
    @State private var droppedPack: DroppedPack?
    @State private var isDropTargeted = false

    var body: some View {
        let instanceStyle = instanceBackground
        HStack(spacing: 0) {
            if isSidebarVisible {
                SidebarView(
                    destination: Binding(get: { navigation.sidebarSelection }, set: { navigation.destination = $0 }),
                    account: accounts.activeAccount,
                    skinHead: accounts.skinHead(for: accounts.activeAccount),
                    onShowAccounts: { isShowingAccounts = true }
                )
                .transition(.move(edge: .leading))
            }
            detail
                .background(Color.black.opacity(0.5))
                .background { wallpaper(instanceStyle) }
        }
        .background {
            if instanceStyle == nil {
                wallpaper(backgrounds.style(for: .application))
            } else if isSidebarVisible {
                // 全局背景按窗口大小绘制再裁出侧栏
                wallpaper(backgrounds.style(for: .application))
                    .mask(alignment: .leading) { Rectangle().frame(width: SidebarView.width) }
            }
        }
        .background { Rectangle().fill(.regularMaterial) }
        .frame(minWidth: 880, minHeight: 560)
        // 隐藏标题栏后 SwiftUI 仍会预留顶部安全区
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.sidebarChrome, SidebarChrome(isVisible: isSidebarVisible) {
            withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
        })
        .overlay { if isDropTargeted { dropHighlight } }
        .onDrop(of: DropResolver.acceptedContentTypes, isTargeted: $isDropTargeted) { providers in
            let items = DroppedItems(providers)
            Task { if let result = await DropResolver.resolve(items) { handleDrop(result) } }
            return true
        }
        .sheet(item: $backgroundEditor) { editor in
            BackgroundSettingsSheet(backgrounds: backgrounds, scope: editor.scope, instanceID: editor.instanceID,
                                    instanceName: editor.instanceName)
        }
        .sheet(item: $droppedPack) { pack in
            InstallSheet(pack: pack.url, runtimes: launcher.javaRuntimes, onInstalled: library.registerInstalled)
        }
        .alert(
            "添加外置登录服务器？",
            isPresented: Binding(
                get: { pendingCard != nil },
                set: { if !$0 { pendingCard = nil } }
            ),
            presenting: pendingCard
        ) { card in
            Button("添加") {
                prefilledServer = card.apiRoot.absoluteString
                pendingCard = nil
                isShowingAccounts = true
            }
            Button("取消", role: .cancel) { pendingCard = nil }
        } message: { card in
            // 拖入的网页可以指定登录服务器
            Text("\(card.apiRoot.absoluteString)\n\n确认后会打开账号界面，在那里登录。")
        }
        .task {
            launcher.downloads = downloads
            launcher.didLaunch = { [library] in library.markLaunched($0) }
            library.load()
            await accounts.load()

            launcher.accountSessionProvider = { [accounts] in
                try await accounts.sessionForActiveAccount()
            }
        }
        .task { await launcher.refreshJavaRuntimes() }
        .onChange(of: activeInstance?.id, initial: true) { _, id in
            if let id { preferredInstanceID = id.uuidString }
        }
        .task(id: accounts.activeAccountID) {
            await accounts.ensureSkinLoaded(for: accounts.activeAccount)
        }
        .sheet(isPresented: $isShowingAccounts, onDismiss: { prefilledServer = nil }) {
            AccountSheet(controller: accounts, prefilledServer: prefilledServer)
        }
        .sheet(isPresented: Binding(
            get: { launcher.isShowingLog },
            set: { if !$0 { launcher.dismissLog() } }
        )) {
            LaunchLogView(launcher: launcher, library: library)
                .id(launcher.logInstanceID)
        }
    }

    private func openBackgroundEditor(_ scope: BackgroundScope) {
        backgroundEditor = BackgroundEditor(scope: scope, instanceID: activeInstance?.id,
                                            instanceName: activeInstance.map { library.displayName(for: $0) })
    }

    private var instanceBackground: BackgroundStyle? {
        guard navigation.destination == .launchHome || navigation.destination == .instanceEditor,
              let activeInstance else { return nil }
        return backgrounds.instanceBackground(for: activeInstance.id)
    }

    @ViewBuilder private func wallpaper(_ style: BackgroundStyle?) -> some View {
        if let style, style.transparency < 100, let url = backgrounds.url(for: style) {
            BackgroundImageLayer(style: style, url: url)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.destination {
        case .instances, .launchHome, .instanceEditor:
            InstanceLibraryView(library: library, launcher: launcher, navigation: $navigation,
                                activeInstance: activeInstance,
                                accountName: accounts.activeAccount?.displayName ?? "离线 · " + launcher.playerName,
                                accountHead: accounts.skinHead(for: accounts.activeAccount),
                                selectInstance: { preferredInstanceID = $0.uuidString },
                                showAccounts: { isShowingAccounts = true },
                                editBackground: { openBackgroundEditor(.instance($0)) })
        case let .download(category):
            DownloadsView(section: category, library: library, launcher: launcher)
        case .downloadCenter:
            DownloadCenterView()
        case .settings:
            SettingsView(launcher: launcher, editBackground: { openBackgroundEditor(.application) })
        case .about:
            AboutView()
        }
    }

    private var dropHighlight: some View {
        ZStack {
            Rectangle()
                .fill(.tint.opacity(0.10))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(10)
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30))
                Text(DroppedPayload.dropHintTitle)
                    .font(.headline)
                Text("添加登录卡片或安装 .mrpack 整合包")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .allowsHitTesting(false)
    }

    private func handleDrop(_ item: DroppedPayload) {
        switch item {
        case let .authlibInjectorCard(card):
            pendingCard = card

        case let .file(url):
            if url.pathExtension.lowercased() == "mrpack" {
                navigation.destination = .download(.modpack)
                droppedPack = DroppedPack(url: url)
            } else {
                navigation.destination = .instances
                launcher.problem = "请选择 .mrpack 格式的整合包。"
            }

        case let .unrecognised(text):
            let preview = text.prefix(60)
            launcher.problem = "认不出拖入的内容：\(preview)"
        }
    }
}
