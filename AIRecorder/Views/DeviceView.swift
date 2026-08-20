import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var bluetooth: BLERecorderClient

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    connectionSection
                    Divider().padding(.vertical, 22)

                    if model.isBusy {
                        activitySection
                    } else if bluetooth.isConnected {
                        statusSection
                        Divider().padding(.vertical, 22)
                        actionsSection
                    } else {
                        discoverySection
                    }

                    if !model.isBusy {
                        activitySection
                    }
                    syncReportSection
                }
                .padding(20)
            }
            .background(appBackground)
            .navigationTitle("Wearable")
            .toolbar {
                if bluetooth.isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            bluetooth.disconnect()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel("Disconnect")
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        HStack(spacing: 14) {
            Image(systemName: bluetooth.isConnected ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(bluetooth.isConnected ? .green : .secondary)
                .frame(width: 44, height: 44)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(connectionTitle)
                    .font(.headline)
                Text(connectionSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                bluetooth.scan()
            } label: {
                HStack(spacing: 8) {
                    if bluetooth.isScanning {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(scanButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(bluetooth.isScanning)

            ForEach(bluetooth.discovered) { recorder in
                Button {
                    bluetooth.connect(recorder)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: recorder.isCompatibleRecorder ? "waveform.badge.mic" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(recorder.isCompatibleRecorder ? Color.accentColor : Color.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recorder.name)
                                .font(.body.weight(.medium))
                            Text(deviceDetail(recorder))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            if let error = bluetooth.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let summary = bluetooth.lastScanSummary {
                Label(summary, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let event = bluetooth.lastEvent {
                Label(event, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        VStack(spacing: 14) {
            HStack {
                StatusValue(
                    title: "Battery",
                    value: bluetooth.status.map { "\($0.approximateBatteryPercent)%" } ?? "—",
                    symbol: "battery.75percent"
                )
                StatusValue(
                    title: "Storage free",
                    value: bluetooth.status.map { "\($0.freeStoragePercent)%" } ?? "—",
                    symbol: "sdcard"
                )
            }
            HStack {
                Label(
                    bluetooth.status?.isRecording == true ? "Recording now" : "Ready to record",
                    systemImage: bluetooth.status?.isRecording == true ? "record.circle.fill" : "checkmark"
                )
                .foregroundStyle(bluetooth.status?.isRecording == true ? .red : .secondary)
                Spacer()
                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh status")
            }
            .font(.subheadline)
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 14) {
            Button {
                Task { await model.toggleBLELiveAudio() }
            } label: {
                Label(
                    bluetooth.isLiveAudioStreaming ? "Stop Live Audio" : "Save Live Audio",
                    systemImage: bluetooth.isLiveAudioStreaming ? "stop.fill" : "waveform"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(bluetooth.isLiveAudioStreaming ? .red : .accentColor)
            .disabled(
                model.isBusy
                    || (!bluetooth.isLiveAudioAvailable && !bluetooth.isLiveAudioStreaming)
            )

            if bluetooth.isLiveAudioStreaming {
                let statistics = bluetooth.liveAudioStatistics
                HStack {
                    Label("Receiving", systemImage: "dot.radiowaves.left.and.right")
                    Spacer()
                    Text("\(Int(statistics.durationSeconds))s")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if !bluetooth.isLiveAudioAvailable {
                Text("Live audio requires recorder characteristic A103.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.toggleRecording() }
            } label: {
                Label(
                    bluetooth.status?.isRecording == true ? "Stop Recording" : "Start Recording",
                    systemImage: bluetooth.status?.isRecording == true ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isBusy || bluetooth.isLiveAudioStreaming)

            Button {
                Task { await model.sync() }
            } label: {
                Label("Download Recordings", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                model.isBusy
                    || bluetooth.status?.isRecording == true
                    || bluetooth.isLiveAudioStreaming
            )
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        switch model.activity {
        case .idle:
            EmptyView()
        case .working(let title, let progress):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView()
                    Text(title).font(.subheadline.weight(.medium))
                }
                if let progress {
                    ProgressView(value: progress)
                }
                if !model.syncDetail.isEmpty,
                   model.syncStage != .idle,
                   model.syncStage != .complete
                {
                    Text(model.syncDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 22)
        case .finished(let message):
            resultBanner(message, color: .green, symbol: "checkmark.circle.fill")
        case .failed(let message):
            resultBanner(message, color: .red, symbol: "exclamationmark.triangle.fill")
        }
    }

    @ViewBuilder
    private var syncReportSection: some View {
        if let report = model.lastSyncReport {
            Divider().padding(.vertical, 22)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfer Report")
                        .font(.subheadline.weight(.semibold))
                    Text(model.syncStage.supportCode)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: report) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share transfer report")
            }
        }
    }

    private func resultBanner(_ message: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message).font(.subheadline)
            Spacer()
            Button {
                model.dismissActivity()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 22)
    }

    private var connectionTitle: String {
        if model.isBusy, model.syncStage != .idle {
            return model.syncStage.title
        }
        return switch bluetooth.connectionState {
        case .unavailable: "Bluetooth unavailable"
        case .idle: "No recorder connected"
        case .scanning: "Searching nearby"
        case .connecting: "Connecting"
        case .connected(let name): name
        }
    }

    private var connectionSubtitle: String {
        if model.isBusy, model.syncStage != .idle {
            return model.syncDetail.isEmpty
                ? "Keep Dawn Recorder open until the transfer finishes"
                : model.syncDetail
        }
        return switch bluetooth.connectionState {
        case .unavailable(let reason): reason
        case .idle: "Keep the recorder nearby and powered on"
        case .scanning: "Showing every nearby BLE device iPhone can detect"
        case .connecting: "This usually takes a few seconds"
        case .connected: "Connected by Bluetooth"
        }
    }

    private func signalText(_ value: Int) -> String {
        if value >= -55 { return "Strong signal" }
        if value >= -72 { return "Good signal" }
        return "Move closer"
    }

    private func deviceDetail(_ device: BLERecorderClient.DiscoveredRecorder) -> String {
        let kind = device.isCompatibleRecorder ? "Compatible recorder" : "Other BLE device"
        return "\(kind) · \(signalText(device.signal)) · \(device.signal) dBm"
    }

    private var scanButtonTitle: String {
        if bluetooth.isScanning { return "Searching..." }
        return bluetooth.discovered.isEmpty ? "Find Recorder" : "Scan Again"
    }

    private var appBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.gray.opacity(0.08)
        #endif
    }
}

private struct StatusValue: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }
            Spacer()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
