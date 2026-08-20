import Foundation

struct BLELiveAudioCaptureResult: Equatable {
    let fileURL: URL
    let statistics: BLEOpusStreamStatistics
}

final class BLELiveAudioCapture {
    private let fileURL: URL
    private let handle: FileHandle
    private var accumulator = BLEOpusStreamAccumulator()
    private var isClosed = false

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw RecorderAppError.localStorageFailed("could not create the BLE audio file")
        }
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw RecorderAppError.localStorageFailed(error.localizedDescription)
        }
    }

    var statistics: BLEOpusStreamStatistics { accumulator.statistics }

    func append(notification: Data) throws {
        guard !isClosed else { return }
        guard let frame = accumulator.consume(notification) else { return }
        do {
            try handle.write(contentsOf: frame.wireData)
        } catch {
            throw RecorderAppError.localStorageFailed(error.localizedDescription)
        }
    }

    func finish() throws -> BLELiveAudioCaptureResult {
        guard !isClosed else {
            throw RecorderAppError.bleAudioStreamUnavailable
        }
        isClosed = true
        try handle.synchronize()
        try handle.close()
        let result = accumulator.statistics
        guard result.frameCount > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw RecorderAppError.bleAudioStreamEmpty
        }
        _ = try RecorderAudioFile.validate(at: fileURL)
        return BLELiveAudioCaptureResult(fileURL: fileURL, statistics: result)
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit {
        if !isClosed {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
