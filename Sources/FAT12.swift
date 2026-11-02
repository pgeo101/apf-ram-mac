import Foundation

struct FAT12Error: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

struct FATEntry: Identifiable {
    let name: String
    let isDirectory: Bool
    let size: Int
    let attributes: UInt8
    let modifiedDate: Date?
    var id: String { name }
}

/// A complete, unpartitioned FAT12 image. Mutations are transactional and never perform I/O.
struct FAT12Volume {
    private var storage: [UInt8]
    let bytesPerSector: Int
    let totalSectors: Int
    let sectorsPerCluster: Int
    let clusterCount: Int
    private let reservedSectors: Int
    private let fatCount: Int
    private let sectorsPerFAT: Int
    private let rootEntryCount: Int
    private let rootStart: Int
    private let dataStart: Int

    var data: Data { Data(storage) }
    var clusterSize: Int { bytesPerSector * sectorsPerCluster }
    var totalBytes: Int { totalSectors * bytesPerSector }
    var freeBytes: Int {
        get throws { try (2..<(clusterCount + 2)).reduce(0) { $0 + (try fat($1) == 0 ? clusterSize : 0) } }
    }

    init(data: Data) throws {
        let b = Array(data)
        guard b.count >= 36 else { throw FAT12Error("The image is too small to contain a FAT12 header.") }
        func u16(_ p: Int) -> Int { Int(b[p]) | (Int(b[p + 1]) << 8) }
        func u32(_ p: Int) -> Int { u16(p) | (u16(p + 2) << 16) }
        let bps = u16(11), spc = Int(b[13]), reserved = u16(14), copies = Int(b[16])
        let roots = u16(17), sectors = u16(19) == 0 ? u32(32) : u16(19), fatSectors = u16(22)
        guard [128, 256, 512, 1024, 2048, 4096].contains(bps), spc > 0, spc <= 128,
              spc & (spc - 1) == 0, reserved > 0, (1...4).contains(copies), roots > 0,
              sectors > 0, fatSectors > 0 else {
            throw FAT12Error("The card header does not describe a supported FAT12 volume. Format the card in the Portfolio first.")
        }
        let rootSectors = (roots * 32 + bps - 1) / bps
        let firstRoot = reserved + copies * fatSectors
        let firstData = firstRoot + rootSectors
        guard sectors > firstData, sectors <= b.count / bps else { throw FAT12Error("The card image is truncated or its header is invalid.") }
        let clusters = (sectors - firstData) / spc
        guard clusters > 0, clusters < 4085, ((clusters + 2) * 3 + 1) / 2 <= fatSectors * bps else {
            throw FAT12Error("Only valid FAT12 card images are supported.")
        }
        storage = b
        bytesPerSector = bps; totalSectors = sectors; sectorsPerCluster = spc; clusterCount = clusters
        reservedSectors = reserved; fatCount = copies; sectorsPerFAT = fatSectors; rootEntryCount = roots
        rootStart = firstRoot * bps; dataStart = firstData * bps
        // Older Portfolio cards need not have the later 0x55AA boot signature.
        guard try fat(0) == (0xF00 | Int(b[21])), try fat(1) >= 0xFF8 else {
            throw FAT12Error("The FAT12 reserved entries are invalid.")
        }
    }

    func entries(in path: String = "/") throws -> [FATEntry] {
        try records(directory: directory(path)).map { record in
            FATEntry(name: record.name, isDirectory: record.isDirectory, size: record.size,
                     attributes: storage[record.offset + 11], modifiedDate: decodeDate(record.offset))
        }
    }

    func readFile(path: String) throws -> Data {
        let parts = components(path)
        guard let name = parts.last else { throw FAT12Error("Choose a file to download.") }
        let dir = try directory("/" + parts.dropLast().joined(separator: "/"))
        guard let record = try records(directory: dir).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              !record.isDirectory else { throw FAT12Error("File not found: \(path)") }
        if record.size == 0 { return Data() }
        let clusters = try chain(record.cluster)
        guard clusters.count * clusterSize >= record.size else { throw FAT12Error("The file is longer than its FAT chain: \(record.name)") }
        var result = Data(); result.reserveCapacity(record.size)
        for c in clusters {
            let start = try clusterOffset(c), count = min(clusterSize, record.size - result.count)
            if count <= 0 { break }
            result.append(contentsOf: storage[start..<(start + count)])
        }
        return result
    }

    /// Sector categories used for upload prechecks and write ordering:
    /// 1 = reserved/boot and FAT sectors, 2 = root and existing subdirectories.
    /// File contents are deliberately excluded. Complete directory chains are
    /// included even when their entry list ends before the final cluster.
    func metadataSectors() throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for sector in 0..<(rootStart / bytesPerSector) { result[sector] = 1 }
        for sector in (rootStart / bytesPerSector)..<(dataStart / bytesPerSector) { result[sector] = 2 }

