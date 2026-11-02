import Foundation

// All USB access is replaced with an in-memory card. Temporary images and
// pre-change backups are confined to /tmp and removed when the suite finishes.
@main enum FastUploadTests {
    enum Event { case read(Int), write(Int) }

    final class MemoryCard: APFCardTransport {
        var disk: Data
        var events: [Event] = []
        var failReadSector: Int?
        var failWriteSector: Int?
        var corruptWrittenSector: Int?

        init(_ disk: Data) { self.disk = disk }
        var reads: [Int] { events.compactMap { if case .read(let n) = $0 { return n }; return nil } }
        var writes: [Int] { events.compactMap { if case .write(let n) = $0 { return n }; return nil } }
        var preflightReads: [Int] {
            var result: [Int] = []
            for event in events {
                switch event {
                case .read(let sector): result.append(sector)
                case .write: return result
                }
            }
            return result
        }
        func readSector(_ sector: Int, bytesPerSector: Int) throws -> Data {
            events.append(.read(sector))
            if sector == failReadSector { throw APFError("Simulated USB read failure") }
            let range = sector * bytesPerSector..<(sector + 1) * bytesPerSector
            guard range.lowerBound >= 0, range.upperBound <= disk.count else { throw APFError("Mock read outside card") }
            return disk.subdata(in: range)
        }
        func writeSector(_ sector: Int, bytesPerSector: Int, data: Data) throws {
            events.append(.write(sector))
            if sector == failWriteSector { throw APFError("Simulated USB write failure") }
            guard data.count == bytesPerSector else { throw APFError("Mock write length") }
            let range = sector * bytesPerSector..<(sector + 1) * bytesPerSector
            guard range.lowerBound >= 0, range.upperBound <= disk.count else { throw APFError("Mock write outside card") }
            disk.replaceSubrange(range, with: data)
            if sector == corruptWrittenSector { disk[range.lowerBound] ^= 0x01 }
        }
        func alter(_ sector: Int, bps: Int, offset: Int = 0) { disk[sector * bps + offset] ^= 0x01 }
    }

    struct Geometry {
        let bps: Int
        let reserved: Int
        let copies: Int
        let fatSectors: Int
        let rootEntries: Int
        let clusterSectors: Int
        let total: Int
        var root: Int { reserved + copies * fatSectors }
        var rootSectors: Int { (rootEntries * 32 + bps - 1) / bps }
        var dataStart: Int { root + rootSectors }
        var metadata: Set<Int> { Set(0..<dataStart) }
        func image() -> Data {
            var bytes = [UInt8](repeating: 0, count: total * bps)
            func word(_ p: Int, _ n: Int) { bytes[p] = UInt8(truncatingIfNeeded: n); bytes[p+1] = UInt8(truncatingIfNeeded: n >> 8) }
            word(11, bps); bytes[13] = UInt8(clusterSectors); word(14, reserved)
            bytes[16] = UInt8(copies); word(17, rootEntries); word(19, total)
            bytes[21] = 0xF8; word(22, fatSectors)
            for copy in 0..<copies {
                let start = (reserved + copy * fatSectors) * bps
                bytes[start] = 0xF8; bytes[start+1] = 0xFF; bytes[start+2] = 0xFF
            }
            return Data(bytes)
        }
        static let real512 = Geometry(bps: 512, reserved: 1, copies: 1, fatSectors: 3,
                                      rootEntries: 508, clusterSectors: 1, total: 1021)
        static func small(_ bps: Int, spc: Int = 1, reserved: Int = 1) -> Geometry {
            let clusters = 64, copies = 2, roots = 32
            let fats = (((clusters + 2) * 3 + 1) / 2 + bps - 1) / bps
            let total = reserved + copies * fats + (roots * 32 + bps - 1) / bps + clusters * spc
            return Geometry(bps: bps, reserved: reserved, copies: copies, fatSectors: fats,
                            rootEntries: roots, clusterSectors: spc, total: total)
        }
    }

    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw APFError("TEST FAILED: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do { try body() } catch { return }
        throw APFError("TEST FAILED: expected rejection: \(message)")
    }
    static func attach(_ original: Data, in temp: URL) throws -> (CardSession, MemoryCard) {
        let file = temp.appendingPathComponent(UUID().uuidString + ".img")
        try original.write(to: file)
        let session = CardSession(backupDirectory: temp.appendingPathComponent("backups"))
        try session.openImage(file)
        let card = MemoryCard(original)
        session.connection = card
        session.imageURL = nil
        return (session, card)
    }
    static func adding(_ original: Data, name: String = "NEW.COM", count: Int = 39, directory: String = "/") throws -> Data {
        var volume = try FAT12Volume(data: original)
        try volume.putFile(name: name, contents: Data(repeating: 0x5A, count: count), in: directory)
        return volume.data
    }
    static func changedSectors(_ before: Data, _ after: Data, bps: Int) -> Set<Int> {
        Set(stride(from: 0, to: before.count, by: bps).filter {
            before[$0..<$0+bps] != after[$0..<$0+bps]
        }.map { $0 / bps })
    }

