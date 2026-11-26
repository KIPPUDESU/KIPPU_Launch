enum DownloadSection: String, CaseIterable, Identifiable {
    case game
    case modpack
    case mod
    case resourcePack
    case shader
    case world

    var id: Self { self }

    var title: String {
        switch self {
        case .game: "游戏"
        case .modpack: "整合包"
        case .mod: "模组"
        case .resourcePack: "资源包"
        case .shader: "光影"
        case .world: "世界"
        }
    }

    var icon: String {
        switch self {
        case .game: "gamecontroller"
        case .modpack: "shippingbox"
        case .mod: "puzzlepiece.extension"
        case .resourcePack: "square.3.layers.3d"
        case .shader: "sun.max"
        case .world: "globe"
        }
    }
}
