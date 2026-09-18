import Foundation

public enum SystemBinding: String, CaseIterable, Codable, Hashable {
    case shortL3 = "short_l3"
    case longL3 = "long_l3"
    case share
}

public enum StickInput: String, CaseIterable, Codable, Hashable {
    case leftUp = "left_up"
    case leftDown = "left_down"
    case leftLeft = "left_left"
    case leftRight = "left_right"
    case rightUp = "right_up"
    case rightDown = "right_down"
    case rightLeft = "right_left"
    case rightRight = "right_right"
}

public enum ScrollDirection: String, Codable, Hashable {
    case up
    case down
    case left
    case right
}

public enum StickMapping: Equatable, Codable {
    case none
    case key(KeyChord)
    case scroll(ScrollDirection)

    private enum Kind: String, Codable {
        case none
        case key
        case scroll
    }

    private struct Wire: Codable {
        let kind: Kind
        let keyCode: UInt16?
        let modifiers: UInt8?
        let direction: ScrollDirection?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.kind {
        case .none:
            self = .none
        case .key:
            guard let keyCode = wire.keyCode else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "key stick mapping has no keyCode"
                    )
                )
            }
            self = .key(
                KeyChord(
                    keyCode: keyCode,
                    modifiers: KeyModifiers(rawValue: wire.modifiers ?? 0)
                )
            )
        case .scroll:
            guard let direction = wire.direction else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "scroll stick mapping has no direction"
                    )
                )
            }
            self = .scroll(direction)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            try Wire(
                kind: .none,
                keyCode: nil,
                modifiers: nil,
                direction: nil
            ).encode(to: encoder)
        case let .key(chord):
            try Wire(
                kind: .key,
                keyCode: chord.keyCode,
                modifiers: chord.modifiers.rawValue,
                direction: nil
            ).encode(to: encoder)
        case let .scroll(direction):
            try Wire(
                kind: .scroll,
                keyCode: nil,
                modifiers: nil,
                direction: direction
            ).encode(to: encoder)
        }
    }
}

public struct VibestickConfiguration: Equatable {
    public static let currentSchemaVersion = 2

    public internal(set) var schemaVersion: Int
    public internal(set) var systemBindings: [SystemBinding: BindingAction]
    public internal(set) var globalFallbackBindings: [PadButton: BindingAction]
    public internal(set) var appProfiles: [String: [PadButton: BindingAction]]
    public internal(set) var herdrLayerOverrides: [PadButton: BindingAction]
    public internal(set) var stickMappings: [StickInput: StickMapping]

    static let defaults = VibestickConfiguration(
        schemaVersion: currentSchemaVersion,
        systemBindings: [
            .shortL3: .key(
                KeyChord(
                    keyCode: 50,
                    modifiers: [.command, .control, .option, .shift]
                )
            ),
            .longL3: .switchApp,
            .share: .overlay,
        ],
        globalFallbackBindings: [:],
        appProfiles: [:],
        herdrLayerOverrides: [:],
        stickMappings: [
            .leftUp: .key(KeyChord(keyCode: 126)),
            .leftDown: .key(KeyChord(keyCode: 125)),
            .leftLeft: .key(KeyChord(keyCode: 123)),
            .leftRight: .key(KeyChord(keyCode: 124)),
            .rightUp: .scroll(.up),
            .rightDown: .scroll(.down),
            .rightLeft: .scroll(.left),
            .rightRight: .scroll(.right),
        ]
    )
}

public struct SkippedConfigurationEntry: Equatable {
    public let path: String
    public let reason: String

    init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ConfigurationMigrationReport: Equatable {
    public let backupURL: URL
    public let skippedEntries: [SkippedConfigurationEntry]

    init(backupURL: URL, skippedEntries: [SkippedConfigurationEntry]) {
        self.backupURL = backupURL
        self.skippedEntries = skippedEntries
    }
}

public enum ConfigurationLoadOutcome: Equatable {
    case notLoaded
    case noFile
    case loaded
    case migrated(ConfigurationMigrationReport)
    case corrupt(String)
    case unsupportedFutureVersion(Int)
    case migrationFailed(String)

