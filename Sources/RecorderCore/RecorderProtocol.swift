import Foundation

public enum RecorderProtocolError: Error, Equatable, LocalizedError {
    case invalidFrame
    case unexpectedResponse
    case deviceError(UInt8)
    case malformedStatus
    case malformedWiFiCredentials
    case malformedRawOpus(offset: Int)
    case malformedBLEOpusFrame

    public var errorDescription: String? {
        switch self {
        case .invalidFrame:
            "The recorder sent an incomplete protocol frame."
        case .unexpectedResponse:
            "The recorder response did not match the command."
        case .deviceError(let code):
            switch code {
            case 0x01: "The recorder is busy with another operation (device code 1)."
            case 0x02: "The recorder is not in the correct state for this action (device code 2)."
            case 0x03: "The recorder rejected an invalid command value (device code 3)."
            case 0x04: "The recorder storage is full (device code 4)."
            case 0x05: "The recorder battery is too low (device code 5)."
            case 0x06: "The recorder reported an internal firmware error (device code 6)."
            default: "The recorder rejected the command (device code \(code))."
            }
        case .malformedStatus:
            "The recorder status payload has an unexpected format."
        case .malformedWiFiCredentials:
            "The recorder's Bluetooth response did not include valid Wi-Fi or FTP credentials."
        case .malformedRawOpus(let offset):
            "The recording has an invalid Opus frame near byte \(offset)."
        case .malformedBLEOpusFrame:
            "The recorder sent an invalid BLE Opus frame."
        }
    }
}

public enum RecorderCommand: UInt8, Sendable {
    case startRecord = 0x01
    case stopRecord = 0x02
    case startBLEStream = 0x05
    case stopBLEStream = 0x06
    case getStatus = 0x07
    case setTime = 0x09
    case startWiFiAP = 0x0B
    case stopWiFiAP = 0x0C
}

public enum RecorderTransferHandoffPolicy {
    public static func acceptsDisconnect(
        while command: RecorderCommand,
        handoffExpected: Bool
    ) -> Bool {
        handoffExpected && command == .startWiFiAP
    }
}

public struct RecorderResponse: Equatable, Sendable {
    public let type: UInt8
    public let command: UInt8
    public let status: UInt8
    public let sequence: UInt8
    public let data: Data

    public init(frame: Data) throws {
        guard frame.count >= 7 else { throw RecorderProtocolError.invalidFrame }
        let payloadLength = Int(frame.littleEndianUInt16(at: 3))
        guard frame.count >= 5 + payloadLength, payloadLength >= 2 else {
            throw RecorderProtocolError.invalidFrame
        }
        type = frame[0]
        command = frame[1]
        status = frame[2]
        sequence = frame[5]
        data = frame.subdata(in: 7..<(5 + payloadLength))
    }

    public func requireSuccess(for expected: RecorderCommand, sequence expectedSequence: UInt8) throws {
        guard type == 0x01,
              command == expected.rawValue,
              sequence == expectedSequence
        else {
            throw RecorderProtocolError.unexpectedResponse
        }
        guard status == 0 else { throw RecorderProtocolError.deviceError(status) }
    }
}

public struct RecorderEvent: Equatable, Sendable {
    public let code: UInt8
    public let data: Data
}

public enum RecorderNotification: Equatable, Sendable {
    case response(RecorderResponse)
    case event(RecorderEvent)
    case status(RecorderStatus)

    public init(frame: Data) throws {
        guard frame.count >= 5 else { throw RecorderProtocolError.invalidFrame }
        let payloadLength = Int(frame.littleEndianUInt16(at: 3))
        guard frame.count == 5 + payloadLength else {
            throw RecorderProtocolError.invalidFrame
        }

        let payload = frame.subdata(in: 5..<frame.count)
        switch frame[0] {
        case 0x01:
            self = .response(try RecorderResponse(frame: frame))
        case 0x02:
            self = .event(RecorderEvent(code: frame[1], data: payload))
        case 0x03:
            self = .status(try RecorderStatus(data: payload))
        default:
            throw RecorderProtocolError.invalidFrame
        }
    }
}

public struct RecorderStatus: Equatable, Sendable {
    public let isRecording: Bool
    public let scene: UInt8
    public let isBLEStreaming: Bool
    public let isTimeSynced: Bool
    public let freeStoragePercent: UInt8
    public let batteryMillivolts: UInt16
    public let recordingSeconds: UInt32
    public let recorderUnixTime: UInt32
    public let deviceState: UInt8

    public init(data: Data) throws {
        guard data.count >= 16 else { throw RecorderProtocolError.malformedStatus }
        isRecording = data[0] != 0
        scene = data[1]
        isBLEStreaming = data[2] != 0
        isTimeSynced = data[3] != 0
        freeStoragePercent = data[4]
        batteryMillivolts = data.littleEndianUInt16(at: 5)
        recordingSeconds = data.littleEndianUInt32(at: 7)
        recorderUnixTime = data.littleEndianUInt32(at: 11)
        deviceState = data[15]
    }

