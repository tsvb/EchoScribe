import Foundation
import Combine

/// One recorded meeting: durable audio + optional analysis + provenance.
struct Meeting: Codable, Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    var participants: [String]
    var engine: String?                     // "apple" | "gemini" — what produced the analysis
    var model: String?                      // e.g. "gemini-3.5-flash" or "apple-on-device"
    var analysis: MeetingAnalysisResponse?  // nil = not analyzed yet
    var audioFileName: String               // "<id>.m4a", relative to the store directory
}

/// Owns ~/Library/Application Support/EchoScribe/: meetings.json (index, newest
/// first) plus one .m4a per meeting. Single source of truth for the history UI.
/// The directory is injectable so tests point it at a temp dir.
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("meetings.json") }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoScribe", isDirectory: true)
    }

    init(directory: URL = MeetingStore.defaultDirectory()) {
        self.directory = directory
        load()
    }

    func audioURL(for meeting: Meeting) -> URL {
        directory.appendingPathComponent(meeting.audioFileName)
    }

    /// Moves (not copies) the finished recording into the store and prepends the
    /// meeting. Returns nil (and sets lastError) if the move or save fails.
    @discardableResult
    func create(audioAt tempURL: URL, title: String, participants: [String],
                duration: TimeInterval) -> Meeting? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let fileName = "\(id.uuidString).m4a"
            let storeURL = directory.appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: tempURL, to: storeURL)
            let meeting = Meeting(id: id, title: title, createdAt: Date(), duration: duration,
                                  participants: participants, engine: nil, model: nil,
                                  analysis: nil, audioFileName: fileName)
            meetings.insert(meeting, at: 0)
            if !saveIndex() {
                // Rollback: remove from memory and move audio file back
                meetings.removeAll { $0.id == id }
                try? FileManager.default.moveItem(at: storeURL, to: tempURL)
                return nil
            }
            return meeting
        } catch {
            lastError = "Failed to save recording: \(error.localizedDescription)"
            return nil
        }
    }

    func updateAnalysis(id: UUID, analysis: MeetingAnalysisResponse, engine: String, model: String) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        let previous = meetings[idx]
        meetings[idx].analysis = analysis
        meetings[idx].engine = engine
        meetings[idx].model = model
        if !saveIndex() {
            meetings[idx] = previous
        }
    }

    func rename(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        let previous = meetings[idx].title
        meetings[idx].title = trimmed
        if !saveIndex() {
            meetings[idx].title = previous
        }
    }

    func delete(id: UUID) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        let meeting = meetings[idx]
        meetings.remove(at: idx)
        if !saveIndex() {
            meetings.insert(meeting, at: idx)
            return
        }
        try? FileManager.default.removeItem(at: audioURL(for: meeting))
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return } // first launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            meetings = try decoder.decode([Meeting].self, from: data)
        } catch {
            // Corrupted index: keep the evidence, never touch audio files.
            let backup = directory.appendingPathComponent("meetings.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            meetings = []
            lastError = "Meeting index was unreadable — moved to meetings.json.bak and started fresh. Audio files were kept."
        }
    }

    @discardableResult private func saveIndex() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (try encoder.encode(meetings)).write(to: indexURL, options: .atomic)
            return true
        } catch {
            lastError = "Failed to save meeting index: \(error.localizedDescription)"
            return false
        }
    }
}
