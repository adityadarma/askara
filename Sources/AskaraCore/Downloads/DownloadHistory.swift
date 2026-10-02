import Foundation

public struct DownloadHistory: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable { case finished, cancelled, failed }
    public enum ScanOutcome: String, Codable, Equatable, Sendable { case waiting, complete, failed }

    public struct Record: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var filename: String
        public var destination: URL?
        public var sourceURL: URL?
        public var endedAt: Date
        public var outcome: Outcome
        public var failureMessage: String?
        public var scanOutcome: ScanOutcome
        public var scanFailureMessage: String?
        public var sha256: String?
        public var risks: [DownloadRisk]
        public var fileSize: Int64?

        public init(id: UUID, filename: String, destination: URL?, sourceURL: URL?, endedAt: Date,
                    outcome: Outcome, failureMessage: String? = nil, scanOutcome: ScanOutcome = .waiting,
                    scanFailureMessage: String? = nil, sha256: String? = nil,
                    risks: [DownloadRisk] = [], fileSize: Int64? = nil) {
            self.id = id
            self.filename = filename
            self.destination = destination
            self.sourceURL = sourceURL
            self.endedAt = endedAt
            self.outcome = outcome
            self.failureMessage = failureMessage
            self.scanOutcome = scanOutcome
            self.scanFailureMessage = scanFailureMessage
            self.sha256 = sha256
            self.risks = risks
            self.fileSize = fileSize
        }
    }

    public var records: [Record]
    public init(records: [Record] = []) { self.records = records }
}
