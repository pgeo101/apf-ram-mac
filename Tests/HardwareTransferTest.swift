import Foundation

// Explicitly invoked diagnostic, excluded from test.sh and the app bundle.
// It creates one unique test file through production commit(), then restores
// every modified sector from the verified original snapshot.
@main struct HardwareTransferTest {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--run-transfer-test" else {
            fputs("Requires --run-transfer-test /absolute/path/to/verified-backup.img\n", stderr); exit(2)
        }
        do {
            let backup = URL(fileURLWithPath: CommandLine.arguments[2])
            let original = try Data(contentsOf: backup)
            var volume = try FAT12Volume(data: original)
            try volume.validateForMutation()
            guard !(try volume.entries(in: "/")).contains(where: { $0.name.caseInsensitiveCompare("APFTEST.TXT") == .orderedSame }) else {
                throw APFError("APFTEST.TXT already exists. No card writes.")
            }
            let content = Data("APF RAM native Mac USB transfer test.\r\n".utf8)
            try volume.putFile(name: "APFTEST.TXT", contents: content, in: "/")
            let updated = volume.data, bps = volume.bytesPerSector
            let changed = stride(from: 0, to: volume.totalBytes, by: bps).filter {
                original[$0..<$0+bps] != updated[$0..<$0+bps]
            }.map { $0/bps }
            let session = CardSession(backupDirectory: backup.deletingLastPathComponent().appendingPathComponent("TestBackups"))
            try session.openImage(backup)
            let device = try APFConnection()
            session.connection = device; session.imageURL = nil; session.label = device.label
            print("\(device.label). Test changes \(changed.count) sectors: \(changed).")
            print("Checking filesystem metadata and affected sectors before writing.")
            fflush(stdout)
            var failure: Error?
            do {
                var last = -1
                try session.commit(updated) { fraction, message in
                    let bucket = Int(fraction * 10)
                    if bucket != last { print("\(Int(fraction*100))% \(message)"); fflush(stdout); last = bucket }
                }
                var actual = original
                for sector in changed {
                    let bytes = try device.readSector(sector, bytesPerSector: bps)
                    actual.replaceSubrange(sector*bps..<(sector+1)*bps, with: bytes)
                }
                let check = try FAT12Volume(data: actual)
                guard try check.readFile(path: "/APFTEST.TXT") == content else { throw APFError("Test file readback differs") }
                print("Native upload and independent file read-back passed.")
            } catch { failure = error }
            if session.hardwareWriteStarted {
                print("Restoring original sectors from backup."); fflush(stdout)
                // Remove the temporary directory entry first, then restore FAT
                // and free-cluster bytes. No Portfolio is attached during test.
                let bytes = [UInt8](original)
                func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p+1])<<8 }
                let fatStart=u16(14), root=fatStart+Int(bytes[16])*u16(22), rootEnd=root+(u16(17)*32+bps-1)/bps
                func order(_ sector: Int) -> Int { sector>=root && sector<rootEnd ? 0 : sector>=fatStart && sector<root ? 1 : 2 }
                let restoreOrder=changed.sorted { order($0)==order($1) ? $0<$1 : order($0)<order($1) }
                var restoreFailures: [String] = []
                for sector in restoreOrder {
                    do {
                        let expected = original.subdata(in: sector*bps..<(sector+1)*bps)
                        if try device.readSector(sector, bytesPerSector: bps) != expected {
                            try device.writeSector(sector, bytesPerSector: bps, data: expected)
                        }
                        guard try device.readSector(sector, bytesPerSector: bps) == expected else { throw APFError("readback mismatch") }
                    } catch {
                        restoreFailures.append("\(sector): \(error.localizedDescription)")
                    }
                }
                guard restoreFailures.isEmpty else {
                    throw APFError("RESTORE FAILED for sectors \(restoreFailures.joined(separator: "; ")). Original backup: \(backup.path)")
                }
                print("All changed sectors restored and verified byte-for-byte. Test file removed.")
            }
            if let failure { throw failure }
        } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
    }
}
