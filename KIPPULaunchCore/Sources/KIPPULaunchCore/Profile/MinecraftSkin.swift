import CoreGraphics
import Foundation
import ImageIO

public struct MinecraftProfileTextures: Sendable, Hashable {
    public var skinURL: URL?
    public var capeURL: URL?

    public init(skinURL: URL? = nil, capeURL: URL? = nil) {
        self.skinURL = skinURL
        self.capeURL = capeURL
    }
}

public enum MinecraftSkin {
    public static let headRect = CGRect(x: 8, y: 8, width: 8, height: 8)

    public static let hatRect = CGRect(x: 40, y: 8, width: 8, height: 8)

    /// 旧版半高皮肤仍有帽子层
    public static let validSizes = [(width: 64, height: 64), (width: 64, height: 32)]

    public static func headImage(from skin: CGImage) -> CGImage? {
        guard isValidSkin(skin) else { return nil }
        return skin.cropping(to: headRect)
    }

    public static func hatImage(from skin: CGImage) -> CGImage? {
        guard isValidSkin(skin) else { return nil }
        return skin.cropping(to: hatRect)
    }

    public static func isValidSkin(_ skin: CGImage) -> Bool {
        validSizes.contains { $0.width == skin.width && $0.height == skin.height }
    }

    public static func decodeSkin(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
