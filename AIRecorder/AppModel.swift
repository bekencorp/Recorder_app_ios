import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case working(String, Double?)
        case finished(String)
        case failed(String)
    }

    let bluetooth = BLERecorderClient()
    let recordings = RecordingStore()

    @Published var activity: Activity = .idle
    @Published private(set) var syncStage: RecorderSyncStage = .idle
    @Published private(set) var syncDetail = ""
    @Published private(set) var lastSyncReport: String?

    private var liveAudioStartedAt: Date?
    private let hotspot = HotspotManager()
    private let ftp = RecorderFTPClient()

    init() {
        bluetooth.prepare()
    }

    var isBusy: Bool {
        if case .working = activity { return true }
        return false
    }

    func toggleRecording() async {
        activity = .working("Sending command to recorder", nil)
        do {
            if bluetooth.status?.isRecording == true {
                try await bluetooth.stopRecording()
                activity = .finished("Recording saved on the wearable")
            } else {
                try await bluetooth.startRecording()
                activity = .finished("Recording started")
            }
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func toggleBLELiveAudio() async {
        if bluetooth.isLiveAudioStreaming {
            await stopBLELiveAudio()
        } else {
            await startBLELiveAudio()
        }
    }

    private func startBLELiveAudio() async {
        let destination = recordings.incomingFileURL()
        let startedAt = Date()
        activity = .working("Starting live audio", nil)
        do {
            try await bluetooth.startLiveAudioCapture(to: destination)
            liveAudioStartedAt = startedAt
            activity = .finished("Live audio is streaming to this iPhone")
        } catch {
            try? FileManager.default.removeItem(at: destination)
            liveAudioStartedAt = nil
            activity = .failed("\(error.localizedDescription) [\(error.recorderSupportCode)]")
        }
    }

    private func stopBLELiveAudio() async {
        activity = .working("Saving live audio", nil)
        do {
            let result = try await bluetooth.stopLiveAudioCapture()
            _ = try recordings.addBLELiveRecording(
                fileAt: result.fileURL,
                byteSize: result.statistics.byteCount,
                startedAt: liveAudioStartedAt ?? Date()
            )
            liveAudioStartedAt = nil
            let seconds = Int(result.statistics.durationSeconds.rounded())
            activity = .finished("Saved \(seconds)s of live audio on this iPhone")
        } catch {
            liveAudioStartedAt = nil
            activity = .failed("\(error.localizedDescription) [\(error.recorderSupportCode)]")
        }
    }

    func refreshStatus() async {
        do {
            _ = try await bluetooth.refreshStatus()
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func sync() async {
        guard bluetooth.isConnected else {
            activity = .failed("Connect to the recorder before syncing.")
            return
        }

        var credentials: RecorderWiFiCredentials?
        var imported: [LocalRecording] = []
        var incomingURL: URL?
        var discardedAudioFrames = 0

        do {
            updateSync(.requestingTransfer)
            let transfer = try await bluetooth.requestTransferNetwork()
            credentials = transfer

            updateSync(
                .disconnectingBluetooth,
                detail: "Recorder accepted the command and is starting \(transfer.ssid)"
            )
            bluetooth.disconnect()
            try await Task.sleep(for: .seconds(2))

            updateSync(.joiningWiFi, detail: "Connect this iPhone to \(transfer.ssid)")
            try await hotspot.join(transfer)
            try await Task.sleep(for: .seconds(2))

            updateSync(.listingFiles)
            let remoteRecordings = try await listRecordingsWithRetry(using: transfer)
            let pending = remoteRecordings.filter {
                !recordings.contains(remoteFilename: $0.filename)
            }

            for (index, remote) in pending.enumerated() {
                let fileIndex = Double(index) / Double(max(pending.count, 1))
                let baseProgress = 0.28 + fileIndex * 0.38
                updateSync(.downloading, detail: remote.filename, progress: baseProgress)

                let destination = recordings.incomingFileURL()
                incomingURL = destination
                let expectedSize = remote.byteSize
                let receipt = try await downloadWithRetry(
                    remote,
                    to: destination,
                    using: transfer
                ) { [weak self] receivedBytes in
                    let fileProgress: Double
                    if let expectedSize, expectedSize > 0 {
                        fileProgress = min(1, Double(receivedBytes) / Double(expectedSize))
                    } else {
                        fileProgress = 0
                    }
                    Task { @MainActor in
                        self?.updateSync(
                            .downloading,
                            detail: "\(remote.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file))",
                            progress: baseProgress
                                + fileProgress * 0.34 / Double(max(pending.count, 1))
                        )
                    }
                }

                updateSync(
                    .validating,
                    detail: receipt.discardedFrameCount == 0
                        ? "\(remote.filename) · \(receipt.frameCount) frames"
                        : "\(remote.filename) · recovered with \(receipt.discardedFrameCount) damaged frames removed"
                )
                discardedAudioFrames += receipt.discardedFrameCount
                updateSync(.saving, detail: remote.filename)
                imported.append(
                    try recordings.add(
                        fileAt: destination,
                        remoteFilename: remote.filename,
                        byteSize: receipt.byteCount
                    )
                )
                incomingURL = nil
            }

            updateSync(.leavingWiFi, detail: "Disconnecting iPhone from \(transfer.ssid)")
            let hotspotRelease = await hotspot.leave(transfer)
            credentials = nil

            var message: String
            if imported.isEmpty {
                message = "Everything is already synced"
            } else {
                message = "Downloaded \(imported.count) recording\(imported.count == 1 ? "" : "s") to this iPhone"
            }
            if discardedAudioFrames > 0 {
                message += ". Removed \(discardedAudioFrames) damaged audio frame\(discardedAudioFrames == 1 ? "" : "s")"
            }
            message = syncCompletionMessage(base: message, hotspotRelease: hotspotRelease)
            finishSync(message: message, importedCount: imported.count)
            activity = .finished(message)
        } catch {
            if let incomingURL {
                try? FileManager.default.removeItem(at: incomingURL)
            }
            if let credentials {
                _ = await hotspot.leave(credentials)
            }
            let failure = RecorderAppError.syncFailed(
                stage: syncStage,
                detail: error.localizedDescription
            )
            let preserved = imported.isEmpty
                ? ""
                : " \(imported.count) completed recording\(imported.count == 1 ? " was" : "s were") saved on this iPhone."
            lastSyncReport = diagnosticReport(
                result: "FAILED",
                code: failure.supportCode,
                detail: failure.localizedDescription + preserved,
                importedCount: imported.count
            )
            activity = .failed(failure.localizedDescription + preserved)
        }
    }

    func dismissActivity() {
        activity = .idle
    }

    private func listRecordingsWithRetry(
        using credentials: RecorderWiFiCredentials
    ) async throws -> [RemoteRecording] {
        var lastError: Error = RecorderAppError.ftpTimedOut
        for attempt in 1...5 {
            do {
                return try await ftp.listRecordings(using: credentials)
            } catch {
                lastError = error
                guard attempt < 5 else { break }
                updateSync(
                    .listingFiles,
                    detail: "Waiting for recorder file service (\(attempt)/5)"
                )
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError
    }

    private func downloadWithRetry(
        _ remote: RemoteRecording,
        to destination: URL,
        using credentials: RecorderWiFiCredentials,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> RecorderTransferReceipt {
        var lastError: Error = RecorderAppError.ftpTimedOut
        for attempt in 1...3 {
            do {
                return try await ftp.download(
                    remote,
                    to: destination,
                    using: credentials,
                    progress: progress
                )
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                updateSync(
                    .downloading,
                    detail: "Retrying \(remote.filename) (\(attempt)/3)"
                )
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError
    }

    private func updateSync(
        _ stage: RecorderSyncStage,
        detail: String = "",
        progress: Double? = nil
    ) {
        syncStage = stage
        syncDetail = detail
        activity = .working(stage.title, progress ?? stage.progress)
    }

    private func syncCompletionMessage(
        base: String,
        hotspotRelease: RecorderHotspotRelease
    ) -> String {
        switch hotspotRelease {
        case .released:
            base + ". Recorder Wi-Fi disconnected; files are ready in Recordings"
        case .stillAssociated:
            base + ". iOS kept the recorder Wi-Fi association [WIFI-RELEASE-001]. Open Wi-Fi and select the normal network"
        }
    }

    private func finishSync(message: String, importedCount: Int) {
        syncStage = .complete
        syncDetail = message
        lastSyncReport = diagnosticReport(
            result: "PASS",
            code: RecorderSyncStage.complete.supportCode,
            detail: message,
            importedCount: importedCount
        )
    }

    private func diagnosticReport(
        result: String,
        code: String,
        detail: String,
        importedCount: Int
    ) -> String {
        let formatter = ISO8601DateFormatter()
        return [
            "Dawn Recorder sync report",
            "App: \(appVersion)",
            "Time: \(formatter.string(from: Date()))",
            "Result: \(result)",
            "Stage: \(syncStage.rawValue)",
            "Code: \(code)",
            "Imported: \(importedCount)",
            "Detail: \(detail)"
        ].joined(separator: "\n")
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(version ?? "unknown") (\(build ?? "unknown"))"
    }
}