    public var approximateBatteryPercent: Int {
        let minimum = 3_300.0
        let maximum = 4_200.0
        let value = (Double(batteryMillivolts) - minimum) / (maximum - minimum)
        return Int((value * 100).rounded()).clamped(to: 0...100)
    }
}

public struct RecorderWiFiCredentials: Equatable, Sendable {
    public let ssid: String
    public let password: String
    public let ftpUser: String
    public let ftpPassword: String
    public let host: String

    public init(
        ssid: String,
        password: String,
        ftpUser: String,
        ftpPassword: String,
        host: String
    ) {
        self.ssid = ssid
        self.password = password
        self.ftpUser = ftpUser
        self.ftpPassword = ftpPassword
        self.host = host
    }

    public init(data: Data) throws {
        var cursor = 0

        func readString() throws -> String {
            guard cursor < data.count else {
                throw RecorderProtocolError.malformedWiFiCredentials
            }
            let length = Int(data[cursor])
            cursor += 1
            guard length > 0, cursor + length <= data.count,
                  let value = String(data: data[cursor..<(cursor + length)], encoding: .utf8)
            else {
                throw RecorderProtocolError.malformedWiFiCredentials
            }
            cursor += length
            return value
        }

        ssid = try readString()
        password = try readString()
        ftpUser = try readString()
        ftpPassword = try readString()
        guard cursor + 4 <= data.count else {
            throw RecorderProtocolError.malformedWiFiCredentials
        }
        host = data[cursor..<(cursor + 4)].map(String.init).joined(separator: ".")
    }
}

public enum RecorderWire {
    public static func command(
        _ command: RecorderCommand,
        sequence: UInt8,
        payload: Data = Data()
    ) -> Data {
        var frame = Data([command.rawValue, sequence])
        frame.appendLittleEndian(UInt16(payload.count))
        frame.append(payload)
        return frame
    }

    public static func startRecord(sequence: UInt8, scene: UInt8 = 0) -> Data {
        command(.startRecord, sequence: sequence, payload: Data([scene]))
    }

    public static func setTime(sequence: UInt8, unixTime: UInt32) -> Data {
        var payload = Data()
        payload.appendLittleEndian(unixTime)
        return command(.setTime, sequence: sequence, payload: payload)
    }

    @discardableResult
    public static func validateRawOpus(_ data: Data) throws -> Int {
        var validator = RawOpusStreamValidator()
        try validator.consume(data)
        return try validator.finish().frameCount
    }
}

public struct BLEOpusFrame: Equatable, Sendable {
    public let wireData: Data
    public let opusPayload: Data

    public init(notification: Data) throws {
        guard let declaredLength = notification.first,
              (20...80).contains(Int(declaredLength)),
              notification.count == Int(declaredLength) + 1
        else {
            throw RecorderProtocolError.malformedBLEOpusFrame
        }
        wireData = notification
        opusPayload = notification.dropFirst()
    }
}

public struct BLEOpusStreamStatistics: Equatable, Sendable {
    public let byteCount: Int
    public let frameCount: Int
    public let discardedFrameCount: Int

    public init(byteCount: Int, frameCount: Int, discardedFrameCount: Int) {
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.discardedFrameCount = discardedFrameCount
    }

    public var durationSeconds: Double {
        Double(frameCount) * 0.02
    }
}

public struct BLEOpusStreamAccumulator: Sendable {
    private var byteCount = 0
    private var frameCount = 0
    private var discardedFrameCount = 0

    public init() {}

    public mutating func consume(_ notification: Data) -> BLEOpusFrame? {
        guard let frame = try? BLEOpusFrame(notification: notification) else {
            discardedFrameCount += 1
            return nil
        }
        byteCount += frame.wireData.count
        frameCount += 1
        return frame
    }

    public var statistics: BLEOpusStreamStatistics {
        BLEOpusStreamStatistics(
            byteCount: byteCount,
            frameCount: frameCount,
            discardedFrameCount: discardedFrameCount
        )
    }
}

public struct RawOpusValidationResult: Equatable, Sendable {
    public let byteCount: Int
    public let frameCount: Int
    public let discardedFrameCount: Int

    public init(byteCount: Int, frameCount: Int, discardedFrameCount: Int = 0) {
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.discardedFrameCount = discardedFrameCount
    }
}

/// Validates the recorder's `[1B length][Opus payload]` format incrementally.
/// Chunk boundaries may fall anywhere, including between the length and payload.
public struct RawOpusStreamValidator: Sendable {
    private var byteCount = 0
    private var frameCount = 0
    private var remainingPayloadBytes: Int?
    private var currentFrameOffset = 0

    public init() {}

