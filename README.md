# KIPPU Launch

用 SwiftUI 编写的 macOS 版 Minecraft Java 启动器。可以导入已有游戏实例，下载安装游戏与模组，管理资源包、光影和世界存档。

## 运行

使用带 macOS 27 SDK 的 Xcode 27 打开 [KIPPU_Launch.xcodeproj](KIPPU_Launch.xcodeproj)，选择 `KIPPU_Launch` 方案和本机 Mac，按 ⌘R 运行。首次构建时 SwiftPM 会下载 ZIPFoundation。应用的最低系统版本为 macOS 27。

## 从哪里开始读

应用入口创建实例库和下载中心，主窗口负责侧边栏导航。页面及其界面状态按功能放在 `Features` 下，游戏文件、网络请求和 Java 进程由本地 Swift 包 `KIPPULaunchCore` 处理。[应用入口](KIPPU_Launch/App/KIPPU_LaunchApp.swift) · [主窗口](KIPPU_Launch/App/ContentView.swift)

以点击「启动」为例，按这个顺序读可以跟完整个流程。

1. 启动页接收点击，控制器准备账号会话并更新界面上的启动状态。[InstanceLaunchPage](KIPPU_Launch/Features/Instances/InstanceLaunchPage.swift) · [LaunchController](KIPPU_Launch/Features/Launch/LaunchController.swift)
2. 核心库读取实例的版本配置、选择 Java，再组装工作目录和启动参数。[InstanceLaunchPlanner](KIPPULaunchCore/Sources/KIPPULaunchCore/Launch/InstanceLaunchPlanner.swift) · [LaunchPlan](KIPPULaunchCore/Sources/KIPPULaunchCore/Launch/LaunchPlan.swift)
3. 启动器创建游戏进程，读取标准输出和错误输出，进程结束后把退出原因交回界面。[GameLauncher](KIPPULaunchCore/Sources/KIPPULaunchCore/Launch/GameLauncher.swift)

| 想看什么 | 去哪里 |
| --- | --- |
| 窗口、导航和侧边栏 | [KIPPU_Launch/App](KIPPU_Launch/App) |
| 下载任务、实例管理、模组等页面 | [KIPPU_Launch/Features](KIPPU_Launch/Features) |
| 实例扫描与登记、版本解析、安装和启动 | [核心库源码](KIPPULaunchCore/Sources/KIPPULaunchCore) |
| 应用图标和界面图片 | [KIPPU_Launch/Resources](KIPPU_Launch/Resources) |
| 登录应用 ID 和关于页链接 | [Config/KIPPU-Launch-Info.plist](Config/KIPPU-Launch-Info.plist) |

单独编译核心库可在仓库根目录执行 `swift build --package-path KIPPULaunchCore`。[包定义](KIPPULaunchCore/Package.swift)
