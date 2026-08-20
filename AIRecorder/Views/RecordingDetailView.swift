import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let recordingID: UUID
    @ObservedObject var recordings: RecordingStore

    @State private var showingRename = false
    @State private var title = ""
    @State private var showingDelete = false

    private var recording: LocalRecording? {
        recordings.recordings.first { $0.id == recordingID }
    }

    var body: some View {
        Group {
            if let recording {
                List {
                    Section("Recording") {
                        LabeledContent(
                            "Recorded",
                            value: recording.createdAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        LabeledContent("Source", value: sourceLabel(for: recording))
                        LabeledContent(
                            "Size",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(recording.byteSize),
                                countStyle: .file
                            )
                        )
                        LabeledContent("Format", value: "Opus audio")
                    }

                    Section {
                        Label("Stored locally on this iPhone", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        ShareLink(item: recordings.audioURL(for: recording)) {
                            Label("Share Audio File", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .navigationTitle(recording.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            title = recording.title
                            showingRename = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Rename recording")
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(role: .destructive) {
                            showingDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete recording")
                    }
                }
                .alert("Rename Recording", isPresented: $showingRename) {
                    TextField("Title", text: $title)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        recordings.rename(recording, to: title)
                    }
                }
                .confirmationDialog(
                    "Delete this recording from the iPhone?",
                    isPresented: $showingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        recordings.delete(recording)
                        dismiss()
                    }
                }
            } else {
                ContentUnavailableView("Recording Not Found", systemImage: "waveform.slash")
            }
        }
    }

    private func sourceLabel(for recording: LocalRecording) -> String {
        recording.remoteFilename?.hasPrefix("ble://") == true
            ? "BLE live audio"
            : "Wearable recorder"
    }
}
