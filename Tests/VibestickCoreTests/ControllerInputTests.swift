import XCTest
@testable import VibestickCore

final class ControllerInputTests: XCTestCase {
    func testXboxReportDecodesEveryRawButtonAndItsRelease() throws {
        let expected: [(bit: Int, button: PadButton)] = [
            (2, .start), (3, .back),
            (4, .a), (5, .b), (6, .x), (7, .y),
            (8, .dpadUp), (9, .dpadDown),
            (10, .dpadLeft), (11, .dpadRight),
            (12, .lb), (13, .rb), (14, .l3), (15, .r3),
        ]

        for entry in expected {
            let bitmap = UInt16(1) << entry.bit
            var pressedBytes = Array(repeating: UInt8(0), count: 17)
            pressedBytes[3] = UInt8(truncatingIfNeeded: bitmap)
            pressedBytes[4] = UInt8(truncatingIfNeeded: bitmap >> 8)

            let pressed = try XCTUnwrap(
                XboxSeriesDecoder.decode(pressedBytes, previousButtons: 0)
            )
            XCTAssertEqual(pressed.buttons.count, 1)
            XCTAssertEqual(pressed.buttons.first?.0, entry.button)
            XCTAssertEqual(pressed.buttons.first?.1, true)

            let released = try XCTUnwrap(
                XboxSeriesDecoder.decode(
                    Array(repeating: UInt8(0), count: 17),
                    previousButtons: bitmap
                )
            )
            XCTAssertEqual(released.buttons.count, 1)
            XCTAssertEqual(released.buttons.first?.0, entry.button)
            XCTAssertEqual(released.buttons.first?.1, false)
        }
    }

    func testXboxReportNormalizesTriggersAndEveryStickAxis() throws {
        var bytes = Array(repeating: UInt8(0), count: 17)
        bytes[5] = 0x00
        bytes[6] = 0x02 // 512 / 1023
        bytes[7] = 0xFF
        bytes[8] = 0x03 // 1023 / 1023
        write(Int16.min, to: &bytes, at: 9)
        write(Int16.max, to: &bytes, at: 11)
        write(16_384, to: &bytes, at: 13)
        write(-16_384, to: &bytes, at: 15)

        let report = try XCTUnwrap(XboxSeriesDecoder.decode(bytes, previousButtons: 0))
        XCTAssertEqual(value(for: .lt, in: report.triggers), 512.0 / 1023.0, accuracy: 0.001)
        XCTAssertEqual(value(for: .rt, in: report.triggers), 1, accuracy: 0.001)
        XCTAssertEqual(value(for: .leftX, in: report.axes), -1, accuracy: 0.001)
        XCTAssertEqual(value(for: .leftY, in: report.axes), 32_767.0 / 32_768.0, accuracy: 0.001)
        XCTAssertEqual(value(for: .rightX, in: report.axes), 0.5, accuracy: 0.001)
        XCTAssertEqual(value(for: .rightY, in: report.axes), -0.5, accuracy: 0.001)
    }

    func testBackendOwnershipProducesOneNormalizedStream() {
        let normalizer = ControllerEventNormalizer()
        let ordinary = ControllerEvent.input(.button(.a, pressed: true))
        let share = ControllerEvent.input(.button(.share, pressed: true))
        let device = ConnectedDevice(
            id: "target",
            name: "Xbox Wireless Controller",
            vendorID: 0x045E,
            productID: 0x0B12
        )

        XCTAssertEqual(normalizer.accept(ordinary, from: .rawHID), ordinary)
        XCTAssertNil(normalizer.accept(ordinary, from: .gameController))
        XCTAssertNil(normalizer.accept(share, from: .rawHID))
        XCTAssertEqual(normalizer.accept(share, from: .gameController), share)
        XCTAssertEqual(normalizer.accept(.connected(device), from: .rawHID), .connected(device))
        XCTAssertNil(normalizer.accept(.connected(device), from: .gameController))
        XCTAssertEqual(
            normalizer.accept(.disconnected(device), from: .rawHID),
            .disconnected(device)
        )
        XCTAssertNil(normalizer.accept(.disconnected(device), from: .gameController))
    }

