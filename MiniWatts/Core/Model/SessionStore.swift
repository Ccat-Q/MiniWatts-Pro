import Foundation

/// Serialized disk operations; complete curves are loaded only for details/export.
actor SessionStore {
    nonisolated static let sampleInterval: TimeInterval = 5
    private nonisolated struct Document: Codable { let version: Int; let session: ChargeSession }
    private nonisolated struct Index: Codable { let version: Int; let sessions: [ChargeSession] }
    private let root: URL
    private var cache: [UUID: ChargeSession]?
    private var warnings: [String] = []
    private var deletedIDs: Set<UUID> = []

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniWattsProSessions", isDirectory: true)
    }
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    private func read(_ id: UUID) throws -> ChargeSession {
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url(id)))
        guard document.version == 1, document.session.id == id else {
            throw NSError(domain: "MiniWattsPro.History", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Unsupported history format")])
        }
        return document.session
    }
    private func writeIndex() throws {
        try JSONEncoder().encode(Index(version: 1, sessions: sorted())).write(to: indexURL, options: .atomic)
    }
    private func sorted() -> [ChargeSession] { (cache ?? [:]).values.sorted { $0.start > $1.start } }
    private func loadIndex() throws {
        guard cache == nil else { return }
        try prepare()
        var values: [UUID: ChargeSession] = [:]
        var indexDate = Date.distantPast
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                values = Dictionary(index.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                indexDate = try indexURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            } catch {
                warnings.append(String(localized: "History index was rebuilt."))
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        let ids = Set(files.compactMap { $0.pathExtension == "json" ? UUID(uuidString: $0.deletingPathExtension().lastPathComponent) : nil })
        values = values.filter { ids.contains($0.key) }
        for id in ids {
            let modified = try url(id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if values[id] == nil || values[id]?.isOpen == true || modified > indexDate {
                do {
                    var session = try read(id)
                    if session.isOpen {
                        session.end = session.lastObserved
                        session.interrupted = true
                        try JSONEncoder().encode(Document(version: 1, session: session)).write(to: url(id), options: .atomic)
                    }
                    values[id] = session.summary()
                } catch {
                    let preserved = root.appendingPathComponent(id.uuidString + ".corrupt-" + UUID().uuidString)
                    try FileManager.default.moveItem(at: url(id), to: preserved)
                    warnings.append(String(localized: "A damaged session was preserved separately.") + " " + preserved.lastPathComponent)
                    values[id] = nil
                }
            }
        }
        cache = values
        try writeIndex()
    }
    func loaded() throws -> [ChargeSession] { try loadIndex(); return sorted().filter { !$0.isOpen } }
    func readWarning() -> String? { warnings.isEmpty ? nil : warnings.joined(separator: "\n") }
    func save(_ session: ChargeSession) throws -> ChargeSession {
        try loadIndex()
        if deletedIDs.contains(session.id) { return session.summary() }
        if let saved = cache?[session.id], (!saved.isOpen && session.isOpen) || saved.lastObserved > session.lastObserved {
            return saved
        }
        try JSONEncoder().encode(Document(version: 1, session: session)).write(to: url(session.id), options: .atomic)
        let summary = session.summary()
        cache?[session.id] = summary
        try writeIndex()
        return summary
    }
    func detail(_ id: UUID) throws -> ChargeSession { try read(id) }
    func delete(_ ids: Set<UUID>) throws -> [ChargeSession] {
        try loadIndex()
        for id in ids where cache?[id]?.isOpen == false {
            try FileManager.default.removeItem(at: url(id))
            cache?[id] = nil
            deletedIDs.insert(id)
        }
        try writeIndex()
        return sorted().filter { !$0.isOpen }
    }
    func bytesUsed() throws -> Int64 {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0)) { total, file in total + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }
}
