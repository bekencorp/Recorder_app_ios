import Foundation
import RecorderCore

enum CheckFailure: Error {
    case mismatch(String)
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure.mismatch(message) }
}

let command = RecorderWire.startRecord(sequence: 0x2A, scene: 0x03)
try require(
    command == Data([0x01, 0x2A, 0x01, 0x00, 0x03]),
    "start-record frame"
)

let response = try RecorderResponse(
    frame: Data([0x01, 0x07, 0x00, 0x03, 0x00, 0x19, 0x00, 0xAA])
)
try response.requireSuccess(for: .getStatus, sequence: 0x19)
try require(response.data == Data([0xAA]), "response payload")

let status = try RecorderStatus(data: Data([
    1, 2, 0, 1, 75,
    0xA0, 0x0F,
    0x2C, 0x01, 0x00, 0x00,
    0x00, 0xF1, 0x53, 0x65,
    3
]))
try require(status.batteryMillivolts == 4_000, "battery decoding")
try require(status.recordingSeconds == 300, "recording duration decoding")

var transfer = Data()
for string in ["recoder", "12345678", "recorder", "12345678"] {
    let value = Data(string.utf8)
    transfer.append(UInt8(value.count))
    transfer.append(value)
}
transfer.append(contentsOf: [192, 168, 4, 1])
let credentials = try RecorderWiFiCredentials(data: transfer)
try require(credentials.host == "192.168.4.1", "Wi-Fi host decoding")
try require(credentials.ftpUser == "recorder", "FTP user decoding")

let validRawOpus = Data([20] + Array(repeating: 1, count: 20)
    + [40] + Array(repeating: 2, count: 40))
let frameCount = try RecorderWire.validateRawOpus(validRawOpus)
try require(frameCount == 2, "raw Opus validation")

do {
    _ = try RecorderWire.validateRawOpus(Data([20, 1, 2]))
    throw CheckFailure.mismatch("truncated Opus was accepted")
} catch RecorderProtocolError.malformedRawOpus {
    // Expected.
}

print("PASS: BK7258 command, response, status, transfer, and Opus checks")
