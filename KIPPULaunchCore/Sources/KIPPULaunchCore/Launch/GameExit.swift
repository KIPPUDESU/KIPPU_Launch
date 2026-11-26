import Foundation

public enum GameExit: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)
    case stoppedByPlayer

    public var code: Int32 {
        switch self {
        case let .exited(code), let .signalled(code): code
        case .stoppedByPlayer: SIGKILL
        }
    }

    public var marker: String {
        switch self {
        case let .exited(code): "— 游戏已退出（状态码 \(code)）—"
        case let .signalled(signal): "— 游戏被信号终止（信号 \(signal)）—"
        case .stoppedByPlayer: "— 玩家已从启动器强制退出游戏 —"
        }
    }

    public init?(marker: String) {
        if marker == Self.stoppedByPlayer.marker { self = .stoppedByPlayer }
        else if let m = marker.wholeMatch(of: /— 游戏已退出（状态码 (-?\d+)）—/), let code = Int32(m.1) { self = .exited(code) }
        else if let m = marker.wholeMatch(of: /— 游戏被信号终止（信号 (\d+)）—/), let signal = Int32(m.1) { self = .signalled(signal) }
        else { return nil }
    }

    /// HotSpot 有时会把信号编号加上 128 作为退出码
    public var interruption: String? {
        switch self {
        case .stoppedByPlayer: return "玩家已从启动器强制退出游戏"
        case .signalled(SIGKILL), .signalled(SIGTERM), .signalled(SIGINT): return "游戏被外部终止"
        case .exited(137), .exited(143), .exited(130): return "游戏可能被外部终止"
        default: return nil
        }
    }

    public var detail: String {
        switch self {
        case .stoppedByPlayer: return "启动器已按你的要求结束游戏进程。"
        case let .signalled(signal): return "macOS 记录到终止信号 \(signal)。玩家强制退出或系统结束进程均可能产生此信号。"
        case let .exited(code):
            let signal = code - 128
            let name = signal == SIGKILL ? "SIGKILL" : (signal == SIGINT ? "SIGINT" : "SIGTERM")
            return "状态码 \(code) 通常表示 JVM 收到了 \(name)（\(signal)）。玩家强制退出和系统结束进程均可能产生此结果。"
        }
    }
}
