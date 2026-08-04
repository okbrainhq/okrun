import Foundation

/// Lightweight sanity checks for installer disk images before they are handed
/// to the Virtualization framework.
///
/// The classic failure mode is a truncated ISO download: the EFI firmware
/// boots, cannot find a readable boot device (the EFI System Partition lives
/// beyond the truncated end of the file), and the guest powers off almost
/// immediately with no error. These checks read only a handful of sectors and
/// reject images whose own metadata says the file must be larger than it is.
enum InstallerImageVerifier {
    /// Only ISO files are checked; other installer payloads (e.g. macOS
    /// restore images) are validated by the framework itself.
    private static let checkedExtensions: Set<String> = ["iso"]

    /// Upper bound on how many ISO 9660 volume descriptors we walk.
    private static let maxVolumeDescriptors = 64

    static func shouldCheck(url: URL) -> Bool {
        checkedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Throws an ``AppError`` describing the problem when the image is
    /// missing, empty, or truncated.
    static func verifyInstallerImage(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw AppError("Installer image not found: \(url.lastPathComponent)")
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value, fileSize > 0 else {
            throw AppError("Installer image is empty: \(url.lastPathComponent)")
        }

        let expectedSize = try minimumExpectedSize(of: url, fileSize: fileSize)
        guard fileSize >= expectedSize else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            throw AppError(
                "Installer image \"\(url.lastPathComponent)\" appears to be incomplete. " +
                "The file is \(formatter.string(fromByteCount: fileSize)), but the image " +
                "metadata expects at least \(formatter.string(fromByteCount: expectedSize)). " +
                "Download the ISO again and verify its checksum before retrying."
            )
        }
    }

    // MARK: - Metadata parsing

    private static func minimumExpectedSize(of url: URL, fileSize: Int64) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var expected: Int64 = 0
        expected = max(expected, try iso9660ExpectedSize(handle: handle, fileSize: fileSize))
        expected = max(expected, try gptExpectedSize(handle: handle, fileSize: fileSize))
        return expected
    }

    /// ISO 9660: walk the volume descriptor set starting at sector 16 and use
    /// the primary descriptor's volume space size * logical block size.
    private static func iso9660ExpectedSize(handle: FileHandle, fileSize: Int64) throws -> Int64 {
        var expected: Int64 = 0
        for index in 0..<maxVolumeDescriptors {
            let offset = Int64(32_768) + Int64(index) * 2048
            guard offset + 2048 <= fileSize else { break }
            try handle.seek(toOffset: UInt64(offset))
            guard let sector = try handle.read(upToCount: 2048), sector.count == 2048 else { break }

            // Standard identifier "CD001" at bytes 1-5.
            guard sector[1] == 0x43, sector[2] == 0x44, sector[3] == 0x30,
                  sector[4] == 0x30, sector[5] == 0x31 else { break }

            let descriptorType = sector[0]
            if descriptorType == 255 { break } // set terminator
            guard descriptorType == 1 else { continue } // primary volume descriptor only

            let volumeSpaceSize = Int64(uint32LE(sector, 80))
            let blockSize = Int64(uint16LE(sector, 128))
            guard volumeSpaceSize > 0, blockSize > 0,
                  volumeSpaceSize <= Int64.max / blockSize else { continue }
            expected = max(expected, volumeSpaceSize * blockSize)
        }
        return expected
    }

    /// GPT: if a valid primary header exists at LBA 1, the image must contain
    /// everything through the backup header. A backup header parked at EOF
    /// that claims an LBA beyond the file is a direct truncation signal.
    private static func gptExpectedSize(handle: FileHandle, fileSize: Int64) throws -> Int64 {
        guard fileSize >= 2 * 512 else { return 0 }
        try handle.seek(toOffset: 512)
        guard let sector = try handle.read(upToCount: 512), sector.count == 512,
              isGPTSignature(sector) else { return 0 }

        let headerSize = Int(uint32LE(sector, 12))
        guard headerSize >= 92, headerSize <= 512 else { return 0 }

        // Zero the header CRC field and verify it before trusting any fields.
        var header = [UInt8](sector.prefix(headerSize))
        let storedCRC = uint32LE(sector, 16)
        header[16] = 0
        header[17] = 0
        header[18] = 0
        header[19] = 0
        guard crc32(header) == storedCRC else { return 0 }

        let alternateLBA = uint64LE(sector, 32)
        let lastUsableLBA = uint64LE(sector, 48)
        let claimedLastLBA = max(alternateLBA, lastUsableLBA)
        guard claimedLastLBA < UInt64(Int64.max) / 512 else { return 0 }

        var expected = Int64(claimedLastLBA + 1) * 512

        // Backup GPT header, if present at the end of the file, must describe
        // a disk that fits inside the file.
        let backupOffset = Int64(fileSize - 512)
        if backupOffset > 1024 {
            try handle.seek(toOffset: UInt64(backupOffset))
            if let tail = try handle.read(upToCount: 512), tail.count == 512, isGPTSignature(tail) {
                let tailMyLBA = uint64LE(tail, 24)
                guard tailMyLBA < UInt64(Int64.max) / 512 else { return expected }
                expected = max(expected, Int64(tailMyLBA + 1) * 512)
            }
        }
        return expected
    }

    private static func isGPTSignature(_ sector: Data) -> Bool {
        sector[0] == 0x45 && sector[1] == 0x46 && sector[2] == 0x49 && sector[3] == 0x20 &&
            sector[4] == 0x50 && sector[5] == 0x41 && sector[6] == 0x52 && sector[7] == 0x54
    }

    // MARK: - Byte helpers

    private static func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func uint64LE(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32LE(data, offset)) | (UInt64(uint32LE(data, offset + 4)) << 32)
    }

    // MARK: - CRC32 (zlib-compatible, used by the GPT header checksum)

    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
