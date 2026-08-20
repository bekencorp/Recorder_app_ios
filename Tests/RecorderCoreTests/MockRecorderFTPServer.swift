import Foundation
import Network

final class MockRecorderFTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DawnRecorder.MockFTP")
    private let recordingFilename: String
    private let recordingData: Data
    private let rejectsList: Bool
    private let requiresAbsoluteRecordDirectory: Bool
    private var listener: NWListener?
    private var sessions: [MockRecorderFTPControlSession] = []

    init(
        recordingFilename: String,
        recordingData: Data,
        rejectsList: Bool = false,
        requiresAbsoluteRecordDirectory: Bool = false
    ) {
        self.recordingFilename = recordingFilename
        self.recordingData = recordingData
        self.rejectsList = rejectsList
        self.requiresAbsoluteRecordDirectory = requiresAbsoluteRecordDirectory
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let gate = MockContinuationGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.take(), let port = listener.port?.rawValue else { return }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard gate.take() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let session = MockRecorderFTPControlSession(
                    connection: connection,
                    queue: self.queue,
                    recordingFilename: self.recordingFilename,
                    recordingData: self.recordingData,
                    rejectsList: self.rejectsList,
                    requiresAbsoluteRecordDirectory: self.requiresAbsoluteRecordDirectory
                )
                self.sessions.append(session)
                session.start()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        sessions.forEach { $0.stop() }
        sessions = []
    }

}

private final class MockRecorderFTPControlSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let recordingFilename: String
    private let recordingData: Data
    private let rejectsList: Bool
    private let requiresAbsoluteRecordDirectory: Bool
    private var receiveBuffer = Data()
    private var passiveListener: NWListener?
    private var dataConnection: NWConnection?
    private var dataConnectionReady = false
    private var pendingData: Data?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        recordingFilename: String,
        recordingData: Data,
        rejectsList: Bool,
        requiresAbsoluteRecordDirectory: Bool
    ) {
        self.connection = connection
        self.queue = queue
        self.recordingFilename = recordingFilename
        self.recordingData = recordingData
        self.rejectsList = rejectsList
        self.requiresAbsoluteRecordDirectory = requiresAbsoluteRecordDirectory
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.sendControl("220 Dawn Recorder simulator ready\r\n")
                self.receiveCommand()
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        passiveListener?.cancel()
        dataConnection?.cancel()
        connection.cancel()
    }

    private func receiveCommand() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            if let data { self.receiveBuffer.append(data) }
            while let range = self.receiveBuffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: self.receiveBuffer[..<range.lowerBound], as: UTF8.self)
                self.receiveBuffer.removeSubrange(..<range.upperBound)
                self.handle(line)
            }
            if !isComplete { self.receiveCommand() }
        }
    }

    private func handle(_ command: String) {
        let upper = command.uppercased()
        if upper.hasPrefix("USER ") {
            sendControl("331 Password required\r\n")
        } else if upper.hasPrefix("PASS ") {
            sendControl("230 Logged in\r\n")
        } else if upper == "TYPE I" {
            sendControl("200 Binary mode\r\n")
        } else if upper == "CWD RECORD" {
            sendControl(requiresAbsoluteRecordDirectory ? "550 Use absolute path\r\n" : "250 Directory changed\r\n")
        } else if upper == "CWD /RECORD" {
            sendControl("250 Directory changed\r\n")
        } else if upper == "PASV" {
            startPassiveListener()
        } else if upper == "LIST" && rejectsList {
            resetPassiveTransfer()
            sendControl("500 LIST unsupported\r\n")
        } else if upper == "LIST" || upper == "NLST" {
            let listing: String
            if upper == "LIST" {
                listing = "-rw-rw-rw- 1 user ftp \(recordingData.count) Aug 03 12:00 \(recordingFilename)\r\n"
            } else {
                listing = "\(recordingFilename)\r\n"
            }
            sendTransfer(Data(listing.utf8))
        } else if upper == "RETR \(recordingFilename.uppercased())" {
            sendTransfer(recordingData)
        } else if upper == "QUIT" {
            sendControl("221 Goodbye\r\n")
        } else {
            sendControl("500 Unsupported command\r\n")
        }
    }

    private func startPassiveListener() {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            passiveListener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state, let port = listener.port?.rawValue else {
                    return
                }
                let high = port / 256
                let low = port % 256
                self.sendControl("227 Entering Passive Mode (127,0,0,1,\(high),\(low))\r\n")
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.dataConnection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, case .ready = state else { return }
                    self.dataConnectionReady = true
                    self.flushPendingData()
                }
                connection.start(queue: self.queue)
            }
            listener.start(queue: queue)
        } catch {
            sendControl("425 Cannot open passive connection\r\n")
        }
    }

    private func sendTransfer(_ data: Data) {
        sendControl("150 Opening data connection\r\n")
        pendingData = data
        flushPendingData()
    }

    private func flushPendingData() {
        guard dataConnectionReady,
              let dataConnection,
              let pendingData
        else {
            return
        }
        self.pendingData = nil
        dataConnection.send(
            content: pendingData,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.sendControl("226 Transfer complete\r\n")
                self.passiveListener?.cancel()
                self.passiveListener = nil
                self.dataConnection = nil
                self.dataConnectionReady = false
            }
        )
    }

    private func sendControl(_ value: String) {
        connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in })
    }

    private func resetPassiveTransfer() {
        passiveListener?.cancel()
        dataConnection?.cancel()
        passiveListener = nil
        dataConnection = nil
        dataConnectionReady = false
        pendingData = nil
    }
}

private final class MockContinuationGate: @unchecked Sendable {
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