    var allowsSaving: Bool {
        switch self {
        case .notLoaded, .noFile, .loaded, .migrated:
            return true
        case .corrupt, .unsupportedFutureVersion, .migrationFailed:
            return false
        }
    }

    var operatorNotice: String? {
        switch self {
        case .notLoaded, .noFile, .loaded:
            return nil
        case let .migrated(report):
            if report.skippedEntries.isEmpty {
                return "Migrated prototype configuration; backup: \(report.backupURL.path)"
            }
            let skipped = report.skippedEntries
                .map { "\($0.path) (\($0.reason))" }
                .joined(separator: ", ")
            return "Migrated with \(report.skippedEntries.count) skipped entr\(report.skippedEntries.count == 1 ? "y" : "ies"): \(skipped). Backup: \(report.backupURL.path)"
        case let .corrupt(reason):
            return "Configuration is corrupt and was left unchanged: \(reason)"
        case let .unsupportedFutureVersion(version):
            return "Configuration schema \(version) is newer than this Vibestick; file left unchanged"
        case let .migrationFailed(reason):
            return "Configuration migration failed; file left unchanged: \(reason)"
        }
    }
}

private struct PersistedConfiguration: Codable {
    let schemaVersion: Int
    let systemBindings: [String: BindingAction]
    let globalFallbackBindings: [String: BindingAction]
    let appProfiles: [String: [String: BindingAction]]
    let herdrLayerOverrides: [String: BindingAction]
    let stickMappings: [String: StickMapping]

    init(configuration: VibestickConfiguration) {
        schemaVersion = configuration.schemaVersion
        systemBindings = configuration.systemBindings.stringKeyed
        globalFallbackBindings = configuration.globalFallbackBindings.stringKeyed
        appProfiles = configuration.appProfiles.mapValues(\.stringKeyed)
        herdrLayerOverrides = configuration.herdrLayerOverrides.stringKeyed
        stickMappings = configuration.stickMappings.stringKeyed
    }

    func configuration(expectedSchemaVersion: Int) throws -> VibestickConfiguration {
        guard schemaVersion == expectedSchemaVersion else {
            throw ConfigurationPersistenceError.invalidSchemaVersion(schemaVersion)
        }
        return VibestickConfiguration(
            schemaVersion: schemaVersion,
            systemBindings: try systemBindings.typedKeys(as: SystemBinding.self),
            globalFallbackBindings: try globalFallbackBindings.typedKeys(as: PadButton.self),
            appProfiles: try appProfiles.mapValues { try $0.typedKeys(as: PadButton.self) },
            herdrLayerOverrides: try herdrLayerOverrides.typedKeys(as: PadButton.self),
            stickMappings: try stickMappings.typedKeys(as: StickInput.self)
        )
    }
}

private extension Dictionary where Key: RawRepresentable, Key.RawValue == String {
    var stringKeyed: [String: Value] {
        reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}

private extension Dictionary where Key == String {
    func typedKeys<T: RawRepresentable>(as type: T.Type) throws -> [T: Value]
    where T.RawValue == String, T: Hashable {
        try reduce(into: [:]) { result, entry in
            guard let key = T(rawValue: entry.key) else {
                throw ConfigurationPersistenceError.unknownKey(entry.key)
            }
            result[key] = entry.value
        }
    }
}

private enum ConfigurationPersistenceError: LocalizedError {
    case invalidRoot
    case invalidSchemaVersion(Int)
    case unknownKey(String)
    case unrecognizedPrototype

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "the top level must be a JSON object"
        case let .invalidSchemaVersion(version):
            return "unsupported schema version \(version)"
        case let .unknownKey(key):
            return "unrecognized configuration key \(key)"
        case .unrecognizedPrototype:
            return "the file is neither a versioned configuration nor a recognizable prototype configuration"
        }
    }
}

