import Foundation
import Network

struct RemoteRecording: Identifiable, Equatable {
    var id: String { filename }
    let filename: String
    let byteSize: Int?

    init(filename: String, byteSize: Int? = nil) {
        self.filename = filename
        self.byteSize = byteSize
    }
}

struct RecorderTransferReceipt: Equatable {
    let byteCount: Int
    let frameCount: Int
    let discardedFrameCount: Int

    init(byteCount: Int, frameCount: Int, discardedFrameCount: Int = 0) {
        self.byteCount = byteCount
        self.frameCount = frameCount
        self.discardedFrameCount = discardedFrameCount
    }
}

struct RecorderFTPClient {
    private let port: UInt16
    private let requiresWiFiInterface: Bool

    init(port: UInt16 = 21, requiresWiFiInterface: Bool = true) {
        self.port = port
        self.requiresWiFiInterface = requiresWiFiInterface
    }

    func listRecordings(using credentials: RecorderWiFiCredentials) async throws -> [RemoteRecording] {
        do {
            let data = try await listing(using: credentials, command: "LIST")
            let recordings = Self.parseListing(data)
            if data.isEmpty || !recordings.isEmpty { return recordings }
        } catch {
            // Some firmware FTP builds reject LIST but support NLST.
        }
        return Self.parseListing(try await listing(using: credentials, command: "NLST"))
    }

    private func listing(
        using credentials: RecorderWiFiCredentials,
        command: String
    ) async throws -> Data {
        let control = try await FTPConnection.connect(
            host: credentials.host,
            port: port,
            requiresWiFiInterface: requiresWiFiInterface
        )
        defer { control.cancel() }
        _ = try await control.readReply(expected: 220)
        try await login(control, credentials: credentials)
        await enterRecordingsDirectory(control)
        let data = try await dataCommand(control, command: command)
        _ = try? await control.command("QUIT", expected: 221)
        return data
    }

    func download(
        _ recording: RemoteRecording,
        to destinationURL: URL,
        using credentials: RecorderWiFiCredentials,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> RecorderTransferReceipt {
        let control = try await FTPConnection.connect(
            host: credentials.host,
            port: port,
            requiresWiFiInterface: requiresWiFiInterface
        )
        defer { control.cancel() }
        _ = try await control.readReply(expected: 220)
        try await login(control, credentials: credentials)
        await enterRecordingsDirectory(control)
        do {
            let receipt = try await dataCommand(
                control,
                command: "RETR \(recording.filename)",
                writingTo: destinationURL,
                progress: progress
            )
            _ = try? await control.command("QUIT", expected: 221)
            return receipt
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    static func parseListing(_ data: Data) -> [RemoteRecording] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> RemoteRecording? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard let rawFilename = fields.last else { return nil }
                let filename = String(rawFilename)
                guard filename.lowercased().hasSuffix(".opus"),
                      !filename.lowercased().hasSuffix(".opus.partial")
                else {
                    return nil
                }
                let byteSize = fields.count >= 9 ? Int(fields[4]) : nil
                return RemoteRecording(filename: filename, byteSize: byteSize)
            }
            .sorted { $0.filename < $1.filename }
    }

    private func login(
        _ control: FTPConnection,
        credentials: RecorderWiFiCredentials
    ) async throws {
        let userReply = try await control.command(
            "USER \(credentials.ftpUser)",
            accepted: [230, 331]
        )
        if userReply.code == 331 {
            _ = try await control.command(
                "PASS \(credentials.ftpPassword)",
                expected: 230
            )
        }
        _ = try await control.command("TYPE I", expected: 200)
    }

    private func enterRecordingsDirectory(_ control: FTPConnection) async {
        if (try? await control.command("CWD RECORD", expected: 250)) != nil { return }
        _ = try? await control.command("CWD /RECORD", expected: 250)
    }

    private func dataCommand(_ control: FTPConnection, command: String) async throws -> Data {
        let passive = try await control.command("PASV", expected: 227)
        let endpoint = try passive.passiveEndpoint()
        let dataConnection = try await FTPConnection.connect(
            host: endpoint.host,
            port: endpoint.port,
            requiresWiFiInterface: requiresWiFiInterface
        )
        defer { dataConnection.cancel() }
        _ = try await control.command(command, accepted: [125, 150])
        let data = try await dataConnection.receiveToEnd()
        _ = try await control.readReply(expected: 226)
        return data
    }

    private func dataCommand(
        _ control: FTPConnection,
        command: String,
        writingTo destinationURL: URL,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> RecorderTransferReceipt {
        let passive = try await control.command("PASV", expected: 227)
        let endpoint = try passive.passiveEndpoint()
        let dataConnection = try await FTPConnection.connect(
            host: endpoint.host,
            port: endpoint.port,
            requiresWiFiInterface: requiresWiFiInterface
        )
        defer { dataConnection.cancel() }
        _ = try await control.command(command, accepted: [125, 150])
        let receipt = try await dataConnection.receiveRawOpus(
            writingTo: destinationURL,
            progress: progress
        )
        _ = try await control.readReply(expected: 226)
        return receipt
    }
}

private struct FTPReply {
    let code: Int
    let message: String

    func passiveEndpoint() throws -> (host: String, port: UInt16) {
        guard let start = message.firstIndex(of: "("),
              let end = message[start...].firstIndex(of: ")")
        else {
            throw RecorderAppError.malformedFTPReply(message)
        }
        let values = message[message.index(after: start)..<end]
            .split(separator: ",")
            .compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 6 else {
            throw RecorderAppError.malformedFTPReply(message)
        }
        let host = values[0...3].map(String.init).joined(separator: ".")
        return (host, values[4] * 256 + values[5])
    }
}

private final class FTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var receiveBuffer = Data()
    private var didReachEnd = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(
        host: String,
        port: UInt16,
        requiresWiFiInterface: Bool
    ) async throws -> FTPConnection {
        let parameters = NWParameters.tcp
        if requiresWiFiInterface {
            parameters.requiredInterfaceType = .wifi
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        let client = FTPConnection(connection: connection)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.take() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.take() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.take() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                guard gate.take() else { return }
                connection.cancel()
                continuation.resume(throwing: RecorderAppError.ftpTimedOut)
            }
        }
        return client
    }

