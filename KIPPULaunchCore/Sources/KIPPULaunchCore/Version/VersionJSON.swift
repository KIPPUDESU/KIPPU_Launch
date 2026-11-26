import Foundation

public struct VersionJSON: Codable, Sendable {
    public var id: String
    public var inheritsFrom: String?
    public var mainClass: String?
    public var type: String?
    /// 旧版使用 assets 字段标识素材索引
    public var assets: String?
    public var assetIndex: AssetIndexReference?
    public var downloads: Downloads?
    public var javaVersion: JavaVersion?
    public var libraries: [Library]?
    public var arguments: Arguments?
    public var minecraftArguments: String?
    public var logging: Logging?
    public var complianceLevel: Int?
    public var minimumLauncherVersion: Int?
    public var releaseTime: String?
    public var time: String?
    /// jar 字段可以指向父版本
    public var jar: String?

    public struct AssetIndexReference: Codable, Sendable {
        public var id: String
        public var sha1: String?
        public var size: Int?
        public var totalSize: Int?
        public var url: String?
    }

    public struct Downloads: Codable, Sendable {
        public var client: Download?
        public var server: Download?
    }

    public struct Download: Codable, Sendable {
        public var sha1: String?
        public var size: Int?
        public var url: String
    }

    public struct JavaVersion: Codable, Sendable {
        public var component: String?
        public var majorVersion: Int?
    }

    public struct Logging: Codable, Sendable {
        public var client: Client?

        public struct Client: Codable, Sendable {
            public var argument: String
            public var file: Download
            public var type: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, inheritsFrom, mainClass, type, assets, assetIndex, downloads
        case javaVersion, libraries, arguments, minecraftArguments, logging
        case complianceLevel, minimumLauncherVersion, releaseTime, time, jar
    }
}

public struct Arguments: Codable, Sendable {
    public var game: [ArgumentValue]?
    public var jvm: [ArgumentValue]?
    public var defaultUserJVM: [ArgumentValue]?

    enum CodingKeys: String, CodingKey {
        case game, jvm
        case defaultUserJVM = "default-user-jvm"
    }

    public init(game: [ArgumentValue]? = nil, jvm: [ArgumentValue]? = nil, defaultUserJVM: [ArgumentValue]? = nil) {
        self.game = game
        self.jvm = jvm
        self.defaultUserJVM = defaultUserJVM
    }
}

public enum ArgumentValue: Sendable {
    case plain(String)
    case conditional(rules: [Rule], value: StringOrArray)
}

extension ArgumentValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
            return
        }
        let object = try container.decode(ConditionalForm.self)
        self = .conditional(rules: object.rules ?? [], value: object.value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .plain(text):
            try container.encode(text)
        case let .conditional(rules, value):
            try container.encode(ConditionalForm(rules: rules, value: value))
        }
    }

    private struct ConditionalForm: Codable {
        var rules: [Rule]?
        var value: StringOrArray
    }
}

public enum StringOrArray: Sendable {
    case one(String)
    case many([String])

    public var values: [String] {
        switch self {
        case let .one(text): [text]
        case let .many(list): list
        }
    }
}

extension StringOrArray: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .one(text)
        } else {
            self = .many(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .one(text): try container.encode(text)
        case let .many(list): try container.encode(list)
        }
    }
}

public struct Rule: Codable, Sendable {
    public var action: Action
    public var os: OperatingSystem?
    public var features: [String: Bool]?

    public enum Action: String, Codable, Sendable {
        case allow
        case disallow
    }

    public struct OperatingSystem: Codable, Sendable {
        /// Mojang 使用 osx 标识 macOS
        public var name: String?
        public var version: String?
        public var arch: String?
        public var versionRange: VersionRange?
    }

    public struct VersionRange: Codable, Sendable {
        public var min: String?
        public var max: String?
    }
}

public struct Library: Codable, Sendable {
    public var name: String
    public var downloads: Downloads?
    public var natives: [String: String]?
    public var extract: Extract?
    public var rules: [Rule]?
    public var url: String?

    public struct Downloads: Codable, Sendable {
        public var artifact: Artifact?
        public var classifiers: [String: Artifact]?
    }

    public struct Artifact: Codable, Sendable {
        public var path: String?
        public var sha1: String?
        public var size: Int?
        public var url: String
    }

    public struct Extract: Codable, Sendable {
        public var exclude: [String]?
    }

    public init(name: String, downloads: Downloads? = nil, natives: [String: String]? = nil, extract: Extract? = nil, rules: [Rule]? = nil, url: String? = nil) {
        self.name = name
        self.downloads = downloads
        self.natives = natives
        self.extract = extract
        self.rules = rules
        self.url = url
    }
}