    func testNormalizerSuppressesDuplicateStateAndResetsOnDisconnect() {
        let normalizer = ControllerEventNormalizer()
        let device = ConnectedDevice(
            id: "target",
            name: "Xbox Wireless Controller",
            vendorID: 0x045E,
            productID: 0x0B12
        )
        let pressed = ControllerEvent.input(.button(.a, pressed: true))

        XCTAssertEqual(normalizer.accept(.connected(device), from: .rawHID), .connected(device))
        XCTAssertNil(normalizer.accept(.connected(device), from: .rawHID))
        XCTAssertEqual(normalizer.accept(pressed, from: .rawHID), pressed)
        XCTAssertNil(normalizer.accept(pressed, from: .rawHID))
        XCTAssertEqual(
            normalizer.accept(.input(.axis(.leftX, value: 0.5)), from: .rawHID),
            .input(.axis(.leftX, value: 0.5))
        )
        XCTAssertNil(
            normalizer.accept(.input(.axis(.leftX, value: 0.505)), from: .rawHID)
        )
        XCTAssertEqual(
            normalizer.accept(.disconnected(device), from: .rawHID),
            .disconnected(device)
        )
        XCTAssertNil(normalizer.accept(.disconnected(device), from: .rawHID))
        XCTAssertEqual(normalizer.accept(pressed, from: .rawHID), pressed)
    }

    func testEveryRequiredControlHasExactlyOneProductionOwner() {
        for button in PadButton.allCases {
            let input = ControllerInput.button(button, pressed: true)
            let accepted = ControllerBackend.allCases.filter {
                ControllerEventNormalizer().accept(.input(input), from: $0) != nil
            }
            XCTAssertEqual(accepted.count, 1, "\(button) must have exactly one owner")
        }

        for button in [PadButton.lt, .rt] {
            let input = ControllerInput.trigger(button, value: 0.75)
            let accepted = ControllerBackend.allCases.filter {
                ControllerEventNormalizer().accept(.input(input), from: $0) != nil
            }
            XCTAssertEqual(accepted, [.rawHID])
        }

        for axis in [StickAxis.leftX, .leftY, .rightX, .rightY] {
            let input = ControllerInput.axis(axis, value: 0.5)
            let accepted = ControllerBackend.allCases.filter {
                ControllerEventNormalizer().accept(.input(input), from: $0) != nil
            }
            XCTAssertEqual(accepted, [.rawHID])
        }
    }

    func testDiagnosticCoverageIdentifiesGameControllerCompleteness() {
        var coverage = ControllerDiagnosticCoverage()
        let buttonEvents: [ControllerEvent] = [
            .input(.button(.a, pressed: true)),
            .input(.button(.b, pressed: true)),
            .input(.button(.x, pressed: true)),
            .input(.button(.y, pressed: true)),
            .input(.button(.lb, pressed: true)),
            .input(.button(.rb, pressed: true)),
            .input(.button(.back, pressed: true)),
            .input(.button(.start, pressed: true)),
            .input(.button(.l3, pressed: true)),
            .input(.button(.r3, pressed: true)),
            .input(.button(.dpadUp, pressed: true)),
            .input(.button(.dpadDown, pressed: true)),
            .input(.button(.dpadLeft, pressed: true)),
            .input(.button(.dpadRight, pressed: true)),
            .input(.button(.share, pressed: true)),
            .input(.trigger(.lt, value: 0.75)),
            .input(.trigger(.rt, value: 0.75)),
        ]
        let axisEvents = StickAxis.allCases.map {
            ControllerEvent.input(.axis($0, value: 0.75))
        }

        for event in buttonEvents + axisEvents {
            XCTAssertTrue(
                coverage.record(
                    ControllerDiagnosticRecord(backend: .gameController, event: event)
                )
            )
        }

        XCTAssertTrue(coverage.missing(from: .gameController).isEmpty)
        XCTAssertFalse(
            coverage.record(
                ControllerDiagnosticRecord(
                    backend: .gameController,
                    event: .input(.button(.share, pressed: false))
                )
            )
        )
    }

    private func write(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let bits = UInt16(bitPattern: value)
        bytes[offset] = UInt8(truncatingIfNeeded: bits)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
    }

    private func value(
        for button: PadButton,
        in values: [(PadButton, Double)]
    ) -> Double {
        values.first { $0.0 == button }?.1 ?? .nan
    }

    private func value(
        for axis: StickAxis,
        in values: [(StickAxis, Double)]
    ) -> Double {
        values.first { $0.0 == axis }?.1 ?? .nan
    }
}
