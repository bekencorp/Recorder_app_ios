import Foundation

enum RecorderAppError: Error, LocalizedError {
    case notConnected
    case commandTimedOut
    case transferCredentialsMissing
    case transferNetworkUnavailable
    case malformedFTPReply(String)
    case ftpTimedOut
    case localStorageFailed(String)
    case bleAudioStreamUnavailable
    case bleAudioStreamEmpty
    case syncFailed(stage: RecorderSyncStage, detail: String)

    var supportCode: String {
        switch self {
        case .notConnected: "BLE-001"
        case .commandTimedOut: "BLE-002"
        case .transferCredentialsMissing: "BLE-003"
        case .transferNetworkUnavailable: "WIFI-001"
        case .malformedFTPReply: "FTP-001"
        case .ftpTimedOut: "FTP-002"
        case .localStorageFailed: "STORAGE-001"
        case .bleAudioStreamUnavailable: "BLE-LIVE-001"
        case .bleAudioStreamEmpty: "BLE-LIVE-002"
        case .syncFailed(let stage, _): stage.supportCode
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Connect to the recorder first."
        case .commandTimedOut:
            "The recorder did not answer. Move the iPhone closer and try again."
        case .transferCredentialsMissing:
            "The recorder did not send Wi-Fi or FTP credentials over Bluetooth, so the transfer was stopped."
        case .transferNetworkUnavailable:
            "The iPhone could not join the recorder's transfer Wi-Fi. In Settings, join the network received over Bluetooth, then return and try again."
        case .malformedFTPReply(let reply):
            "The recorder's file server returned an unexpected response: \(reply)"
        case .ftpTimedOut:
            "The recorder's file server did not respond in time."
        case .localStorageFailed(let reason):
            "The recording could not be saved on this iPhone: \(reason)."
        case .bleAudioStreamUnavailable:
            "This recorder does not provide the BLE live-audio channel (A103)."
        case .bleAudioStreamEmpty:
            "No BLE audio frames arrived. Confirm the recorder is recording and try again."
        case .syncFailed(let stage, let detail):
            "\(stage.title) failed [\(stage.supportCode)]: \(detail)"
        }
    }
}

extension Error {
    var recorderSupportCode: String {
        (self as? RecorderAppError)?.supportCode ?? "APP-001"
    }
}