    func cancel() {
        connection.cancel()
    }

    func command(_ value: String, expected: Int) async throws -> FTPReply {
        try await command(value, accepted: [expected])
    }

    func command(_ value: String, accepted: Set<Int>) async throws -> FTPReply {
        try await send(Data("\(value)\r\n".utf8))
        let reply = try await readReply()
        guard accepted.contains(reply.code) else {
            throw RecorderAppError.malformedFTPReply(reply.message)
        }
        return reply
    }

    func sendCommandWithoutWaiting(_ value: String) async throws {
        try await send(Data("\(value)\r\n".utf8))
    }

    func readReply(expected: Int) async throws -> FTPReply {
        let reply = try await readReply()
        guard reply.code == expected else {
            throw RecorderAppError.malformedFTPReply(reply.message)
        }
        return reply
    }

    func readReply() async throws -> FTPReply {
        while true {
            if let lineRange = receiveBuffer.range(of: Data("\r\n".utf8)) {
                let lineData = receiveBuffer[..<lineRange.lowerBound]
                receiveBuffer.removeSubrange(..<lineRange.upperBound)
                let line = String(decoding: lineData, as: UTF8.self)
                guard line.count >= 3, let code = Int(line.prefix(3)) else {
                    throw RecorderAppError.malformedFTPReply(line)
                }
                return FTPReply(code: code, message: line)
            }
            receiveBuffer.append(try await receiveChunk())
        }
    }

    func receiveToEnd() async throws -> Data {
        var result = Data()
        while true {
            let chunk = try await receiveChunk(allowEnd: true)
            if chunk.isEmpty { return result }
            result.append(chunk)
        }
    }

    func receiveRawOpus(
        writingTo destinationURL: URL,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> RecorderTransferReceipt {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw RecorderAppError.localStorageFailed("could not create the incoming file")
        }

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }
        var received = 0

        while true {
            let chunk = try await receiveChunk(allowEnd: true)
            if chunk.isEmpty {
                try handle.synchronize()
                try handle.close()
                let result = try RecorderAudioFile.validateOrRecover(at: destinationURL)
                return RecorderTransferReceipt(
                    byteCount: result.byteCount,
                    frameCount: result.frameCount,
                    discardedFrameCount: result.discardedFrameCount
                )
            }
            try handle.write(contentsOf: chunk)
            received += chunk.count
            progress(received)
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveChunk(allowEnd: Bool = false) async throws -> Data {
        if didReachEnd {
            if allowEnd { return Data() }
            throw RecorderAppError.malformedFTPReply("Connection closed")
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let gate = ContinuationGate()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data,
                _,
                isComplete,
                error in
                guard gate.take() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    if isComplete { self.didReachEnd = true }
                    continuation.resume(returning: data)
                } else if isComplete {
                    if allowEnd {
                        continuation.resume(returning: Data())
                    } else {
                        continuation.resume(
                            throwing: RecorderAppError.malformedFTPReply("Connection closed")
                        )
                    }
                } else {
                    continuation.resume(throwing: RecorderAppError.malformedFTPReply("Connection closed"))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                guard gate.take() else { return }
                self.connection.cancel()
                continuation.resume(throwing: RecorderAppError.ftpTimedOut)
            }
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}
