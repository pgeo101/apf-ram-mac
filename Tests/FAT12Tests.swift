import Foundation

@main
enum FAT12Tests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw FAT12Error("TEST FAILED: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do { try body() } catch { return }
        throw FAT12Error("TEST FAILED: expected rejection: \(message)")
    }
    static func write16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value); bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    static func image(bps: Int = 128, spc: Int = 1, clusters: Int = 64, roots: Int = 16) -> Data {
        let fatSectors = (((clusters + 2) * 3 + 1) / 2 + bps - 1) / bps
        let total = 1 + 2 * fatSectors + (roots * 32 + bps - 1) / bps + clusters * spc
        var b = [UInt8](repeating: 0, count: total * bps)
        b[0] = 0xEB; b[1] = 0x3C; b[2] = 0x90
        write16(&b, 11, bps); b[13] = UInt8(spc); write16(&b, 14, 1); b[16] = 2
        write16(&b, 17, roots); write16(&b, 19, total); b[21] = 0xF8; write16(&b, 22, fatSectors)
        for offset in [bps, bps * (1 + fatSectors)] { b[offset] = 0xF8; b[offset + 1] = 0xFF; b[offset + 2] = 0xFF }
        return Data(b)
    }
    static func fatValue(_ bytes: [UInt8], bps: Int, cluster: Int) -> Int {
        let p = bps + cluster + cluster / 2, pair = Int(bytes[p]) | Int(bytes[p + 1]) << 8
        return cluster & 1 == 0 ? pair & 0xFFF : pair >> 4
    }
    static func setFAT(_ bytes: inout [UInt8], bps: Int, cluster: Int, value: Int) {
        let fs = Int(bytes[22]) | Int(bytes[23]) << 8
        for start in [bps, bps * (1 + fs)] {
            let p = start + cluster + cluster / 2, pair = Int(bytes[p]) | Int(bytes[p + 1]) << 8
            let replacement = cluster & 1 == 0 ? (pair & 0xF000) | value : (pair & 0x000F) | value << 4
            write16(&bytes, p, replacement)
        }
    }
    static func rootOffset(_ bytes: [UInt8]) -> Int {
        let bps = Int(bytes[11]) | Int(bytes[12]) << 8, fs = Int(bytes[22]) | Int(bytes[23]) << 8
        return bps * (1 + 2 * fs)
    }
    static func main() throws {
        for bps in [128, 256, 512] {
            for spc in [1, 4] {
                var volume = try FAT12Volume(data: image(bps: bps, spc: spc))
                try check(volume.bytesPerSector == bps && volume.clusterSize == bps * spc, "BPB geometry")
                try check(try volume.freeBytes == 64 * bps * spc, "initial free space")
                let payload = Data((0..<(bps * spc * 3 + 17)).map { UInt8(truncatingIfNeeded: $0 * 37) })
                try volume.putFile(name: "game.com", contents: payload)
                try volume.putFile(name: "OTHER.BIN", contents: Data([1, 2, 3]))
                try check(try volume.entries().map(\.name) == ["GAME.COM", "OTHER.BIN"], "8.3 uppercasing/listing")
                try check(try volume.readFile(path: "A:\\game.com") == payload, "multicluster content")
                try check(try volume.readFile(path: "/OTHER.BIN") == Data([1, 2, 3]), "neighbor FAT nibble preserved")
                let bytes = Array(volume.data)
                try check(fatValue(bytes, bps: bps, cluster: 2) == 3 && fatValue(bytes, bps: bps, cluster: 3) == 4,
                          "even and odd FAT12 entries")
                try volume.createDirectory(name: "TOOLS")
                try volume.createDirectory(name: "SUB", in: "/TOOLS")
                try volume.putFile(name: "HELLO.TXT", contents: Data("Hello Portfolio".utf8), in: "A:\\TOOLS\\SUB")
                try check(try volume.readFile(path: "/TOOLS/SUB/../SUB/HELLO.TXT") == Data("Hello Portfolio".utf8), "nested path")
                try check(try volume.entries(in: "/TOOLS").first?.isDirectory == true, "directory entry")
                try volume.putFile(name: "EMPTY.DAT", contents: Data(), in: "/TOOLS")
                try check(try volume.readFile(path: "/TOOLS/EMPTY.DAT").isEmpty, "zero-length file")
                let before = volume.data
                try rejects("existing file without overwrite") { try volume.putFile(name: "GAME.COM", contents: Data([4])) }
                try check(volume.data == before, "failed overwrite is transactional")
                try rejects("disk full") { try volume.putFile(name: "BIG.BIN", contents: Data(repeating: 9, count: 100 * bps * spc)) }
                try check(volume.data == before, "failed allocation is transactional")
                try volume.putFile(name: "GAME.COM", contents: Data([0xC3]), overwrite: true)
                try check(try volume.readFile(path: "/GAME.COM") == Data([0xC3]), "explicit overwrite")
                try check(try volume.readFile(path: "/OTHER.BIN") == Data([1, 2, 3]), "overwrite preserves other files")
                try volume.validateForMutation()
                let rebuilt = try FAT12Volume(data: volume.data)
                try check(try rebuilt.readFile(path: "/TOOLS/SUB/HELLO.TXT") == Data("Hello Portfolio".utf8), "saved image reload")
            }
        }
        var volume = try FAT12Volume(data: image())
        for name in ["", ".", "..", "NINECHARS.TXT", "A.LONG", "A..B", "A.", "A B.TXT", "A/B.TXT", "é.TXT", "CON.TXT", "COM1"] {
            let before = volume.data
            try rejects("invalid 8.3 name \(name)") { try volume.putFile(name: name, contents: Data([1])) }
            try check(volume.data == before, "invalid name leaves image unchanged")
        }
        try volume.createDirectory(name: "DIR")
        for i in 0..<12 { try volume.putFile(name: "F\(i).TXT", contents: Data([UInt8(i)]), in: "/DIR") }
        try check(try volume.entries(in: "/DIR").count == 12, "subdirectory extends across clusters")
        for i in 0..<12 { try check(try volume.readFile(path: "/DIR/F\(i).TXT") == Data([UInt8(i)]), "extended directory content") }

        var rootFull = try FAT12Volume(data: image())
        for i in 0..<16 { try rootFull.putFile(name: "F\(i)", contents: Data()) }
        let fullBefore = rootFull.data
        try rejects("root full") { try rootFull.putFile(name: "EXTRA", contents: Data()) }
        try check(rootFull.data == fullBefore, "full root rollback")

        var small = try FAT12Volume(data: image(clusters: 3))
        try small.putFile(name: "FILL", contents: Data(repeating: 7, count: 3 * 128))
        try check(try small.freeBytes == 0, "exact disk capacity")
        try small.putFile(name: "EMPTY", contents: Data())
        let smallBefore = small.data
        try rejects("overwrite bigger than capacity") { try small.putFile(name: "FILL", contents: Data(repeating: 8, count: 4 * 128), overwrite: true) }
        try check(small.data == smallBefore && (try small.readFile(path: "/FILL")) == Data(repeating: 7, count: 3 * 128), "overwrite allocation rollback")

        var corrupt = Array(small.data)
        setFAT(&corrupt, bps: 128, cluster: 3, value: 2)
        let looped = try FAT12Volume(data: Data(corrupt))
        try rejects("FAT cycle reading") { _ = try looped.readFile(path: "/FILL") }
        try rejects("FAT cycle mutation") { try looped.validateForMutation() }

        corrupt = Array(image()); corrupt[128 + 4] ^= 1
        let mismatched = try FAT12Volume(data: Data(corrupt))
        try rejects("mismatched FAT copies") { try mismatched.validateForMutation() }
        corrupt = Array(image()); setFAT(&corrupt, bps: 128, cluster: 2, value: 0xFFF)
        let orphan = try FAT12Volume(data: Data(corrupt))
        try rejects("orphan allocation") { try orphan.validateForMutation() }

        var linked = try FAT12Volume(data: image())
        try linked.putFile(name: "A", contents: Data([1])); try linked.putFile(name: "B", contents: Data([2]))
        corrupt = Array(linked.data)
        let root = rootOffset(corrupt), first = Int(corrupt[root + 26]) | Int(corrupt[root + 27]) << 8
        write16(&corrupt, root + 32 + 26, first)
        let crosslinked = try FAT12Volume(data: Data(corrupt))
        try rejects("cross-linked files") { try crosslinked.validateForMutation() }

        corrupt = Array(linked.data); corrupt[root + 11] |= 1
        var readOnly = try FAT12Volume(data: Data(corrupt))
        try rejects("read-only overwrite") { try readOnly.putFile(name: "A", contents: Data(), overwrite: true) }
        try rejects("truncated image") { _ = try FAT12Volume(data: image().dropLast(100)) }

        var trailing = image(); trailing.append(contentsOf: [0xA1, 0xB2, 0xC3])
        var preserved = try FAT12Volume(data: trailing)
        try preserved.putFile(name: "OK", contents: Data([1]))
        try check(preserved.data.suffix(3) == Data([0xA1, 0xB2, 0xC3]), "unrelated trailing bytes preserved")
        print("FAT12: \(checks) checks passed (128/256/512-byte sectors; root, nested, and extended directories; transactional writes; corruption rejection).")
    }
}
