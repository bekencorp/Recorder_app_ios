import Foundation

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [LocalRecording] = []

    private let fileManager = FileManager.default
    private let directory: URL
    private let indexURL: URL

    init(rootURL: URL? = nil) {
        let root = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "DawnRecorder", directoryHint: .isDirectory)
        directory = root.appending(path: "Recordings", directoryHint: .isDirectory)
        indexURL = root.appending(path: "recordings.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupIncomingFiles()
        load()
    }

    func contains(remoteFilename: String) -> Bool {
        recordings.contains { $0.remoteFilename == remoteFilename }
    }

    func add(audio: Data, remoteFilename: String) throws -> LocalRecording {
        let sourceURL = incomingFileURL()
        do {
            try audio.write(to: sourceURL, options: .atomic)
            return try add(
                fileAt: sourceURL,
                remoteFilename: remoteFilename,
                byteSize: audio.count
            )
        } catch let error as RecorderAppError {
            try? fileManager.removeItem(at: sourceURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: sourceURL)
            throw RecorderAppError.localStorageFailed(error.localizedDescription)
        }
    }

    func incomingFileURL() -> URL {
        directory.appending(path: ".incoming-\(UUID().uuidString).partial")
    }

    func add(
        fileAt sourceURL: URL,
        remoteFilename: String,
        byteSize: Int
    ) throws -> LocalRecording {
        try addFile(
            sourceURL,
            title: title(from: remoteFilename),
            createdAt: Date(),
            remoteFilename: remoteFilename,
            byteSize: byteSize,
            audioFormat: "raw_opus"
        )
    }

    func addBLELiveRecording(
        fileAt sourceURL: URL,
        byteSize: Int,
        startedAt: Date
    ) throws -> LocalRecording {
        guard byteSize > 0 else {
            throw RecorderAppError.bleAudioStreamEmpty
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try addFile(
            sourceURL,
            title: "Live \(formatter.string(from: startedAt))",
            createdAt: startedAt,
            remoteFilename: "ble://\(UUID().uuidString)",
            byteSize: byteSize,
            audioFormat: "raw_opus"
        )
    }

    func audio(for recording: LocalRecording) throws -> Data {
        try Data(contentsOf: audioURL(for: recording))
    }

    func audioURL(for recording: LocalRecording) -> URL {
        directory.appending(path: recording.localFilename)
    }

    func rename(_ recording: LocalRecording, to title: String) {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let index = recordings.firstIndex(where: { $0.id == recording.id })
        else { return }
        recordings[index].title = normalized
        save()
    }

    func delete(_ recording: LocalRecording) {
        try? fileManager.removeItem(at: audioURL(for: recording))
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    private func addFile(
        _ sourceURL: URL,
        title: String,
        createdAt: Date,
        remoteFilename: String,
        byteSize: Int,
        audioFormat: String
    ) throws -> LocalRecording {
        let id = UUID()
        let filename = "\(id.uuidString).opus"
        let destinationURL = directory.appending(path: filename)
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw RecorderAppError.localStorageFailed(error.localizedDescription)
        }

        let recording = LocalRecording(
            id: id,
            title: title,
            createdAt: createdAt,
            localFilename: filename,
            remoteFilename: remoteFilename,
            byteSize: byteSize,
            audioFormat: audioFormat
        )
        recordings.insert(recording, at: 0)
        do {
            try persist()
        } catch {
            recordings.removeAll { $0.id == recording.id }
            try? fileManager.removeItem(at: destinationURL)
            throw RecorderAppError.localStorageFailed(error.localizedDescription)
        }
        return recording
    }

    private func title(from remoteFilename: String) -> String {
        let value = remoteFilename.replacingOccurrences(of: ".opus", with: "")
        return value.isEmpty ? "Recording" : value
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let values = try? JSONDecoder().decode([LocalRecording].self, from: data)
        else { return }
        recordings = values.filter {
            fileManager.fileExists(atPath: audioURL(for: $0).path)
        }.sorted { $0.createdAt > $1.createdAt }
        save()
    }

    private func save() {
        try? persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(recordings)
        try data.write(to: indexURL, options: .atomic)
    }

    private func cleanupIncomingFiles() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(".incoming-")
            && file.pathExtension == "partial"
        {
            try? fileManager.removeItem(at: file)
        }
    }
}
