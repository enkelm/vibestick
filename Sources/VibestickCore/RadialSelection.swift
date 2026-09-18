import Foundation

public enum RadialSelection {
    public static let deadZone = 0.42

    public static func index(
        x: Double,
        y: Double,
        itemCount: Int,
        deadZone: Double = deadZone
    ) -> Int? {
        guard itemCount > 0, hypot(x, y) >= deadZone else { return nil }
        let fullTurn = Double.pi * 2
        let sector = fullTurn / Double(itemCount)
        var clockwiseFromTop = atan2(-y, x) + Double.pi / 2
        if clockwiseFromTop < 0 { clockwiseFromTop += fullTurn }
        return Int((clockwiseFromTop + sector / 2) / sector) % itemCount
    }
}
