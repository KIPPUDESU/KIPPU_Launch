enum SidebarDestination: Hashable {
    case launchHome
    case instanceEditor
    case instances
    case download(DownloadSection)
    case downloadCenter
    case settings
    case about

    var title: String {
        switch self {
        case .launchHome: "实例管理"
        case .instanceEditor: "编辑实例"
        case .instances: "实例列表"
        case let .download(category): category.title
        case .downloadCenter: "下载任务"
        case .settings: "设置"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .launchHome: "play.rectangle"
        case .instanceEditor: "cube"
        case .instances: "square.grid.2x2"
        case let .download(category): category.icon
        case .downloadCenter: "arrow.down.circle"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct LauncherNavigation {
    var destination: SidebarDestination = .instances
    var managementTab: InstanceManagementTab = .instance
    private(set) var editorOrigin: SidebarDestination = .launchHome

    var sidebarSelection: SidebarDestination {
        destination == .instanceEditor ? editorOrigin : destination
    }

    mutating func edit(_ tab: InstanceManagementTab, from origin: SidebarDestination) {
        managementTab = tab
        editorOrigin = origin
        destination = .instanceEditor
    }
}