    public mutating func consume(_ data: Data) throws {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if let remaining = remainingPayloadBytes {
                let available = data.distance(from: cursor, to: data.endIndex)
                let consumed = min(remaining, available)
                cursor = data.index(cursor, offsetBy: consumed)
                byteCount += consumed
                let nextRemaining = remaining - consumed
                if nextRemaining == 0 {
                    remainingPayloadBytes = nil
                    frameCount += 1
                } else {
                    remainingPayloadBytes = nextRemaining
                }
                continue
            }

            currentFrameOffset = byteCount
            let length = Int(data[cursor])
            cursor = data.index(after: cursor)
            byteCount += 1
            guard (20...80).contains(length) else {
                throw RecorderProtocolError.malformedRawOpus(offset: currentFrameOffset)
            }
            remainingPayloadBytes = length
        }
    }

    public func finish() throws -> RawOpusValidationResult {
        guard byteCount > 0, frameCount > 0, remainingPayloadBytes == nil else {
            throw RecorderProtocolError.malformedRawOpus(offset: currentFrameOffset)
        }
        return RawOpusValidationResult(byteCount: byteCount, frameCount: frameCount)
    }
}

public enum RecorderAudioFile {
    private static let fixedSlotSize = 81
    private static let fixedPayloadSize: UInt8 = 80

    public static func validateOrRecover(at fileURL: URL) throws -> RawOpusValidationResult {
        do {
            return try validate(at: fileURL)
        } catch {
            guard let recovered = try recoverFixedSlots(at: fileURL) else { throw error }
            return recovered
        }
    }

    public static func validate(at fileURL: URL) throws -> RawOpusValidationResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var validator = RawOpusStreamValidator()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try validator.consume(data)
        }
        return try validator.finish()
    }

    private static func recoverFixedSlots(
        at sourceURL: URL
    ) throws -> RawOpusValidationResult? {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, byteCount.isMultiple(of: fixedSlotSize) else { return nil }

        let totalSlots = byteCount / fixedSlotSize
        let recoveredURL = sourceURL.appendingPathExtension("recovered")
        try? FileManager.default.removeItem(at: recoveredURL)
        guard FileManager.default.createFile(atPath: recoveredURL.path, contents: nil) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: recoveredURL) }

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: recoveredURL)
            defer {
                try? input.close()
                try? output.close()
            }

            var recoveredSlots = 0
            for _ in 0..<totalSlots {
                guard let slot = try input.read(upToCount: fixedSlotSize),
                      slot.count == fixedSlotSize
                else {
                    return nil
                }
                guard slot.first == fixedPayloadSize else { continue }
                try output.write(contentsOf: slot)
                recoveredSlots += 1
            }
            try output.synchronize()

            guard recoveredSlots > 0,
                  recoveredSlots * 100 >= totalSlots * 95
            else {
                return nil
            }

            let validated = try validate(at: recoveredURL)
            _ = try FileManager.default.replaceItemAt(
                sourceURL,
                withItemAt: recoveredURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
            return RawOpusValidationResult(
                byteCount: validated.byteCount,
                frameCount: validated.frameCount,
                discardedFrameCount: totalSlots - recoveredSlots
            )
        } catch {
            try? FileManager.default.removeItem(at: recoveredURL)
            throw error
        }
    }
}

public enum RecorderSyncStage: String, CaseIterable, Codable, Sendable {
    case idle
    case requestingTransfer = "requesting_transfer"
    case disconnectingBluetooth = "disconnecting_bluetooth"
    case joiningWiFi = "joining_wifi"
    case listingFiles = "listing_files"
    case downloading
    case validating
    case saving
    case leavingWiFi = "leaving_wifi"
    case complete

    public var title: String {
        switch self {
        case .idle: "Ready"
        case .requestingTransfer: "Preparing recorder"
        case .disconnectingBluetooth: "Switching from Bluetooth"
        case .joiningWiFi: "Joining recorder Wi-Fi"
        case .listingFiles: "Finding recordings"
        case .downloading: "Copying recording"
        case .validating: "Checking recording"
        case .saving: "Saving on iPhone"
        case .leavingWiFi: "Restoring internet connection"
        case .complete: "Download complete"
        }
    }

    public var supportCode: String {
        switch self {
        case .idle: "SYNC-000"
        case .requestingTransfer: "SYNC-100"
        case .disconnectingBluetooth: "SYNC-110"
        case .joiningWiFi: "SYNC-200"
        case .listingFiles: "SYNC-300"
        case .downloading: "SYNC-400"
        case .validating: "SYNC-410"
        case .saving: "SYNC-500"
        case .leavingWiFi: "SYNC-600"
        case .complete: "SYNC-900"
        }
    }

    public var progress: Double? {
        switch self {
        case .idle: nil
        case .requestingTransfer: 0.05
        case .disconnectingBluetooth: 0.1
        case .joiningWiFi: 0.16
        case .listingFiles: 0.24
        case .downloading: 0.4
        case .validating: 0.62
        case .saving: 0.68
        case .leavingWiFi: 0.74
        case .complete: 1
        }
    }
}

extension Data {
    fileprivate func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    fileprivate mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
