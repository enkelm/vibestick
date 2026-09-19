import Foundation

/// A platform-neutral snapshot of one running application.
///
/// `id` identifies the running instance. `applicationID` identifies the app for
/// deduplication and recent-use tracking.
public struct AppWheelApplication: Equatable {
    public let id: String
    public let name: String
    public let applicationID: String
    public let recencyRank: UInt64?
    public let isRegular: Bool
    public let isTerminated: Bool
    public let isCurrent: Bool
    public let isVibestick: Bool

    public init(
        id: String,
        name: String,
        applicationID: String,
        recencyRank: UInt64? = nil,
        isRegular: Bool = true,
        isTerminated: Bool = false,
        isCurrent: Bool = false,
        isVibestick: Bool = false
    ) {
        self.id = id
        self.name = name
        self.applicationID = applicationID
        self.recencyRank = recencyRank
        self.isRegular = isRegular
        self.isTerminated = isTerminated
        self.isCurrent = isCurrent
        self.isVibestick = isVibestick
    }
}

public enum AppWheelCandidates {
    public static let limit = 8

    public static func make(
        from applications: [AppWheelApplication]
    ) -> [AppWheelApplication] {
        let excludedApplicationIDs = Set(
            applications
                .filter { $0.isCurrent || $0.isVibestick }
                .map(\.applicationID)
        )
        let ordered = applications
            .filter {
                $0.isRegular &&
                    !$0.isTerminated &&
                    !excludedApplicationIDs.contains($0.applicationID)
            }
            .sorted(by: comesBefore)

        var seenApplicationIDs: Set<String> = []
        return ordered
            .filter { seenApplicationIDs.insert($0.applicationID).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static func comesBefore(
        _ lhs: AppWheelApplication,
        _ rhs: AppWheelApplication
    ) -> Bool {
        switch (lhs.recencyRank, rhs.recencyRank) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.applicationID != rhs.applicationID {
            return lhs.applicationID < rhs.applicationID
        }
        return lhs.id < rhs.id
    }
}

public enum AppWheelApplicationIdentity {
    public static func make(
        bundleIdentifier: String?,
        bundleURL: URL?,
        executableURL: URL?,
        localizedName: String?,
        processIdentifier: Int32
    ) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle-id:\(bundleIdentifier)"
        }
        if let bundleURL {
            return "bundle-url:\(bundleURL.standardizedFileURL.path)"
        }
        if let executableURL {
            return "executable-url:\(executableURL.standardizedFileURL.path)"
        }
        if let localizedName, !localizedName.isEmpty {
            return "localized-name:\(localizedName)"
        }
        return "pid:\(processIdentifier)"
    }
}

/// Session-local activation order. Higher ranks are more recent.
public struct AppWheelRecency {
    private var nextRank: UInt64 = 1
    private var ranks: [String: UInt64] = [:]

    public init() {}

    public mutating func recordUse(of applicationID: String) {
        ranks[applicationID] = nextRank
        nextRank &+= 1
    }

    public func rank(for applicationID: String) -> UInt64? {
        ranks[applicationID]
    }
}

public enum AppWheelResponse: Equatable {
    case none
    case activate(index: Int)
    case cancel
}

/// The explicit selection behavior of one app-wheel presentation.
public struct AppWheelInteraction {
    public private(set) var selectedIndex: Int?
    private var itemCount = 0

    public init() {}

    public mutating func begin(itemCount: Int) {
        self.itemCount = max(0, itemCount)
        selectedIndex = nil
    }

    public mutating func updateSelection(x: Double, y: Double) {
        guard let index = RadialSelection.index(
            x: x,
            y: y,
            itemCount: itemCount
        ) else {
            return
        }
        selectedIndex = index
    }

    public func handle(button: PadButton, pressed: Bool) -> AppWheelResponse {
        guard pressed else { return .none }
        switch button {
        case .a:
            guard let selectedIndex else { return .none }
            return .activate(index: selectedIndex)
        case .b:
            return .cancel
        default:
            return .none
        }
    }
}