        var visited = Set<Int>()
        func visit(_ directory: Int?, depth: Int) throws {
            guard depth <= 128 else { throw FAT12Error("The directory tree is too deep or contains a cycle.") }
            if let directory {
                for cluster in try chain(directory) {
                    guard visited.insert(cluster).inserted else {
                        throw FAT12Error("Directories have overlapping FAT chains or contain a cycle.")
                    }
                    let start = try clusterOffset(cluster) / bytesPerSector
                    for sector in start..<(start + sectorsPerCluster) { result[sector] = 2 }
                }
            }
            for record in try records(directory: directory) where record.isDirectory {
                try visit(record.cluster, depth: depth + 1)
            }
        }
        try visit(nil, depth: 0)
        return result
    }

    mutating func putFile(name: String, contents: Data, in directory: String = "/", overwrite: Bool = false) throws {
        let encoded = try Self.encodeName(name)
        guard contents.count <= Int(UInt32.max) else { throw FAT12Error("The file is too large.") }
        var next = self
        try next.validateForMutation()
        let dir = try next.directory(directory)
        let existing = try next.records(directory: dir).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let existing {
            guard overwrite, !existing.isDirectory else { throw FAT12Error("An entry named \(name) already exists.") }
            guard next.storage[existing.offset + 11] & 1 == 0 else { throw FAT12Error("The existing file is read-only: \(name)") }
            if existing.cluster != 0 { for c in try next.chain(existing.cluster) { try next.setFAT(c, 0) } }
        }
        let slot = try existing?.offset ?? next.availableSlot(in: dir)
        let required = (contents.count + clusterSize - 1) / clusterSize
        let clusters = try next.allocate(required)
        let source = Array(contents)
        for (i, cluster) in clusters.enumerated() {
            let offset = try next.clusterOffset(cluster), count = min(clusterSize, source.count - i * clusterSize)
            next.storage.replaceSubrange(offset..<(offset + count), with: source[(i * clusterSize)..<(i * clusterSize + count)])
        }
        next.writeEntry(at: slot, name: encoded, attributes: 0x20, cluster: clusters.first ?? 0, size: contents.count)
        try next.validateForMutation()
        self = next
    }

    mutating func createDirectory(name: String, in directory: String = "/") throws {
        let encoded = try Self.encodeName(name)
        var next = self
        try next.validateForMutation()
        let parent = try next.directory(directory)
        guard try !next.records(directory: parent).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FAT12Error("An entry named \(name) already exists.")
        }
        let slot = try next.availableSlot(in: parent)
        let cluster = try next.allocate(1)[0], offset = try next.clusterOffset(cluster)
        next.writeEntry(at: offset, name: Array(".          ".utf8), attributes: 0x10, cluster: cluster, size: 0)
        next.writeEntry(at: offset + 32, name: Array("..         ".utf8), attributes: 0x10, cluster: parent ?? 0, size: 0)
        next.writeEntry(at: slot, name: encoded, attributes: 0x10, cluster: cluster, size: 0)
        try next.validateForMutation()
        self = next
    }

    /// Check the complete directory tree and all FAT copies before permitting a write.
    /// Refuse orphan allocations, cross-links, loops, truncated chains, and long filename records.
    func validateForMutation() throws {
        let fatBytes = sectorsPerFAT * bytesPerSector, first = reservedSectors * bytesPerSector
        if fatCount > 1 {
            for copy in 1..<fatCount {
                let start = first + copy * fatBytes
                guard storage[first..<(first + fatBytes)].elementsEqual(storage[start..<(start + fatBytes)]) else {
                    throw FAT12Error("The card's FAT copies disagree. Writing is disabled until the filesystem is repaired.")
                }
            }
        }
        var owned = Set<Int>()
        func claim(_ clusters: [Int]) throws {
            for c in clusters {
                guard owned.insert(c).inserted else { throw FAT12Error("The card has cross-linked files or directories. Writing is disabled.") }
            }
        }
        func visit(_ directory: Int?, depth: Int) throws {
            guard depth <= 128 else { throw FAT12Error("The directory tree is too deep or contains a cycle.") }
            if let directory { try claim(chain(directory)) }
            let slots = try directorySlots(directory)
            for offset in slots {
                if storage[offset] == 0 { break }
                if storage[offset] == 0xE5 { continue }
                if storage[offset + 11] == 0x0F { throw FAT12Error("The card contains long filename records. This utility writes only Portfolio 8.3 volumes.") }
            }
            let records = try records(directory: directory)
            var names = Set<String>()
            for record in records {
                guard names.insert(record.name.uppercased()).inserted else { throw FAT12Error("The card contains duplicate directory entries.") }
                guard u16(record.offset + 20) == 0 else { throw FAT12Error("A directory entry contains an unsupported high cluster number.") }
                if record.isDirectory {
                    guard record.cluster >= 2 else { throw FAT12Error("A directory has no valid cluster.") }
                    try visit(record.cluster, depth: depth + 1)
                } else if record.cluster != 0 {
                    let clusters = try chain(record.cluster)
                    guard clusters.count * clusterSize >= record.size else { throw FAT12Error("A file is longer than its FAT chain: \(record.name)") }
                    try claim(clusters)
                } else if record.size != 0 {
                    throw FAT12Error("A nonempty file has no FAT chain: \(record.name)")
                }
            }
        }
        try visit(nil, depth: 0)
        for c in 2..<(clusterCount + 2) {
            let value = try fat(c)
            if value != 0 && value != 0xFF7 && !owned.contains(c) {
                throw FAT12Error("The card has unreferenced or reserved allocations. Writing is disabled until the filesystem is repaired.")
            }
        }
    }

    private struct Record {
        let offset: Int
        let name: String
        let cluster: Int
        let size: Int
        let isDirectory: Bool
    }
    private func u16(_ p: Int) -> Int { Int(storage[p]) | Int(storage[p + 1]) << 8 }
    private func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
    private mutating func write16(_ p: Int, _ value: Int) {
        storage[p] = UInt8(truncatingIfNeeded: value); storage[p + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    private func fat(_ cluster: Int) throws -> Int {
        guard cluster >= 0, cluster < clusterCount + 2 else { throw FAT12Error("A cluster number is outside the card.") }
        let offset = reservedSectors * bytesPerSector + cluster + cluster / 2
        let pair = u16(offset)
        return cluster & 1 == 0 ? pair & 0xFFF : pair >> 4
    }
    private mutating func setFAT(_ cluster: Int, _ value: Int) throws {
        guard cluster >= 2, cluster < clusterCount + 2, (0...0xFFF).contains(value) else { throw FAT12Error("Invalid FAT update.") }
        for copy in 0..<fatCount {
            let offset = (reservedSectors + copy * sectorsPerFAT) * bytesPerSector + cluster + cluster / 2
            let pair = u16(offset)
            write16(offset, cluster & 1 == 0 ? ((pair & 0xF000) | value) : ((pair & 0x000F) | value << 4))
        }
    }
    private func clusterOffset(_ cluster: Int) throws -> Int {
        guard cluster >= 2, cluster < clusterCount + 2 else { throw FAT12Error("A cluster number is outside the card.") }
        return dataStart + (cluster - 2) * clusterSize
    }
    private func chain(_ first: Int) throws -> [Int] {
        guard first >= 2 else { throw FAT12Error("A file or directory has an invalid first cluster.") }
        var result: [Int] = [], seen = Set<Int>(), current = first
        while true {
            guard current >= 2, current < clusterCount + 2, seen.insert(current).inserted else {
                throw FAT12Error("The FAT chain is invalid or contains a loop.")
            }
            result.append(current)
            let next = try fat(current)
            if next >= 0xFF8 { return result }
            guard next >= 2, next < 0xFF0 else { throw FAT12Error("The FAT chain ends in a free, reserved, or bad cluster.") }
            current = next
        }
    }
    private func directorySlots(_ cluster: Int?) throws -> [Int] {
        guard let cluster else { return (0..<rootEntryCount).map { rootStart + $0 * 32 } }
        return try chain(cluster).flatMap { c in
            let start = try clusterOffset(c)
            return stride(from: start, to: start + clusterSize, by: 32).map { $0 }
        }
    }
    private func records(directory: Int?) throws -> [Record] {
        var result: [Record] = []
        for offset in try directorySlots(directory) {
            let first = storage[offset], attr = storage[offset + 11]
            if first == 0 { break }
            if first == 0xE5 || attr == 0x0F || attr & 0x08 != 0 { continue }
            let name = decodeName(offset)
            if name == "." || name == ".." { continue }
            result.append(Record(offset: offset, name: name, cluster: u16(offset + 26), size: u32(offset + 28), isDirectory: attr & 0x10 != 0))
        }
        return result
    }
    private func components(_ path: String) -> [String] {
        var path = path.replacingOccurrences(of: "\\", with: "/")
        if path.uppercased().hasPrefix("A:") { path = String(path.dropFirst(2)) }
        var result: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." { if !result.isEmpty { result.removeLast() }; continue }
            result.append(component)
        }
        return result
    }
    private func directory(_ path: String) throws -> Int? {
        var current: Int?
        for component in components(path) {
            guard let record = try records(directory: current).first(where: { $0.name.caseInsensitiveCompare(component) == .orderedSame }), record.isDirectory else {
                throw FAT12Error("Directory not found: \(path)")
            }
            current = record.cluster
        }
        return current
    }
    private static func encodeName(_ name: String) throws -> [UInt8] {
        let bytes = Array(name.utf8), allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~".utf8)
        let upper = bytes.map { (97...122).contains($0) ? $0 - 32 : $0 }
        let parts = upper.split(separator: 46, omittingEmptySubsequences: false)
        guard !name.isEmpty, parts.count <= 2, !parts[0].isEmpty, parts[0].count <= 8,
              (parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 3)),
              parts.allSatisfy({ $0.allSatisfy { allowed.contains($0) } }) else {
            throw FAT12Error("Use a DOS 8.3 name: up to 8 ASCII letters or numbers, then an optional extension of up to 3 characters (for example GAME.COM).")
        }
        // DOS device names cannot be used as ordinary files on the Portfolio.
        let base = String(bytes: parts[0], encoding: .ascii)!
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !reserved.contains(base) else { throw FAT12Error("\(base) is a reserved DOS device name.") }
        return Array(parts[0]) + Array(repeating: 32, count: 8 - parts[0].count)
            + (parts.count == 2 ? Array(parts[1]) : []) + Array(repeating: 32, count: 3 - (parts.count == 2 ? parts[1].count : 0))
    }
    private func decodeName(_ offset: Int) -> String {
        func text(_ bytes: ArraySlice<UInt8>) -> String {
            let trimmed = bytes.reversed().drop(while: { $0 == 32 }).reversed()
            return String(String.UnicodeScalarView(trimmed.map { UnicodeScalar(UInt32($0))! }))
        }
        let base = text(storage[offset..<(offset + 8)]), ext = text(storage[(offset + 8)..<(offset + 11)])
        return base + (ext.isEmpty ? "" : "." + ext)
    }
    private mutating func allocate(_ count: Int) throws -> [Int] {
        guard count >= 0 else { throw FAT12Error("Invalid allocation size.") }
        if count == 0 { return [] }
        var free: [Int] = []
        for c in 2..<(clusterCount + 2) {
            if try fat(c) == 0 { free.append(c); if free.count == count { break } }
        }
        guard free.count == count else { throw FAT12Error("The card does not have enough free space.") }
        for (i, c) in free.enumerated() {
            try setFAT(c, i + 1 == free.count ? 0xFFF : free[i + 1])
            let offset = try clusterOffset(c)
            storage.replaceSubrange(offset..<(offset + clusterSize), with: repeatElement(UInt8(0), count: clusterSize))
        }
        return free
    }
    private mutating func availableSlot(in directory: Int?) throws -> Int {
        let slots = try directorySlots(directory)
        for (i, offset) in slots.enumerated() {
            if storage[offset] == 0xE5 { return offset }
            if storage[offset] == 0 {
                // Preserve the end marker even when old garbage follows it.
                if i + 1 < slots.count { storage[slots[i + 1]] = 0 }
                return offset
            }
        }
        guard let directory else { throw FAT12Error("The card's root directory is full.") }
        let last = try chain(directory).last!, added = try allocate(1)[0]
        try setFAT(last, added)
        return try clusterOffset(added)
    }
    private mutating func writeEntry(at offset: Int, name: [UInt8], attributes: UInt8, cluster: Int, size: Int) {
        storage.replaceSubrange(offset..<(offset + 32), with: repeatElement(UInt8(0), count: 32))
        storage.replaceSubrange(offset..<(offset + 11), with: name)
        storage[offset + 11] = attributes
        let now = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
        let year = min(2107, max(1980, now.year ?? 1980)), month = now.month ?? 1, day = now.day ?? 1
        let date = (year - 1980) << 9 | month << 5 | day
        let time = (now.hour ?? 0) << 11 | (now.minute ?? 0) << 5 | (now.second ?? 0) / 2
        write16(offset + 14, time); write16(offset + 16, date); write16(offset + 18, date)
        write16(offset + 22, time); write16(offset + 24, date); write16(offset + 26, cluster)
        write16(offset + 28, size & 0xFFFF); write16(offset + 30, size >> 16)
    }
    private func decodeDate(_ offset: Int) -> Date? {
        let date = u16(offset + 24), time = u16(offset + 22)
        guard date != 0 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: 1980 + (date >> 9), month: (date >> 5) & 15,
            day: date & 31, hour: time >> 11, minute: (time >> 5) & 63, second: (time & 31) * 2))
    }
}
