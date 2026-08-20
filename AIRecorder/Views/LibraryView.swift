import SwiftUI

struct LibraryView: View {
    @ObservedObject var recordings: RecordingStore

    var body: some View {
        NavigationStack {
            Group {
                if recordings.recordings.isEmpty {
                    ContentUnavailableView {
                        Label("No Recordings", systemImage: "waveform")
                    } description: {
                        Text("Connect the wearable, then download its saved recordings.")
                    }
                } else {
                    List(recordings.recordings) { recording in
                        NavigationLink {
                            RecordingDetailView(
                                recordingID: recording.id,
                                recordings: recordings
                            )
                        } label: {
                            RecordingRow(recording: recording)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recordings")
        }
    }
}

private struct RecordingRow: View {
    let recording: LocalRecording

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(sourceLabel)
                    Text("·")
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(recording.byteSize),
                        countStyle: .file
                    ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Saved on iPhone")
        }
        .padding(.vertical, 5)
    }

    private var sourceLabel: String {
        recording.remoteFilename?.hasPrefix("ble://") == true ? "BLE" : "Wearable"
    }
}
