import Foundation

struct EthernetFrameHeader {
    var destination: EthernetAddress
    var source: EthernetAddress

    static func parse(_ frame: Data) -> EthernetFrameHeader? {
        guard frame.count >= 12 else { return nil }
        let bytes = [UInt8](frame.prefix(12))
        return EthernetFrameHeader(
            destination: EthernetAddress(Array(bytes[0..<6])),
            source: EthernetAddress(Array(bytes[6..<12]))
        )
    }
}

extension EthernetAddress {
    var isUnicast: Bool {
        guard let firstByte = bytes.first else { return false }
        return (firstByte & 0x01) == 0
    }
}
