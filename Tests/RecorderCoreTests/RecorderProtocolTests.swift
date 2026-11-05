import XCTest

@testable import AIRecorder

final class RecorderProtocolTests: XCTestCase {
    func testBuildsLittleEndianCommandFrame() {
        XCTAssertEqual(
            RecorderWire.startRecord(sequence: 0x2A, scene: 0x03),
            Data([0x01, 0x2A, 0x01, 0x00, 0x03])
        )
        XCTAssertEqual(
            RecorderWire.command(.startBLEStream, sequence: 0x2B),
            Data([0x05, 0x2B, 0x00, 0x00])
        )
        XCTAssertEqual(
            RecorderWire.command(.stopBLEStream, sequence: 0x2C),
            Data([0x06, 0x2C, 0x00, 0x00])
        )
    }

    func testParsesStatusAndWiFiCredentials() throws {
        let status = try RecorderStatus(data: Data([
            1, 2, 0, 1, 75,
            0xA0, 0x0F,
            0x2C, 0x01, 0x00, 0x00,
            0x00, 0xF1, 0x53, 0x65,
            3
        ]))
        XCTAssertEqual(status.batteryMillivolts, 4_000)
        XCTAssertEqual(status.recordingSeconds, 300)

        let credentials = try RecorderWiFiCredentials(data: wifiCredentialPayload(
            ssid: "fixture-ap",
            password: "fixture-wifi",
            ftpUser: "fixture-user",
            ftpPassword: "fixture-ftp",
            host: [192, 168, 4, 1]
        ))
        XCTAssertEqual(credentials.ssid, "fixture-ap")
        XCTAssertEqual(credentials.password, "fixture-wifi")
        XCTAssertEqual(credentials.ftpUser, "fixture-user")
        XCTAssertEqual(credentials.ftpPassword, "fixture-ftp")
        XCTAssertEqual(credentials.host, "192.168.4.1")
    }

    func testRejectsMissingWiFiCredentials() {
        XCTAssertThrowsError(try RecorderWiFiCredentials(data: Data())) { error in
            XCTAssertEqual(error as? RecorderProtocolError, .malformedWiFiCredentials)
        }
        XCTAssertThrowsError(try RecorderWiFiCredentials(data: Data([0]))) { error in
            XCTAssertEqual(error as? RecorderProtocolError, .malformedWiFiCredentials)
        }
        let truncated = wifiCredentialPayload(
            ssid: "fixture-ap",
            password: "fixture-wifi",
            ftpUser: "fixture-user",
            ftpPassword: "fixture-ftp",
            host: [192, 168]
        )
        XCTAssertThrowsError(try RecorderWiFiCredentials(data: truncated)) { error in
            XCTAssertEqual(error as? RecorderProtocolError, .malformedWiFiCredentials)
        }
    }

    private func wifiCredentialPayload(
        ssid: String,
        password: String,
        ftpUser: String,
        ftpPassword: String,
        host: [UInt8]
    ) -> Data {
        var transfer = Data()
        for string in [ssid, password, ftpUser, ftpPassword] {
            let value = Data(string.utf8)
            transfer.append(UInt8(value.count))
            transfer.append(value)
        }
        transfer.append(contentsOf: host)
        return transfer
    }

    func testParsesCommandResponseNotification() throws {
        let frame = Data([
            0x01, 0x07, 0x00, 0x12, 0x00,
            0x2A, 0x00,
            1, 0, 0, 1, 75,
            0xA0, 0x0F,
            0x2C, 0x01, 0x00, 0x00,
            0x00, 0xF1, 0x53, 0x65,
            1
        ])

        guard case .response(let response) = try RecorderNotification(frame: frame) else {
            return XCTFail("Expected a command response")
        }
        XCTAssertEqual(response.sequence, 0x2A)
        XCTAssertEqual(response.data.count, 16)
        XCTAssertNoThrow(
            try response.requireSuccess(for: .getStatus, sequence: 0x2A)
        )
    }

    func testParsesStatusPushWithoutSequencePrefix() throws {
        let frame = Data([
            0x03, 0x00, 0x00, 0x10, 0x00,
            1, 0, 0, 1, 75,
            0xA0, 0x0F,
            0x2C, 0x01, 0x00, 0x00,
            0x00, 0xF1, 0x53, 0x65,
            1
        ])

        guard case .status(let status) = try RecorderNotification(frame: frame) else {
            return XCTFail("Expected a status notification")
        }
        XCTAssertTrue(status.isRecording)
        XCTAssertEqual(status.recordingSeconds, 300)
    }

    func testParsesDeviceEvent() throws {
        let frame = Data([0x02, 0x13, 0x00, 0x01, 0x00, 0x03])

        guard case .event(let event) = try RecorderNotification(frame: frame) else {
            return XCTFail("Expected a device event")
        }
        XCTAssertEqual(event.code, 0x13)
        XCTAssertEqual(event.data, Data([0x03]))
    }

    func testTransferHandoffAcceptsDisconnectOnlyForWiFiCommand() {
        XCTAssertTrue(
            RecorderTransferHandoffPolicy.acceptsDisconnect(
                while: .startWiFiAP,
                handoffExpected: true
            )
        )
        XCTAssertFalse(
            RecorderTransferHandoffPolicy.acceptsDisconnect(
                while: .getStatus,
                handoffExpected: true
            )
        )
        XCTAssertFalse(
            RecorderTransferHandoffPolicy.acceptsDisconnect(
                while: .startWiFiAP,
                handoffExpected: false
            )
        )
    }

    func testValidatesRawOpusFrames() throws {
        let valid = Data([20] + Array(repeating: 1, count: 20)
            + [40] + Array(repeating: 2, count: 40))
        XCTAssertEqual(
            try RecorderWire.validateRawOpus(valid),
            2
        )
        XCTAssertThrowsError(try RecorderWire.validateRawOpus(Data([19] + Array(repeating: 1, count: 19))))
    }

    func testValidatesOneCompleteBLEOpusNotification() throws {
        let notification = Data([20] + Array(repeating: 0xA5, count: 20))
        let frame = try BLEOpusFrame(notification: notification)

        XCTAssertEqual(frame.wireData, notification)
        XCTAssertEqual(frame.opusPayload, Data(repeating: 0xA5, count: 20))
    }

    func testRejectsMalformedBLEOpusNotifications() {
        XCTAssertThrowsError(try BLEOpusFrame(notification: Data()))
        XCTAssertThrowsError(
            try BLEOpusFrame(notification: Data([20] + Array(repeating: 0xA5, count: 19)))
        )
        XCTAssertThrowsError(
            try BLEOpusFrame(notification: Data([81] + Array(repeating: 0xA5, count: 81)))
        )
    }

    func testBLEStreamAccumulatorCountsValidAndDiscardedFrames() {
        var stream = BLEOpusStreamAccumulator()
        XCTAssertNotNil(stream.consume(Data([20] + Array(repeating: 1, count: 20))))
        XCTAssertNil(stream.consume(Data([20, 1])))
        XCTAssertNotNil(stream.consume(Data([40] + Array(repeating: 2, count: 40))))

        XCTAssertEqual(
            stream.statistics,
            BLEOpusStreamStatistics(
                byteCount: 62,
                frameCount: 2,
                discardedFrameCount: 1
            )
        )
        XCTAssertEqual(stream.statistics.durationSeconds, 0.04, accuracy: 0.0001)
    }
}
