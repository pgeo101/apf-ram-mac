import Foundation

struct APFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

protocol APFCardTransport: AnyObject {
    func readSector(_ sector: Int, bytesPerSector: Int) throws -> Data
    func writeSector(_ sector: Int, bytesPerSector: Int, data: Data) throws
}

final class APFConnection: APFCardTransport {
    private let handle: OpaquePointer
    let identity: [UInt8]
    let label: String
    let capacityLimit: Int
    init() throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let device = apf_open(&error, error.count) else { throw APFError(String(cString: error)) }
        var raw = [UInt8](repeating: 0, count: 63)
        guard apf_identity(device, &raw, raw.count, &error, error.count) != 0 else {
            apf_close(device); throw APFError(String(cString: error))
        }
        let sizes: [UInt8: (String, Int)] = [0x10: ("512 KB", 524288), 0x20: ("1 MB", 1048576),
                                            0x30: ("1.5 MB", 1572864), 0x40: ("1.9 MB", 2097152),
                                            0x50: ("2 MB", 2097152)]
        guard raw[0] != 7, let size = sizes[raw[2]] else {
            apf_close(device)
            throw APFError("This build supports APF-01 cards with a recognized capacity. Device identity: \(raw.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        handle = device; identity = raw; capacityLimit = size.1
        label = "\(size.0) APF-01 · hardware \(raw[0]).\(raw[1])"
    }
    deinit { apf_close(handle) }
    func readSector(_ sector: Int, bytesPerSector: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: max(512, bytesPerSector))
        var error = [CChar](repeating: 0, count: 512)
        guard apf_read_sector(handle, UInt32(sector), UInt32(bytesPerSector), &bytes, &error, error.count) != 0 else {
            throw APFError("Sector \(sector): \(String(cString: error))")
        }
        let count = bytesPerSector == 0 ? Int(bytes[11]) | Int(bytes[12]) << 8 : bytesPerSector
        return Data(bytes.prefix(count))
    }
    func writeSector(_ sector: Int, bytesPerSector: Int, data: Data) throws {
        guard data.count == bytesPerSector else { throw APFError("Wrong sector length") }
        var error = [CChar](repeating: 0, count: 512)
        let success = data.withUnsafeBytes {
            apf_write_sector(handle, UInt32(sector), UInt32(bytesPerSector), $0.bindMemory(to: UInt8.self).baseAddress, &error, error.count)
        }
        guard success != 0 else { throw APFError("Writing sector \(sector): \(String(cString: error))") }
    }
}

// All access to a session occurs on the app's single background queue.
final class CardSession {
    private let backupDirectory: URL?
    init(backupDirectory: URL? = nil) { self.backupDirectory = backupDirectory }
    var connection: APFCardTransport?
    var image = Data()
    var label = ""
    var imageURL: URL?
    var needsReconnect = false
    private(set) var hardwareWriteStarted = false
    var lastBackup: URL?
    private(set) var bytesPerSector = 0
    var isHardware: Bool { connection != nil }
    typealias Progress = (Double, String) -> Void

    func connect(progress: Progress) throws {
        connection = nil; image = Data(); needsReconnect = false; imageURL = nil
        let device = try APFConnection()
        let boot = try device.readSector(0, bytesPerSector: 0)
        let bps = boot.count
        func u16(_ p: Int) -> Int { Int(boot[p]) | Int(boot[p + 1]) << 8 }
        let shortTotal = u16(19)
        let total = shortTotal != 0 ? shortTotal : Int(boot[32]) | Int(boot[33]) << 8 | Int(boot[34]) << 16 | Int(boot[35]) << 24
        guard [128, 256, 512].contains(bps), total > 0, total <= device.capacityLimit / bps else {
            throw APFError("The card's disk geometry does not match its hardware capacity. Format the card in the Portfolio first if it is new.")
        }
        var snapshot = Data(count: total * bps)
        snapshot.replaceSubrange(0..<bps, with: boot)
        for sector in 1..<total {
            let data = try device.readSector(sector, bytesPerSector: bps)
            snapshot.replaceSubrange(sector*bps..<(sector+1)*bps, with: data)
            if sector % 16 == 0 { progress(Double(sector) / Double(total), "Reading card… \(sector * 100 / total)%") }
        }
        // Validate the BPB before exposing the image. Mutations validate the
        // complete graph; damaged cards can still be backed up and read.
        _ = try FAT12Volume(data: snapshot)
        guard try device.readSector(0, bytesPerSector: bps) == boot else {
            throw APFError("The card changed while reading. Disconnect it from the Portfolio and reconnect.")
        }
        connection = device; image = snapshot; bytesPerSector = bps; label = device.label
        progress(1, "Connected")
    }

