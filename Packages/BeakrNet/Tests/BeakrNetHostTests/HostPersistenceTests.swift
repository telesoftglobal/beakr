import Foundation
import Testing
import BeakrNetHost

@Suite("Host checkpoint and diagnostics")
struct HostPersistenceTests {
    @Test("Atomic checkpoints survive relaunch and reject generation rollback")
    func checkpointRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("host.json"), now = Date(timeIntervalSince1970: 1_000)
        let first = try FileHostCheckpointStore.open(fileURL: url)
        let checkpoint = HostCheckpoint(generation: 2, lifecycle: .background, checkpointedAt: now, cleanShutdown: false)
        try await first.save(checkpoint)
        let restored = try FileHostCheckpointStore.open(fileURL: url)
        #expect(await restored.load() == checkpoint)
        await #expect(throws: HostCheckpointError.generationRollback) {
            try await restored.save(.init(generation: 2, lifecycle: .foreground, checkpointedAt: now, cleanShutdown: false))
        }
    }

    @Test("Diagnostic retention and export are bounded and canonical")
    func boundedDiagnostics() async throws {
        let journal = HostDiagnosticJournal(policy: .init(maximumEvents: 2, maximumExportBytes: 512))
        let now = Date(timeIntervalSince1970: 1_000)
        await journal.record(.init(timestamp: now, subsystem: .lifecycle, reason: .started))
        await journal.record(.init(timestamp: now, subsystem: .transfer, reason: .integrityFailure, identifier: UUID(), count: 1))
        await journal.record(.init(timestamp: now, subsystem: .permission, reason: .denied))
        #expect(await journal.snapshot().count == 2)
        let first = try await journal.export(), second = try await journal.export()
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        #expect(!text.contains("path")); #expect(!text.contains("payload")); #expect(!text.contains("credential"))
    }

    @Test("Corrupt or future checkpoints fail closed")
    func invalidCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("host.json")
        try Data("not-json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try FileHostCheckpointStore.open(fileURL: url) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(HostCheckpoint(formatVersion: 99, generation: 1, lifecycle: .stopped,
                                          checkpointedAt: Date(timeIntervalSince1970: 1_000), cleanShutdown: true)).write(to: url)
        #expect(throws: HostCheckpointError.unsupportedFormat(99)) { try FileHostCheckpointStore.open(fileURL: url) }
    }
}
