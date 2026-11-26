import Foundation
import UniformTypeIdentifiers

public enum DroppedPayload: Sendable, Hashable {
    case authlibInjectorCard(AuthlibInjectorCard)
    case file(URL)
    case unrecognised(String)
}

extension DroppedPayload {
    public static let dropHintTitle = "松开以添加"
    public static let authlibCardHint = "把这个外置登录服务器加到启动器"
    public static let fileHint = "安装整合包或模组"
}

/// 跨队列只使用 NSItemProvider 提供的异步加载接口
public struct DroppedItems: @unchecked Sendable {
    public let providers: [NSItemProvider]

    public init(_ providers: [NSItemProvider]) {
        self.providers = providers
    }
}

public enum DropResolver {
    static let textTypeIdentifiers = [
        UTType.utf8PlainText.identifier,
        UTType.plainText.identifier,
        UTType.text.identifier,
    ]

    public static let acceptedContentTypes: [UTType] = [
        .utf8PlainText, .plainText, .text, .url, .fileURL,
    ]

    /// 浏览器可能同时提供网页链接和卡片文本 先读文本才能拿到登录地址
    public static func resolve(_ items: DroppedItems) async -> DroppedPayload? {
        var firstUnrecognised: DroppedPayload?

        for provider in items.providers {
            let texts = await loadTexts(from: provider)

            for text in texts {
                if let card = AuthlibInjectorCard.parse(text) {
                    return .authlibInjectorCard(card)
                }
            }

            if let url = await loadFileURL(from: provider) {
                return .file(url)
            }

            if firstUnrecognised == nil, let text = texts.first {
                firstUnrecognised = .unrecognised(text)
            }
            if firstUnrecognised == nil, let url = await loadURL(from: provider) {
                firstUnrecognised = .unrecognised(url.absoluteString)
            }
        }
        return firstUnrecognised
    }

    static func loadTexts(from provider: NSItemProvider) async -> [String] {
        var results: [String] = []
        for identifier in textTypeIdentifiers {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let text = await loadString(identifier: identifier, from: provider), !text.isEmpty {
                results.append(text)
            }
        }
        return results
    }

    private static func loadString(identifier: String, from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                switch item {
                case let text as String:
                    continuation.resume(returning: text)
                case let data as Data:
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                case let url as URL:
                    continuation.resume(returning: url.absoluteString)
                case let url as NSURL:
                    continuation.resume(returning: url.absoluteString)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let value as URL: url = value
                case let value as NSURL: url = value as URL
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                default: url = nil
                }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    static func loadURL(from provider: NSItemProvider) async -> URL? {
        let identifier = UTType.url.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                switch item {
                case let value as URL: continuation.resume(returning: value)
                case let value as NSURL: continuation.resume(returning: value as URL)
                case let data as Data:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let text as String:
                    continuation.resume(returning: URL(string: text))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
