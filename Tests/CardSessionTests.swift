import Foundation

// Offline integration tests only. No APFConnection is constructed and no USB
// device is opened. Every image and backup lives in a newly-created temp folder.
@main enum CardSessionTests {
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
    static func blankImage(bps: Int) -> Data {
        let clusters = 32, roots = 16
        let fatSize = (((clusters + 2) * 3 + 1) / 2 + bps - 1) / bps
        let sectors = 1 + fatSize * 2 + (roots * 32 + bps - 1) / bps + clusters
        var b = [UInt8](repeating: 0, count: sectors * bps)
        func word(_ p: Int, _ value: Int) { b[p] = UInt8(truncatingIfNeeded: value); b[p + 1] = UInt8(truncatingIfNeeded: value >> 8) }
        word(11, bps); b[13] = 1; word(14, 1); b[16] = 2; word(17, roots); word(19, sectors)
        b[21] = 0xF8; word(22, fatSize)
        for start in [bps, (1 + fatSize) * bps] { b[start] = 0xF8; b[start + 1] = 0xFF; b[start + 2] = 0xFF }
        return Data(b)
    }
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("apf-session-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let backups = temp.appendingPathComponent("backups", isDirectory: true)
        for bps in [128, 256, 512] {
            let original = blankImage(bps: bps), file = temp.appendingPathComponent("\(bps).img")
            try original.write(to: file)
            let session = CardSession(backupDirectory: backups)
            try session.openImage(file)
            try check(!session.isHardware && session.bytesPerSector == bps, "offline image geometry")
            try session.commit(original) { _, _ in }
            try check(session.lastBackup == nil, "unchanged commit does not create backup")
            var volume = try FAT12Volume(data: session.image)
            try volume.createDirectory(name: "TOOLS")
            try volume.putFile(name: "TEST.COM", contents: Data(repeating: 0xC3, count: bps * 3 + 7), in: "/TOOLS")
            try session.commit(volume.data) { _, _ in }
            try check(try Data(contentsOf: file) == volume.data && session.image == volume.data, "offline commit persists entire image")
            guard let backup = session.lastBackup else { throw APFError("TEST FAILED: no pre-change backup") }
            try check(try Data(contentsOf: backup) == original, "backup contains original bytes")
            let reloaded = CardSession(backupDirectory: backups)
            try reloaded.openImage(file)
            try check(try FAT12Volume(data: reloaded.image).readFile(path: "/TOOLS/TEST.COM") == Data(repeating: 0xC3, count: bps * 3 + 7), "reopen committed image")
            let before = session.image
            var bootChanged = before; bootChanged[3] ^= 1
            try rejects("boot sector change") { try session.commit(bootChanged) { _, _ in } }
            var invalid = before; invalid[bps + 4] ^= 1
            try rejects("corrupt updated FAT") { try session.commit(invalid) { _, _ in } }
            try check(try Data(contentsOf: file) == before && session.image == before, "invalid commit preserves file and snapshot")
            try rejects("wrong image length") { try session.commit(Data(before.dropLast())) { _, _ in } }
            session.needsReconnect = true
            var changed = try FAT12Volume(data: before)
            try changed.putFile(name: "NEW", contents: Data([1]))
            try rejects("requires reconnect") { try session.commit(changed.data) { _, _ in } }
            try check(try Data(contentsOf: file) == before, "reconnect guard prevents writes")
        }

        let extra = temp.appendingPathComponent("trailing.img")
        var withTail = blankImage(bps: 128); withTail.append(contentsOf: [0xAB, 0xCD, 0xEF])
        try withTail.write(to: extra)
        let trailing = CardSession(backupDirectory: backups); try trailing.openImage(extra)
        var volume = try FAT12Volume(data: trailing.image)
        try volume.putFile(name: "TAIL.TXT", contents: Data("unchanged tail".utf8))
        try trailing.commit(volume.data) { _, _ in }
        try check(try Data(contentsOf: extra).suffix(3) == Data([0xAB, 0xCD, 0xEF]), "unaligned trailing bytes preserved without crash")
        let before = trailing.image
        var changedTail = before; changedTail[changedTail.count - 1] ^= 1
        try rejects("tail mutation") { try trailing.commit(changedTail) { _, _ in } }
        try check(try Data(contentsOf: extra) == before, "tail mutation leaves file intact")

        let failBackupPath = temp.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: failBackupPath)
        let failImage = temp.appendingPathComponent("backup-failure.img"), original = blankImage(bps: 128)
        try original.write(to: failImage)
        let failedBackup = CardSession(backupDirectory: failBackupPath); try failedBackup.openImage(failImage)
        var changed = try FAT12Volume(data: original); try changed.putFile(name: "NEW", contents: Data([1]))
        try rejects("backup directory failure") { try failedBackup.commit(changed.data) { _, _ in } }
        try check(try Data(contentsOf: failImage) == original && failedBackup.image == original, "backup failure prevents image mutation")

        let staleFile = temp.appendingPathComponent("stale.img"); try original.write(to: staleFile)
        let stale = CardSession(backupDirectory: backups); try stale.openImage(staleFile)
        var externallyChanged = try FAT12Volume(data: original)
        try externallyChanged.putFile(name: "EXTERNAL", contents: Data([2]))
        try externallyChanged.data.write(to: staleFile)
        try rejects("external disk edit") { try stale.commit(changed.data) { _, _ in } }
        try check(try Data(contentsOf: staleFile) == externallyChanged.data, "external edits preserved")
        print("CardSession: \(checks) offline integration checks passed (no USB access).")
    }
}