    func openImage(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 2097152 else { throw APFError("Card images must be 2 MB or smaller") }
        let volume = try FAT12Volume(data: data)
        connection = nil; image = volume.data; imageURL = url; needsReconnect = false
        bytesPerSector = Int(data[11]) | Int(data[12]) << 8
        label = url.lastPathComponent + " · image"
    }

    func automaticBackup() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = backupDirectory ?? base.appendingPathComponent("APF RAM/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("APF-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).img")
        try image.write(to: url, options: .atomic)
        lastBackup = url
        return url
    }

    func commit(_ updated: Data, progress: Progress) throws {
        hardwareWriteStarted = false
        guard !needsReconnect, !image.isEmpty, updated.count == image.count else {
            throw APFError("Reconnect the card before making another change")
        }
        let updatedVolume = try FAT12Volume(data: updated)
        try updatedVolume.validateForMutation()
        let bps = bytesPerSector
        let totalBytes = updatedVolume.totalBytes
        let originalVolume = try FAT12Volume(data: image)
        try originalVolume.validateForMutation()
        guard updatedVolume.bytesPerSector == bps, totalBytes == originalVolume.totalBytes,
              image.prefix(bps) == updated.prefix(bps) else { throw APFError("Changing card format or boot-sector geometry is not supported") }
        guard image[totalBytes...] == updated[totalBytes...] else { throw APFError("Bytes outside the FAT12 volume cannot be changed") }
        let changed = stride(from: 0, to: totalBytes, by: bps).filter {
            image[$0..<$0+bps] != updated[$0..<$0+bps]
        }.map { $0 / bps }
        guard !changed.isEmpty else { return }
        _ = try automaticBackup()
        guard let device = connection else {
            guard let url = imageURL else { throw APFError("No card or image open") }
            guard try Data(contentsOf: url) == image else {
                needsReconnect = true
                throw APFError("The image file changed since it was opened. Open it again before saving.")
            }
            try updated.write(to: url, options: .atomic); image = updated; return
        }
        // The USB handle is held exclusively throughout the session. Check all
        // filesystem metadata plus every sector we will change, instead of
        // rereading unrelated file contents on each upload. Connect / Refresh
        // still reads a complete snapshot after use in the Portfolio.
        let metadata = try originalVolume.metadataSectors()
        let checkSectors = Set(metadata.keys).union(changed).sorted()
        do {
            for (index, sector) in checkSectors.enumerated() {
                let current = try device.readSector(sector, bytesPerSector: bps)
                guard current == image.subdata(in: sector*bps..<(sector+1)*bps) else {
                    throw APFError("The card contents changed. No writes were made. Reconnect to refresh it.")
                }
                progress(Double(index+1)/Double(checkSectors.count)*0.5, "Checking card… \((index+1)*100/checkSectors.count)%")
            }
        } catch {
            needsReconnect = true
            throw error
        }
        // New data first, FAT next, directory entries last. Existing directory
        // clusters are found from the original graph, rather than guessed.
        let ordered = changed.sorted { a, b in
            let ka = metadata[a] ?? 0, kb = metadata[b] ?? 0
            return ka == kb ? a < b : ka < kb
        }
        do {
            for (index, sector) in ordered.enumerated() {
                let data = updated.subdata(in: sector*bps..<(sector+1)*bps)
                hardwareWriteStarted = true
                try device.writeSector(sector, bytesPerSector: bps, data: data)
                guard try device.readSector(sector, bytesPerSector: bps) == data else {
                    throw APFError("Read-back verification failed at sector \(sector)")
                }
                progress(0.5 + Double(index+1)/Double(ordered.count)*0.5, "Writing and verifying… \(index+1)/\(ordered.count) sectors")
            }
            image = updated
        } catch {
            needsReconnect = true
            throw APFError("Upload stopped: \(error.localizedDescription). Reconnect before continuing. The original image is backed up at \(lastBackup?.path ?? "unknown").")
        }
    }

}