    static func realCardReadBudget(_ temp: URL) throws {
        let g = Geometry.real512, original = g.image()
        let (session, card) = try attach(original, in: temp)
        let first = try adding(original, name: "FIRST.COM")
        try session.commit(first) { _, _ in }
        try check(g.metadata.count == 36, "real-card fixture has 36 metadata sectors")
        try check(card.preflightReads.count == 37, "small upload checks 37 sectors rather than 1021")
        try check(Set(card.preflightReads) == g.metadata.union([g.dataStart]), "preflight covers metadata plus new data")
        try check(card.reads.count == 40 && card.writes.count == 3, "each of the three writes still has read-back verification")
        try check(card.writes == [g.dataStart, g.reserved, g.root], "new data is written before FAT and directory publication")
        try check(card.disk == first && session.image == first, "commit advances disk and cached snapshot together")
        guard let backup = session.lastBackup else { throw APFError("TEST FAILED: backup missing") }
        try check(try Data(contentsOf: backup) == original, "fast upload retains full original snapshot backup")

        card.events = []
        let second = try adding(first, name: "SECOND.COM", count: 7)
        try session.commit(second) { _, _ in }
        try check(card.preflightReads.count == 37 && card.reads.count == 40, "second upload reuses updated snapshot with same bounded read count")
        try check(!card.reads.contains(g.dataStart) && !card.writes.contains(g.dataStart), "unrelated existing file data is neither reread nor rewritten")
        let onCard = try FAT12Volume(data: card.disk)
        try check(try onCard.readFile(path: "/FIRST.COM") == Data(repeating: 0x5A, count: 39), "first file survives second upload")
        try check(try onCard.readFile(path: "/SECOND.COM") == Data(repeating: 0x5A, count: 7), "second file round-trips")
        guard let secondBackup = session.lastBackup else { throw APFError("TEST FAILED: second backup missing") }
        try check(try Data(contentsOf: secondBackup) == first, "second backup uses latest committed snapshot")
    }

    static func refusesStaleCard(_ original: Data, updated: Data, geometry g: Geometry, sector: Int,
                                 label: String, temp: URL) throws {
        let (session, card) = try attach(original, in: temp)
        card.alter(sector, bps: g.bps, offset: g.bps - 1)
        try rejects(label) { try session.commit(updated) { _, _ in } }
        try check(card.writes.isEmpty && !session.hardwareWriteStarted, "\(label): no write starts")
        try check(session.needsReconnect && session.image == original, "\(label): snapshot retained and reconnect required")
        let eventCount = card.events.count
        try rejects("\(label): retry") { try session.commit(updated) { _, _ in } }
        try check(card.events.count == eventCount, "\(label): retry cannot access card before refresh")
    }