struct ConfigurationReadResult {
    let configuration: VibestickConfiguration
    let outcome: ConfigurationLoadOutcome
}

enum ConfigurationPersistence {
    static func load(from url: URL) -> ConfigurationReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ConfigurationReadResult(
                configuration: .defaults,
                outcome: .noFile
            )
        }

        let originalData: Data
        let root: [String: Any]
        do {
            originalData = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
            else {
                throw ConfigurationPersistenceError.invalidRoot
            }
            root = object
        } catch {
            return ConfigurationReadResult(
                configuration: .defaults,
                outcome: .corrupt(error.localizedDescription)
            )
        }

        if let rawVersion = root["schemaVersion"] {
            guard let version = integerSchemaVersion(rawVersion) else {
                return ConfigurationReadResult(
                    configuration: .defaults,
                    outcome: .corrupt("schemaVersion must be an integer")
                )
            }
            guard version <= VibestickConfiguration.currentSchemaVersion else {
                return ConfigurationReadResult(
                    configuration: .defaults,
                    outcome: .unsupportedFutureVersion(version)
                )
            }
            if version == 1 {
                do {
                    let migration = try migrateVersionOne(
                        originalData: originalData,
                        at: url
                    )
                    return ConfigurationReadResult(
                        configuration: migration.configuration,
                        outcome: .migrated(migration.report)
                    )
                } catch {
                    return ConfigurationReadResult(
                        configuration: .defaults,
                        outcome: .migrationFailed(error.localizedDescription)
                    )
                }
            }
            guard version == VibestickConfiguration.currentSchemaVersion else {
                return ConfigurationReadResult(
                    configuration: .defaults,
                    outcome: .corrupt("unsupported schema version \(version)")
                )
            }

            do {
                let wire = try JSONDecoder().decode(PersistedConfiguration.self, from: originalData)
                return ConfigurationReadResult(
                    configuration: try wire.configuration(
                        expectedSchemaVersion: VibestickConfiguration.currentSchemaVersion
                    ),
                    outcome: .loaded
                )
            } catch {
                return ConfigurationReadResult(
                    configuration: .defaults,
                    outcome: .corrupt(error.localizedDescription)
                )
            }
        }

        do {
            let migration = try migratePrototype(root: root, originalData: originalData, at: url)
            return ConfigurationReadResult(
                configuration: migration.configuration,
                outcome: .migrated(migration.report)
            )
        } catch {
            return ConfigurationReadResult(
                configuration: .defaults,
                outcome: .migrationFailed(error.localizedDescription)
            )
        }
    }

    static func save(_ configuration: VibestickConfiguration, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedConfiguration(configuration: configuration))
        try data.write(to: url, options: .atomic)
    }

    private static func integerSchemaVersion(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let integer = number.intValue
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }

    private static func migrateVersionOne(
        originalData: Data,
        at url: URL
    ) throws -> (
        configuration: VibestickConfiguration,
        report: ConfigurationMigrationReport
    ) {
        let wire = try JSONDecoder().decode(PersistedConfiguration.self, from: originalData)
        var configuration = try wire.configuration(expectedSchemaVersion: 1)
        configuration.schemaVersion = VibestickConfiguration.currentSchemaVersion
        preserveGhosttyProfilesInHerdr(configuration: &configuration)

        let backupURL = nextBackupURL(for: url)
        try originalData.write(to: backupURL, options: .withoutOverwriting)
        try save(configuration, to: url)
        return (
            configuration,
            ConfigurationMigrationReport(backupURL: backupURL, skippedEntries: [])
        )
    }

    private static func migratePrototype(
        root: [String: Any],
        originalData: Data,
        at url: URL
    ) throws -> (
        configuration: VibestickConfiguration,
        report: ConfigurationMigrationReport
    ) {
        guard root["global"] != nil || root["apps"] != nil else {
            throw ConfigurationPersistenceError.unrecognizedPrototype
        }

        var configuration = VibestickConfiguration.defaults
        var skipped: [SkippedConfigurationEntry] = []

        for key in root.keys where key != "global" && key != "apps" {
            skipped.append(
                SkippedConfigurationEntry(
                    path: key,
                    reason: "unknown prototype field"
                )
            )
        }

        if let rawGlobal = root["global"] as? [String: Any] {
            migrateBindings(
                rawGlobal,
                path: "global",
                into: &configuration.globalFallbackBindings,
                skipped: &skipped
            )
        } else {
            skipped.append(
                SkippedConfigurationEntry(
                    path: "global",
                    reason: root["global"] == nil ? "missing prototype scope" : "scope is not an object"
                )
            )
        }

        if let rawApps = root["apps"] as? [String: Any] {
            for bundleID in rawApps.keys.sorted() {
                let path = "apps.\(bundleID)"
                guard !bundleID.isEmpty else {
                    skipped.append(
                        SkippedConfigurationEntry(
                            path: path,
                            reason: "app context identifier is empty"
                        )
                    )
                    continue
                }
                guard let rawProfile = rawApps[bundleID] as? [String: Any] else {
                    skipped.append(
                        SkippedConfigurationEntry(
                            path: path,
                            reason: "app profile is not an object"
                        )
                    )
                    continue
                }
                var profile: [PadButton: BindingAction] = [:]
                migrateBindings(
                    rawProfile,
                    path: path,
                    into: &profile,
                    skipped: &skipped
                )
                if !profile.isEmpty {
                    configuration.appProfiles[bundleID] = profile
                }
            }
        } else {
            skipped.append(
                SkippedConfigurationEntry(
                    path: "apps",
                    reason: root["apps"] == nil ? "missing prototype scope" : "scope is not an object"
                )
            )
        }

        preserveGhosttyProfilesInHerdr(configuration: &configuration)
        let backupURL = nextBackupURL(for: url)
        try originalData.write(to: backupURL, options: .withoutOverwriting)
        try save(configuration, to: url)
        return (
            configuration,
            ConfigurationMigrationReport(
                backupURL: backupURL,
                skippedEntries: skipped
            )
        )
    }

    private static func preserveGhosttyProfilesInHerdr(
        configuration: inout VibestickConfiguration
    ) {
        for bundleID in GhosttyPreset.bundleIDs {
            guard let profile = configuration.appProfiles[bundleID] else { continue }
            let herdrProfileKey = AppProfileKey.herdr(bundleID: bundleID).rawValue
            if configuration.appProfiles[herdrProfileKey] == nil {
                configuration.appProfiles[herdrProfileKey] = profile
            }
        }
    }

    private static func migrateBindings(
        _ values: [String: Any],
        path: String,
        into bindings: inout [PadButton: BindingAction],
        skipped: inout [SkippedConfigurationEntry]
    ) {
        for key in values.keys.sorted() {
            let entryPath = "\(path).\(key)"
            guard let button = PadButton(rawValue: key) else {
                skipped.append(
                    SkippedConfigurationEntry(
                        path: entryPath,
                        reason: "unknown controller button"
                    )
                )
                continue
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: values[key] as Any)
                bindings[button] = try JSONDecoder().decode(BindingAction.self, from: data)
            } catch {
                skipped.append(
                    SkippedConfigurationEntry(
                        path: entryPath,
                        reason: error.localizedDescription
                    )
                )
            }
        }
    }

    private static func nextBackupURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        var index = 1

        while true {
            let suffix = index == 1 ? "" : "-\(index)"
            let filename = pathExtension.isEmpty
                ? "\(stem).prototype-backup\(suffix)"
                : "\(stem).prototype-backup\(suffix).\(pathExtension)"
            let candidate = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
