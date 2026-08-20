import Foundation

public struct LocalRecording: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public let localFilename: String
    public let remoteFilename: String?
    public let byteSize: Int
    public let audioFormat: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        localFilename: String,
        remoteFilename: String? = nil,
        byteSize: Int,
        audioFormat: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.localFilename = localFilename
        self.remoteFilename = remoteFilename
        self.byteSize = byteSize
        self.audioFormat = audioFormat
    }
}
