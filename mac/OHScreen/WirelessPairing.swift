import AppKit
import CoreImage
import Darwin
import Foundation

enum WirelessPairing {
    static let port: UInt16 = 27184

    static func randomPin() -> UInt32 {
        UInt32.random(in: 100_000...999_999)
    }

    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let item = ptr {
            let flags = Int32(item.pointee.ifa_flags)
            let up = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            if up, let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    addr.pointee.sa_len > 0 ? socklen_t(addr.pointee.sa_len) : socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !addresses.contains(ip) {
                        addresses.append(ip)
                    }
                }
            }
            ptr = item.pointee.ifa_next
        }
        return addresses.sorted { a, b in
            score(a) > score(b)
        }
    }

    static func qrPayload(pin: UInt32) -> String? {
        let ips = ipv4Addresses()
        guard let primary = ips.first else {
            return nil
        }
        let alts = ips.dropFirst().joined(separator: ",")
        var url = "ohscreen://\(primary):\(port)?pin=\(pin)"
        if !alts.isEmpty {
            url += "&alt=\(alts)"
        }
        return url
    }

    static func qrImage(from payload: String, dimension: CGFloat = 280) -> NSImage? {
        let data = Data(payload.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return nil
        }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.addRepresentation(rep)
        return image
    }

    private static func score(_ ip: String) -> Int {
        if ip.hasPrefix("192.168.") { return 3 }
        if ip.hasPrefix("10.") { return 2 }
        if ip.hasPrefix("172.") { return 1 }
        return 0
    }
}
