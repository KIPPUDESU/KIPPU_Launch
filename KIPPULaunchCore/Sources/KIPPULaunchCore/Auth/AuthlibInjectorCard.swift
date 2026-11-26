import Foundation

public struct AuthlibInjectorCard: Sendable, Hashable {
    public static let schemePrefix = "authlib-injector:yggdrasil-server:"

    public let apiRoot: URL

    public init(apiRoot: URL) {
        self.apiRoot = apiRoot
    }

    /// 有些浏览器拖出的地址带换行或省略了百分号编码
    public static func parse(_ payload: String) -> AuthlibInjectorCard? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count > schemePrefix.count else { return nil }
        guard trimmed.prefix(schemePrefix.count).lowercased() == schemePrefix.lowercased() else { return nil }

        let encoded = String(trimmed.dropFirst(schemePrefix.count))
        let decoded = encoded.removingPercentEncoding ?? encoded

        guard let url = URL(string: decoded),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }

        return AuthlibInjectorCard(apiRoot: url)
    }

    public var payload: String {
        let encoded = apiRoot.absoluteString.addingPercentEncoding(
            withAllowedCharacters: Self.percentEncodingAllowed
        ) ?? apiRoot.absoluteString
        return Self.schemePrefix + encoded
    }

    /// 网页卡片使用 encodeURIComponent 处理这些标点
    private static let percentEncodingAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return allowed
    }()
}
