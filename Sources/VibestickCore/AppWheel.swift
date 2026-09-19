import Foundation

/// A platform-neutral snapshot of one running application.
///
/// `id` identifies the running instance. `bundleID` identifies the app for
/// deduplication and recent-use tracking.
public struct AppWheelApplication: Equatable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let recentUse: UInt64?
    public let isRegular: Bool
    public let isTerminated: Bool
    public let isCurrent: Bool
    public let isVibestick: Bool

    public init(
        id: String,
        name: String,
        bundleID: String,
        recentUse: UInt64? = nil,
        isRegular: Bool = true,
        isTerminated: Bool = false,
        isCurrent: Bool = false,
        isVibestick: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.recentUse = recentUse
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
        let excludedBundleIDs = Set(
            applications
                .filter { $0.isCurrent || $0.isVibestick }
                .map(\.bundleID)
        )
        let ordered = applications
            .filter {
                $0.isRegular &&
                    !$0.isTerminated &&
                    !excludedBundleIDs.contains($0.bundleID)
            }
            .sorted(by: comesBefore)

        var seenBundleIDs: Set<String> = []
        return ordered
            .filter { seenBundleIDs.insert($0.bundleID).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static func comesBefore(
        _ lhs: AppWheelApplication,
        _ rhs: AppWheelApplication
    ) -> Bool {
        switch (lhs.recentUse, rhs.recentUse) {
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
        if lhs.bundleID != rhs.bundleID {
            return lhs.bundleID < rhs.bundleID
        }
        return lhs.id < rhs.id
    }
}

/// Session-local activation order. Higher ranks are more recent.
public struct AppWheelRecency {
    private var nextRank: UInt64 = 1
    private var ranks: [String: UInt64] = [:]

    public init() {}

    public mutating func recordUse(of bundleID: String) {
        ranks[bundleID] = nextRank
        nextRank &+= 1
    }

    public func rank(for bundleID: String) -> UInt64? {
        ranks[bundleID]
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