    static func metadataAndGeometry(_ temp: URL) throws {
        for bps in [128, 256, 512] {
            let g = Geometry.small(bps, spc: 2, reserved: 2), original = g.image()
            let updated = try adding(original, count: bps + 7)
            let changed = changedSectors(original, updated, bps: bps)
            let (session, card) = try attach(original, in: temp)
            try session.commit(updated) { _, _ in }
            try check(Set(card.preflightReads) == g.metadata.union(changed), "\(bps)-byte sectors: complete metadata and affected-data check")
            try check(card.preflightReads.count < g.total / 2, "\(bps)-byte sectors: no full-card reread")
            try check(card.disk == updated && session.image == updated, "\(bps)-byte sectors: multi-FAT/multi-sector-cluster upload")
            try check(card.reads.count == card.preflightReads.count + card.writes.count, "\(bps)-byte sectors: every write verified exactly once")

            for (sector, label) in [(0, "boot"), (1, "extra reserved sector"),
                                     (g.reserved, "primary FAT"), (g.reserved + g.fatSectors, "secondary FAT"),
                                     (g.root + g.rootSectors - 1, "root directory tail"),
                                     (g.dataStart + 1, "affected file data")] {
                try refusesStaleCard(original, updated: updated, geometry: g, sector: sector,
                                     label: "\(bps)-byte sectors: \(label)", temp: temp)
            }

            var directoryVolume = try FAT12Volume(data: original)
            try directoryVolume.createDirectory(name: "TOOLS")
            // Fill one cluster's usable directory slots, forcing a second
            // cluster even though every test file itself is zero-length.
            let firstClusterFiles = bps * g.clusterSectors / 32 - 2
            for index in 0...firstClusterFiles {
                try directoryVolume.putFile(name: "F\(index).TXT", contents: Data(), in: "/TOOLS")
            }
            let withDirectory = directoryVolume.data
            let staged = try adding(withDirectory, name: "ROOT.COM")
            let tail = g.dataStart + g.clusterSectors - 1
            try refusesStaleCard(withDirectory, updated: staged, geometry: g, sector: tail,
                                 label: "\(bps)-byte sectors: existing directory cluster tail", temp: temp)
            let secondClusterTail = g.dataStart + g.clusterSectors * 2 - 1
            try refusesStaleCard(withDirectory, updated: staged, geometry: g, sector: secondClusterTail,
                                 label: "\(bps)-byte sectors: chained directory tail", temp: temp)
        }
    }

    static func failuresRequireRefresh(_ temp: URL) throws {
        let g = Geometry.real512, original = g.image(), updated = try adding(original)
        let (readSession, readCard) = try attach(original, in: temp)
        readCard.failReadSector = g.root
        try rejects("USB preflight read failure") { try readSession.commit(updated) { _, _ in } }
        try check(readCard.writes.isEmpty && !readSession.hardwareWriteStarted, "USB read error prevents all writes")
        try check(readSession.needsReconnect && readSession.image == original, "USB read error invalidates session without changing cached bytes")
        let count = readCard.events.count
        readCard.failReadSector = nil
        try rejects("USB read failure must be refreshed") { try readSession.commit(updated) { _, _ in } }
        try check(readCard.events.count == count, "USB failure cannot silently resume from stale state")

        let (writeSession, writeCard) = try attach(original, in: temp)
        writeCard.corruptWrittenSector = g.dataStart
        try rejects("read-back mismatch") { try writeSession.commit(updated) { _, _ in } }
        try check(writeSession.needsReconnect && writeSession.hardwareWriteStarted, "read-back mismatch requires reconnect")
        try check(writeSession.image == original && writeCard.writes == [g.dataStart], "failed data verification never publishes FAT or directory")
        let writeCount = writeCard.events.count
        try rejects("read-back mismatch retry") { try writeSession.commit(updated) { _, _ in } }
        try check(writeCard.events.count == writeCount, "failed verification blocks later writes")
    }

    static func main() throws {
        let temp = URL(fileURLWithPath: "/tmp").appendingPathComponent("apf-fast-upload-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try realCardReadBudget(temp)
        try metadataAndGeometry(temp)
        try failuresRequireRefresh(temp)
        print("Fast uploads: \(checks) mock-hardware checks passed; small 512 KB-card uploads use 37 preflight reads instead of 1021 (no USB access).")
    }
}
