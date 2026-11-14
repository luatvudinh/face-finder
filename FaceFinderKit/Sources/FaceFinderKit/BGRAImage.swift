import CoreGraphics
import Foundation
import ImageIO

/// Ảnh 8 bit, mỗi pixel 4 byte theo thứ tự B, G, R, A (định dạng tự nhiên của macOS và Core ML).
public struct BGRAImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
        precondition(bytesPerRow >= width * 4 && data.count >= bytesPerRow * height)
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    /// Vẽ một CGImage ra bitmap BGRA mà **không đổi hệ màu**: CLI Python (PIL) cũng dùng thẳng giá trị pixel
    /// trong file, bỏ qua ICC profile, nên phải làm giống vậy để điểm số trùng nhau.
    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var space = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        if space.model != .rgb { space = CGColorSpaceCreateDeviceRGB() }
        let rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: space, bitmapInfo: info)
                    ?? CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, bytesPerRow: rowBytes, data: buf)
    }

    /// Đọc nguyên một file ảnh ở đúng kích thước gốc (không thu nhỏ, không xoay). Dùng cho test với golden data.
    public static func loadExact(url: URL) -> BGRAImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return BGRAImage(cgImage: img)
    }

    /// Dữ liệu B, G, R liền nhau theo từng hàng (như mảng ảnh của OpenCV).
    public func bgrBytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var o = 0
                for y in 0..<height {
                    var i = y * bytesPerRow
                    for _ in 0..<width {
                        dst[o] = src[i]; dst[o + 1] = src[i + 1]; dst[o + 2] = src[i + 2]
                        o += 3; i += 4
                    }
                }
            }
        }
        return out
    }
}
