import Foundation

public struct StickTuning: Codable, Equatable {
    public static let defaults = StickTuning(
        deadZone: 0.25,
        repeatDelay: 0.4,
        repeatInterval: 0.08
    )

    public let deadZone: Double
    public let repeatDelay: TimeInterval
    public let repeatInterval: TimeInterval

    public init(
        deadZone: Double,
        repeatDelay: TimeInterval,
        repeatInterval: TimeInterval
    ) {
        precondition(
            Self.valuesAreValid(
                deadZone: deadZone,
                repeatDelay: repeatDelay,
                repeatInterval: repeatInterval
            )
        )
        self.deadZone = deadZone
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deadZone = try container.decode(Double.self, forKey: .deadZone)
        let repeatDelay = try container.decode(
            TimeInterval.self,
            forKey: .repeatDelay
        )
        let repeatInterval = try container.decode(
            TimeInterval.self,
            forKey: .repeatInterval
        )
        guard Self.valuesAreValid(
            deadZone: deadZone,
            repeatDelay: repeatDelay,
            repeatInterval: repeatInterval
        )
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid stick tuning values"
                )
            )
        }
        self.deadZone = deadZone
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
    }

    private static func valuesAreValid(
        deadZone: Double,
        repeatDelay: TimeInterval,
        repeatInterval: TimeInterval
    ) -> Bool {
        deadZone.isFinite &&
            deadZone >= 0 &&
            deadZone < 1 &&
            repeatDelay.isFinite &&
            repeatDelay >= 0 &&
            repeatInterval.isFinite &&
            repeatInterval > 0
    }
}

public struct ScrollDelta: Equatable {
    public let vertical: Int32
    public let horizontal: Int32

    public init(vertical: Int32, horizontal: Int32) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

public extension ScrollDirection {
    func delta(naturalScrolling: Bool) -> ScrollDelta {
        let direction: ScrollDelta
        switch self {
        case .up:
            direction = ScrollDelta(vertical: 1, horizontal: 0)
        case .down:
            direction = ScrollDelta(vertical: -1, horizontal: 0)
        case .left:
            direction = ScrollDelta(vertical: 0, horizontal: 1)
        case .right:
            direction = ScrollDelta(vertical: 0, horizontal: -1)
        }
        let multiplier: Int32 = naturalScrolling ? 1 : -1
        return ScrollDelta(
            vertical: direction.vertical * multiplier,
            horizontal: direction.horizontal * multiplier
        )
    }
}

/// Converts normalized stick axes into immediate directional inputs followed by
/// a deterministic repeat cadence. Platform timers remain outside this type so
/// timing and cancellation can be tested without a run loop.
public struct StickRepeater {
    private struct ActiveDirection {
        let input: StickInput
        var nextFireTime: TimeInterval
    }

    public let tuning: StickTuning
    private var activeDirections: [StickAxis: ActiveDirection] = [:]

    public init(tuning: StickTuning = .defaults) {
        self.tuning = tuning
    }

    public var isActive: Bool {
        !activeDirections.isEmpty
    }

    public var nextFireTime: TimeInterval? {
        activeDirections.values.map(\.nextFireTime).min()
    }

    public mutating func update(
        axis: StickAxis,
        value: Double,
        at timestamp: TimeInterval
    ) -> [StickInput] {
        guard let input = Self.direction(
            for: axis,
            value: value,
            deadZone: tuning.deadZone
        ) else {
            activeDirections.removeValue(forKey: axis)
            return []
        }
        guard activeDirections[axis]?.input != input else { return [] }

        activeDirections[axis] = ActiveDirection(
            input: input,
            nextFireTime: timestamp + tuning.repeatDelay
        )
        return [input]
    }

    public mutating func advance(to timestamp: TimeInterval) -> [StickInput] {
        let epsilon = 0.000_000_1
        var due: [(timestamp: TimeInterval, axis: StickAxis, input: StickInput)] = []

        for axis in activeDirections.keys {
            guard var active = activeDirections[axis] else { continue }
            if active.nextFireTime <= timestamp + epsilon {
                due.append((active.nextFireTime, axis, active.input))
                let intervalsElapsed = max(
                    1,
                    floor(
                        (timestamp - active.nextFireTime) / tuning.repeatInterval
                    ) + 1
                )
                active.nextFireTime += intervalsElapsed * tuning.repeatInterval
            }
            activeDirections[axis] = active
        }

        return due.sorted {
            if abs($0.timestamp - $1.timestamp) > epsilon {
                return $0.timestamp < $1.timestamp
            }
            return $0.axis.rawValue < $1.axis.rawValue
        }.map(\.input)
    }

    public mutating func cancel() {
        activeDirections.removeAll()
    }

    private static func direction(
        for axis: StickAxis,
        value: Double,
        deadZone: Double
    ) -> StickInput? {
        guard abs(value) > deadZone else { return nil }

        switch (axis, value > 0) {
        case (.leftX, true):
            return .leftRight
        case (.leftX, false):
            return .leftLeft
        case (.leftY, true):
            return .leftUp
        case (.leftY, false):
            return .leftDown
        case (.rightX, true):
            return .rightRight
        case (.rightX, false):
            return .rightLeft
        case (.rightY, true):
            return .rightUp
        case (.rightY, false):
            return .rightDown
        }
    }
}
