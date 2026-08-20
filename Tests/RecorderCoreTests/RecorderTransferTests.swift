import Combine
import Foundation
import XCTest

@testable import AIRecorder

final class RecorderTransferTests: XCTestCase {
    func testFTPWorkflowAgainstSimulatedRecorder() async throws {
        let filename = "20260803_120000.opus"
        let audio = recorderAudio()
        let server = MockRecorderFTPServer(
            recordingFilename: filename,
            recordingData: audio
        )
        let port = try await server.start()
        defer { server.stop() }
        let client = RecorderFTPClient(port: port, requiresWiFiInterface: false)
        let credentials = AIRecorder.RecorderWiFiCredentials(
            ssid: "recoder",
            password: "12345678",
            ftpUser: "recorder",
            ftpPassword: "12345678",
            host: "127.0.0.1"
        )

        let listed = try await client.listRecordings(using: credentials)
        XCTAssertEqual(
            listed,
            [RemoteRecording(filename: filename, byteSize: audio.count)]
        )

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ftp-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: destination) }
        let receipt = try await client.download(
            listed[0],
            to: destination,
            using: credentials
        )

        XCTAssertEqual(receipt, RecorderTransferReceipt(byteCount: audio.count, frameCount: 3))
        XCTAssertEqual(try Data(contentsOf: destination), audio)
    }

    func testFallsBackToNLSTAndAbsoluteRecordDirectory() async throws {
        let filename = "20260803_121500.opus"
        let server = MockRecorderFTPServer(
            recordingFilename: filename,
            recordingData: recorderAudio(),
            rejectsList: true,
            requiresAbsoluteRecordDirectory: true
        )
        let port = try await server.start()
        defer { server.stop() }
        let client = RecorderFTPClient(port: port, requiresWiFiInterface: false)

        let listed = try await client.listRecordings(using: testCredentials)

        XCTAssertEqual(listed, [RemoteRecording(filename: filename)])
    }

    func testIncrementalRawOpusValidationAcrossEveryChunkBoundary() throws {
        let recording = recorderAudio()

        for split in 0...recording.count {
            var validator = RawOpusStreamValidator()
            try validator.consume(recording.prefix(split))
            try validator.consume(recording.suffix(recording.count - split))
            XCTAssertEqual(
                try validator.finish(),
                RawOpusValidationResult(byteCount: recording.count, frameCount: 3),
                "split at byte \(split)"
            )
        }
    }

    func testIncrementalValidatorRejectsTruncatedFinalFrameWithOffset() throws {
        var validator = RawOpusStreamValidator()
        try validator.consume(Data([20] + Array(repeating: 0xAA, count: 20) + [40, 0x01]))

        XCTAssertThrowsError(try validator.finish()) { error in
            XCTAssertEqual(error as? RecorderProtocolError, .malformedRawOpus(offset: 21))
        }
    }

    func testAllDaySizedStreamDoesNotRequireWholeFileBuffer() throws {
        var validator = RawOpusStreamValidator()
        let frame = Data([40] + Array(repeating: UInt8(0x5A), count: 40))
        let frameCount = 100_000

        for _ in 0..<frameCount {
            try validator.consume(frame)
        }

        XCTAssertEqual(
            try validator.finish(),
            RawOpusValidationResult(
                byteCount: frame.count * frameCount,
                frameCount: frameCount
            )
        )
    }

    func testRecoversAndroidBoardFixedSlotFormat() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "board-recovery-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data()
        for index in 0..<100 {
            data.append(index == 42 ? 0 : 80)
            data.append(contentsOf: Array(repeating: UInt8(index), count: 80))
        }
        try data.write(to: file)

        let result = try RecorderAudioFile.validateOrRecover(at: file)

        XCTAssertEqual(result.frameCount, 99)
        XCTAssertEqual(result.discardedFrameCount, 1)
        XCTAssertEqual(result.byteCount, 99 * 81)
        XCTAssertEqual((try Data(contentsOf: file)).count, 99 * 81)
    }

    func testRejectsFixedSlotFileWhenMoreThanFivePercentIsDamaged() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "board-reject-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data()
        for index in 0..<100 {
            data.append(index < 6 ? 0 : 80)
            data.append(contentsOf: Array(repeating: UInt8(index), count: 80))
        }
        try data.write(to: file)

        XCTAssertThrowsError(try RecorderAudioFile.validateOrRecover(at: file))
        XCTAssertEqual((try Data(contentsOf: file)).count, 100 * 81)
    }

    func testParsesFirmwareUnixListAndExcludesPartialFiles() {
        let listing = Data("""
        -rw-rw-rw- 1 user ftp 245760 Jun 30 12:00 20260630_120000.opus\r
        -rw-rw-rw- 1 user ftp 1024 Jun 30 12:01 20260630_120100.opus.partial\r
        -rw-rw-rw- 1 user ftp 512000 Jun 30 11:45 20260630_114530.opus\r
        """.utf8)

        XCTAssertEqual(
            RecorderFTPClient.parseListing(listing),
            [
                RemoteRecording(filename: "20260630_114530.opus", byteSize: 512_000),
                RemoteRecording(filename: "20260630_120000.opus", byteSize: 245_760)
            ]
        )
    }

    func testParsesNLSTFallbackShape() {
        let listing = Data("20260630_120000.opus\r\nnotes.txt\r\n".utf8)
        XCTAssertEqual(
            RecorderFTPClient.parseListing(listing),
            [RemoteRecording(filename: "20260630_120000.opus")]
        )
    }

    @MainActor
    func testDownloadedFileIsMovedIntoPersistentLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let incoming = store.incomingFileURL()
        let audio = Data([2, 0xAA, 0xBB, 1, 0xCC])
        try audio.write(to: incoming)

        let recording = try store.add(
            fileAt: incoming,
            remoteFilename: "20260803_120000.opus",
            byteSize: audio.count
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: recording)), audio)
        XCTAssertTrue(store.contains(remoteFilename: "20260803_120000.opus"))

        let reloaded = RecordingStore(rootURL: root)
        XCTAssertEqual(reloaded.recordings.first?.id, recording.id)
    }

    @MainActor
    func testBLELiveFileIsMovedIntoPersistentLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let incoming = store.incomingFileURL()
        let audio = Data([20] + Array(repeating: 0xA5, count: 20))
        try audio.write(to: incoming)
        let startedAt = Date(timeIntervalSince1970: 1_786_000_000)

        let recording = try store.addBLELiveRecording(
            fileAt: incoming,
            byteSize: audio.count,
            startedAt: startedAt
        )

        XCTAssertEqual(recording.audioFormat, "raw_opus")
        XCTAssertTrue(recording.remoteFilename?.hasPrefix("ble://") == true)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(for: recording)), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
    }

    func testBLELiveCaptureWritesOnlyCompleteFramesAndFinishes() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ble-live-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = try BLELiveAudioCapture(fileURL: file)
        let first = Data([20] + Array(repeating: 0x11, count: 20))
        let second = Data([40] + Array(repeating: 0x22, count: 40))

        try capture.append(notification: first)
        try capture.append(notification: Data([20, 0x01]))
        try capture.append(notification: second)
        let result = try capture.finish()

        XCTAssertEqual(try Data(contentsOf: file), first + second)
        XCTAssertEqual(result.statistics.frameCount, 2)
        XCTAssertEqual(result.statistics.discardedFrameCount, 1)
        XCTAssertEqual(result.statistics.byteCount, first.count + second.count)
    }

    @MainActor
    func testDeletingRecordingPublishesAndPersistsImmediately() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let recording = try store.add(
            audio: Data([2, 0xAA, 0xBB]),
            remoteFilename: "20260806_100000.opus"
        )
        let audioURL = store.audioURL(for: recording)
        var publishedCounts: [Int] = []
        let observation = store.$recordings
            .dropFirst()
            .sink { publishedCounts.append($0.count) }

        store.delete(recording)

        XCTAssertEqual(publishedCounts.last, 0)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(RecordingStore(rootURL: root).recordings.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRelaunchRemovesIncompleteTransferFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = RecordingStore(rootURL: root)
        let incomplete = firstStore.incomingFileURL()
        try Data([4, 1]).write(to: incomplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))

        _ = RecordingStore(rootURL: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomplete.path))
    }

    func testSyncStagesHaveStableUniqueSupportCodes() {
        let codes = RecorderSyncStage.allCases.map(\.supportCode)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(RecorderSyncStage.requestingTransfer.supportCode, "SYNC-100")
        XCTAssertEqual(RecorderSyncStage.downloading.supportCode, "SYNC-400")
        XCTAssertEqual(RecorderSyncStage.complete.supportCode, "SYNC-900")
    }

    func testRecorderHotspotReleaseRequiresLeavingRecorderSSID() {
        XCTAssertEqual(
            HotspotManager.releaseState(currentSSID: "recoder", recorderSSID: "recoder"),
            .stillAssociated
        )
        XCTAssertEqual(
            HotspotManager.releaseState(currentSSID: "Home Wi-Fi", recorderSSID: "recoder"),
            .released
        )
        XCTAssertEqual(
            HotspotManager.releaseState(currentSSID: nil, recorderSSID: "recoder"),
            .released
        )
    }

    private var testCredentials: RecorderWiFiCredentials {
        RecorderWiFiCredentials(
            ssid: "recoder",
            password: "12345678",
            ftpUser: "recorder",
            ftpPassword: "12345678",
            host: "127.0.0.1"
        )
    }

    private func recorderAudio() -> Data {
        Data([20] + Array(repeating: 0x11, count: 20)
            + [40] + Array(repeating: 0x22, count: 40)
            + [80] + Array(repeating: 0x33, count: 80))
    }
}
