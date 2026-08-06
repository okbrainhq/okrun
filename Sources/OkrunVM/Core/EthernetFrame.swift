import Foundation

struct EthernetFrameHeader {
    var destination: EthernetAddress
    var source: EthernetAddress
    var etherType: UInt16?

    static func parse(_ frame: Data) -> EthernetFrameHeader? {
        guard frame.count >= 12 else { return nil }
        let bytes = [UInt8](frame.prefix(14))
        let etherType: UInt16? = bytes.count >= 14
            ? (UInt16(bytes[12]) << 8) | UInt16(bytes[13])
            : nil
        return EthernetFrameHeader(
            destination: EthernetAddress(Array(bytes[0..<6])),
            source: EthernetAddress(Array(bytes[6..<12])),
            etherType: etherType
        )
    }

    var logDescription: String {
        let formattedEtherType = etherType.map { String(format: "0x%04x", $0) } ?? "unknown"
        return "source=\(source.description) destination=\(destination.description) etherType=\(formattedEtherType)"
    }
}

extension EthernetAddress {
    var isUnicast: Bool {
        guard let firstByte = bytes.first else { return false }
        return (firstByte & 0x01) == 0
    }
}
