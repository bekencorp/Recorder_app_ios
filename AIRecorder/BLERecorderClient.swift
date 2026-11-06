import CoreBluetooth
import Foundation

@MainActor
final class BLERecorderClient: NSObject, ObservableObject {
    struct DiscoveredRecorder: Identifiable, Equatable {
        let id: UUID
        let name: String
        let signal: Int
        let isCompatibleRecorder: Bool
        fileprivate let peripheral: CBPeripheral

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.signal == rhs.signal
                && lhs.isCompatibleRecorder == rhs.isCompatibleRecorder
        }
    }

    enum ConnectionState: Equatable {
        case unavailable(String)
        case idle
        case scanning
        case connecting
        case connected(String)
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var discovered: [DiscoveredRecorder] = []
    @Published private(set) var status: RecorderStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var lastEvent: String?
    @Published private(set) var lastScanSummary: String?
    @Published private(set) var isLiveAudioAvailable = false
    @Published private(set) var isLiveAudioStreaming = false
    @Published private(set) var liveAudioStatistics = BLEOpusStreamStatistics(
        byteCount: 0,
        frameCount: 0,
        discardedFrameCount: 0
    )

    private static let serviceUUID = CBUUID(string: "A001")
    private static let responseUUID = CBUUID(string: "A101")
    private static let commandUUID = CBUUID(string: "A102")
    private static let audioUUID = CBUUID(string: "A103")

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var commandWriteType: CBCharacteristicWriteType?
    private var liveAudioCapture: BLELiveAudioCapture?
    private var liveRecordingStartedByApp = false
    private var transferHandoffExpected = false
    private var sequence: UInt8 = 0
    private var scanGeneration = UUID()
    private var scanRequestedWhenReady = false
    private var connectionGeneration = UUID()
    private var pending: [
        UInt8: (command: RecorderCommand, continuation: CheckedContinuation<RecorderResponse, Error>)
    ] = [:]

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isScanning: Bool {
        if case .scanning = connectionState { return true }
        return false
    }

    func prepare() {
        _ = central
    }

    func scan() {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .unknown, .resetting:
            scanRequestedWhenReady = true
            lastError = nil
            lastScanSummary = "Preparing Bluetooth..."
            connectionState = .scanning
            scanGeneration = UUID()
            let generation = scanGeneration
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard scanRequestedWhenReady, generation == scanGeneration else { return }
                scanRequestedWhenReady = false
                connectionState = .unavailable("Bluetooth did not become ready")
                lastError = "Open iPhone Settings, allow Bluetooth for Dawn Recorder, and try again."
            }
        case .poweredOff:
            scanRequestedWhenReady = false
            lastError = "Turn on Bluetooth to find the recorder."
        case .unauthorized:
            scanRequestedWhenReady = false
            lastError = "Allow Bluetooth for Dawn Recorder in iPhone Settings."
        case .unsupported:
            scanRequestedWhenReady = false
            lastError = "Bluetooth Low Energy is not supported on this device."
        @unknown default:
            scanRequestedWhenReady = false
            lastError = "Bluetooth is not ready. Try again in a moment."
        }
    }

    private func beginScan() {
        scanRequestedWhenReady = false
        discovered = []
        lastError = nil
        lastScanSummary = nil
        connectionState = .scanning
        scanGeneration = UUID()
        let generation = scanGeneration
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        Task {
            try? await Task.sleep(for: .seconds(8))
            if generation == scanGeneration,
               case .scanning = connectionState
            {
                stopScan()
            }
        }
    }

    func stopScan() {
        scanRequestedWhenReady = false
        scanGeneration = UUID()
        central.stopScan()
        if case .scanning = connectionState {
            connectionState = .idle
            if discovered.isEmpty {
                lastScanSummary = "No BLE advertisements received. Confirm Bluetooth access and that nearby devices are powered on and advertising."
            } else {
                let count = discovered.count
                let compatibleCount = discovered.filter(\.isCompatibleRecorder).count
                if compatibleCount == 0 {
                    lastScanSummary = "Bluetooth is working. Found \(count) nearby BLE device\(count == 1 ? "" : "s"), but no compatible recorder yet."
                } else {
                    lastScanSummary = "Found \(count) nearby BLE device\(count == 1 ? "" : "s"), including \(compatibleCount) compatible recorder\(compatibleCount == 1 ? "" : "s")."
                }
            }
        }
    }

    func connect(_ recorder: DiscoveredRecorder) {
        stopScan()
        lastError = nil
        connectionState = .connecting
        connectedPeripheral = recorder.peripheral
        recorder.peripheral.delegate = self
        central.connect(recorder.peripheral)
        connectionGeneration = UUID()
        let generation = connectionGeneration
        Task {
            try? await Task.sleep(for: .seconds(12))
            guard generation == connectionGeneration,
                  case .connecting = connectionState
            else {
                return
            }
            central.cancelPeripheralConnection(recorder.peripheral)
            connectedPeripheral = nil
            connectionState = .idle
            lastError = "The recorder did not finish connecting. Move it closer and try again."
        }
    }

    func disconnect() {
        connectionGeneration = UUID()
        liveAudioCapture?.cancel()
        liveAudioCapture = nil
        liveRecordingStartedByApp = false
        isLiveAudioStreaming = false
        guard let connectedPeripheral else {
            connectionState = .idle
            return
        }
        central.cancelPeripheralConnection(connectedPeripheral)
    }

    func synchronizeTime() async throws {
        let unixTime = UInt32(Date().timeIntervalSince1970)
        _ = try await send(.setTime, payload: {
            var data = Data()
            data.append(contentsOf: [
                UInt8(truncatingIfNeeded: unixTime),
                UInt8(truncatingIfNeeded: unixTime >> 8),
                UInt8(truncatingIfNeeded: unixTime >> 16),
                UInt8(truncatingIfNeeded: unixTime >> 24)
            ])
            return data
        }())
    }

    @discardableResult
    func refreshStatus() async throws -> RecorderStatus {
        let response = try await send(.getStatus)
        let value = try RecorderStatus(data: response.data)
        status = value
        return value
    }

    func startRecording(scene: UInt8 = 0) async throws {
        _ = try await send(.startRecord, payload: Data([scene]))
        try await waitForRecordingState(true)
    }

    func stopRecording() async throws {
        do {
            _ = try await send(.stopRecord, timeout: 2)
        } catch RecorderAppError.commandTimedOut {
            // Current board firmware can perform STOP_RECORD without returning
            // its command response. The status push/GET_STATUS is authoritative.
        }
        try await waitForRecordingState(false)
    }

    func startLiveAudioCapture(to fileURL: URL, scene: UInt8 = 0) async throws {
        guard isLiveAudioAvailable, audioCharacteristic?.isNotifying == true else {
            throw RecorderAppError.bleAudioStreamUnavailable
        }
        guard liveAudioCapture == nil else { return }

        let wasRecording = status?.isRecording == true
        if !wasRecording {
            try await startRecording(scene: scene)
        }

        do {
            let capture = try BLELiveAudioCapture(fileURL: fileURL)
            liveAudioCapture = capture
            liveRecordingStartedByApp = !wasRecording
            liveAudioStatistics = capture.statistics
            _ = try await send(.startBLEStream)
            try await waitForStreamingState(true)
            isLiveAudioStreaming = true
            lastEvent = "Receiving live audio from the recorder."
        } catch {
            _ = try? await send(.stopBLEStream, timeout: 2)
            liveAudioCapture?.cancel()
            liveAudioCapture = nil
            liveRecordingStartedByApp = false
            if !wasRecording { try? await stopRecording() }
            throw error
        }
    }

    func stopLiveAudioCapture() async throws -> BLELiveAudioCaptureResult {
        guard let capture = liveAudioCapture else {
            throw RecorderAppError.bleAudioStreamUnavailable
        }
        let shouldStopRecording = liveRecordingStartedByApp

        do {
            _ = try await send(.stopBLEStream, timeout: 3)
        } catch RecorderAppError.commandTimedOut {
            // The status push and the absence of further A103 frames are authoritative.
        }
        try? await waitForStreamingState(false)
        if shouldStopRecording {
            // Preserve the received audio even when firmware performs STOP_RECORD
            // but misses its response or next status push.
            try? await stopRecording()
        }

        do {
            let result = try capture.finish()
            liveAudioCapture = nil
            liveRecordingStartedByApp = false
            isLiveAudioStreaming = false
            liveAudioStatistics = result.statistics
            lastEvent = "Live audio saved on this iPhone."
            return result
        } catch {
            capture.cancel()
            liveAudioCapture = nil
            liveRecordingStartedByApp = false
            isLiveAudioStreaming = false
            throw error
        }
    }

    func requestTransferNetwork() async throws -> RecorderWiFiCredentials {
        guard !isLiveAudioStreaming else {
            throw RecorderAppError.bleAudioStreamUnavailable
        }
        do {
            let response = try await send(.startWiFiAP, timeout: 15)
            let credentials = try RecorderWiFiCredentials(data: response.data)
            transferHandoffExpected = true
            return credentials
        } catch RecorderAppError.notConnected, RecorderAppError.commandTimedOut {
            throw RecorderAppError.transferCredentialsMissing
        }
    }

    private func send(
        _ command: RecorderCommand,
        payload: Data = Data(),
        timeout: TimeInterval = 8
    ) async throws -> RecorderResponse {
        guard let connectedPeripheral,
              let commandCharacteristic,
              responseCharacteristic?.isNotifying == true,
              let commandWriteType
        else {
            throw RecorderAppError.notConnected
        }
        sequence &+= 1
        let currentSequence = sequence
        let frame = RecorderWire.command(command, sequence: currentSequence, payload: payload)

        return try await withCheckedThrowingContinuation { continuation in
            pending[currentSequence] = (command, continuation)
            connectedPeripheral.writeValue(
                frame,
                for: commandCharacteristic,
                type: commandWriteType
            )
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard let request = pending.removeValue(forKey: currentSequence) else { return }
                request.continuation.resume(throwing: RecorderAppError.commandTimedOut)
            }
        }
    }

    private func acceptNotification(_ value: Data) {
        do {
            switch try RecorderNotification(frame: value) {
            case .response(let response):
                guard let request = pending.removeValue(forKey: response.sequence) else { return }
                do {
                    try response.requireSuccess(
                        for: request.command,
                        sequence: response.sequence
                    )
                    request.continuation.resume(returning: response)
                } catch {
                    request.continuation.resume(throwing: error)
                    lastError = error.localizedDescription
                }
            case .status(let value):
                status = value
            case .event(let event):
                lastEvent = Self.eventDescription(event)
                Task { _ = try? await refreshStatus() }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func waitForRecordingState(_ expected: Bool) async throws {
        for _ in 0..<40 {
            if status?.isRecording == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }

        let refreshed = try await refreshStatus()
        guard refreshed.isRecording == expected else {
            throw RecorderAppError.commandTimedOut
        }
    }

    private func waitForStreamingState(_ expected: Bool) async throws {
        for _ in 0..<40 {
            if status?.isBLEStreaming == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let refreshed = try await refreshStatus()
        guard refreshed.isBLEStreaming == expected else {
            throw RecorderAppError.commandTimedOut
        }
    }

    private func acceptLiveAudio(_ value: Data) {
        guard let capture = liveAudioCapture else { return }
        do {
            try capture.append(notification: value)
            liveAudioStatistics = capture.statistics
        } catch {
            capture.cancel()
            liveAudioCapture = nil
            liveRecordingStartedByApp = false
            isLiveAudioStreaming = false
            lastError = "BLE live audio stopped [BLE-LIVE-003]: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func failPendingRequests(
        with error: Error,
        treatingTransferDisconnectAsHandoff: Bool = false
    ) -> Bool {
        let requests = Array(pending.values)
        pending.removeAll()
        var completedTransferHandoff = false
        for request in requests {
            if RecorderTransferHandoffPolicy.acceptsDisconnect(
                while: request.command,
                handoffExpected: treatingTransferDisconnectAsHandoff
            ) {
                completedTransferHandoff = true
                request.continuation.resume(throwing: RecorderAppError.notConnected)
            } else {
                request.continuation.resume(throwing: error)
            }
        }
        return completedTransferHandoff
    }

    private static func eventDescription(_ event: RecorderEvent) -> String {
        switch event.code {
        case 0x10:
            let free = event.data.first.map { " (\($0)% free)" } ?? ""
            return "Recorder storage is running low\(free)."
        case 0x11:
            return "Recorder storage is full and recording stopped."
        case 0x12:
            let deleted: UInt16? = event.data.count >= 2
                ? UInt16(event.data[0]) | (UInt16(event.data[1]) << 8)
                : nil
            return deleted.map { "Recorder removed \($0) old file(s) to free space." }
                ?? "Recorder removed old files to free space."
        case 0x13:
            switch event.data.first {
            case 1: return "Recording stopped because the battery is low."
            case 3: return "Recording was saved before Wi-Fi transfer started."
            default: return "The recorder stopped recording."
            }
        default:
            return "Recorder event 0x\(String(event.code, radix: 16, uppercase: true))."
        }
    }
}

extension BLERecorderClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if scanRequestedWhenReady {
                    beginScan()
                } else if case .unavailable = connectionState {
                    connectionState = .idle
                }
            case .poweredOff:
                connectionState = .unavailable("Bluetooth is off")
            case .unauthorized:
                connectionState = .unavailable("Bluetooth permission is required")
            case .unsupported:
                connectionState = .unavailable("Bluetooth is not supported")
            default:
                connectionState = .unavailable("Bluetooth is not ready")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let name = peripheral.name
                ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ?? "Unnamed BLE device"
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let isCompatibleRecorder = name.hasPrefix("NSRecorder-")
                || advertisedServices.contains(Self.serviceUUID)
            let value = DiscoveredRecorder(
                id: peripheral.identifier,
                name: name,
                signal: RSSI.intValue,
                isCompatibleRecorder: isCompatibleRecorder,
                peripheral: peripheral
            )
            discovered.removeAll { $0.id == value.id }
            discovered.append(value)
            discovered.sort {
                if $0.isCompatibleRecorder != $1.isCompatibleRecorder {
                    return $0.isCompatibleRecorder
                }
                return $0.signal > $1.signal
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            connectionGeneration = UUID()
            connectedPeripheral = nil
            failPendingRequests(with: error ?? RecorderAppError.notConnected)
            connectionState = .idle
            lastError = error?.localizedDescription ?? "Could not connect to the recorder."
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let expectedTransferDisconnect = transferHandoffExpected
            transferHandoffExpected = false
            connectionGeneration = UUID()
            connectedPeripheral = nil
            commandCharacteristic = nil
            responseCharacteristic = nil
            audioCharacteristic = nil
            commandWriteType = nil
            liveAudioCapture?.cancel()
            liveAudioCapture = nil
            liveRecordingStartedByApp = false
            isLiveAudioAvailable = false
            isLiveAudioStreaming = false
            status = nil
            failPendingRequests(
                with: error ?? RecorderAppError.notConnected,
                treatingTransferDisconnectAsHandoff: expectedTransferDisconnect
            )
            connectionState = .idle
            if expectedTransferDisconnect {
                lastError = nil
                lastEvent = "Recorder switched from Bluetooth to transfer Wi-Fi."
            } else if let error {
                lastError = error.localizedDescription
            }
        }
    }
}

extension BLERecorderClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
            else {
                lastError = error?.localizedDescription
                    ?? "This BLE device does not provide the Dawn Recorder service (A001)."
                disconnect()
                return
            }
            peripheral.discoverCharacteristics(
                [Self.responseUUID, Self.commandUUID, Self.audioUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil else {
                lastError = error?.localizedDescription
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.responseUUID:
                    responseCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                case Self.commandUUID:
                    commandCharacteristic = characteristic
                    if characteristic.properties.contains(.write) {
                        commandWriteType = .withResponse
                    } else if characteristic.properties.contains(.writeWithoutResponse) {
                        commandWriteType = .withoutResponse
                    }
                case Self.audioUUID:
                    audioCharacteristic = characteristic
                    if characteristic.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                default:
                    break
                }
            }
            guard commandCharacteristic != nil,
                  commandWriteType != nil,
                  responseCharacteristic != nil
            else {
                lastError = "Recorder command channels were not found."
                disconnect()
                return
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if characteristic.uuid == Self.audioUUID {
                isLiveAudioAvailable = error == nil && characteristic.isNotifying
                if let error {
                    lastError = "BLE live audio is unavailable [BLE-LIVE-001]: \(error.localizedDescription)"
                }
                return
            }
            guard characteristic.uuid == Self.responseUUID else { return }
            guard error == nil, characteristic.isNotifying else {
                lastError = error?.localizedDescription
                    ?? "Recorder notifications could not be enabled."
                disconnect()
                return
            }

            connectionGeneration = UUID()
            connectionState = .connected(peripheral.name ?? "Dawn Recorder")
            Task {
                do {
                    try await synchronizeTime()
                    _ = try await refreshStatus()
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            lastError = error.localizedDescription
            failPendingRequests(with: error)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }
            guard let value = characteristic.value else { return }
            switch characteristic.uuid {
            case Self.responseUUID:
                acceptNotification(value)
            case Self.audioUUID:
                acceptLiveAudio(value)
            default:
                return
            }
        }
    }
}
