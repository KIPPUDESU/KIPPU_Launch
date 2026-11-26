// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "KIPPULaunchCore",
    // 部署版本须与 Xcode 工程一致
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "KIPPULaunchCore", targets: ["KIPPULaunchCore"]),
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "KIPPULaunchCore", dependencies: ["ZIPFoundation"]),
    ],
    swiftLanguageModes: [.v6]
)
