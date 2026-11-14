import CJPEGTurbo
import CoreGraphics
import Foundation
import ImageIO

public enum ImageLoaderError: Error, CustomStringConvertible {
    case notAnImage
    case decodeFailed

    public var description: String {
        switch self {
        case .notAnImage: return "không phải file ảnh đọc được"
        case .decodeFailed: return "giải mã ảnh thất bại"
        }
    }
}

public enum ImageLoader {
    /// Bộ giải mã dùng cho JPEG (xem PLAN.md mục 5.1). Định dạng khác luôn đi qua ImageIO.
    public enum JPEGMode: String, Sendable {
        /// libjpeg-turbo đóng gói kèm, cùng thiết lập với Pillow: pixel trùng CLI Python từng byte. Mặc định.
        case turbo
        /// Bộ giải mã của ImageIO: pixel lệch ~0,6 mức xám so với libjpeg-turbo, làm ~9% số ảnh lệch điểm >= 0,01.
        case imageio
        /// Để ImageIO tự thu nhỏ (`CGImageSourceCreateThumbnailAtIndex`): lệch nhiều nhất, chỉ để so sánh.
        case thumbnail
    }

    /// Phiên bản libjpeg-turbo đang đóng gói.
    public static var turboVersion: String { String(cString: ff_jpeg_version()) }

    /// Đọc ảnh, xoay đúng theo EXIF, thu nhỏ để cạnh dài <= `maxSide` (không phóng to). Tương đương
    /// `findface.load_image()`: cùng bộ giải mã JPEG, cùng mức giải mã rút gọn, cùng bộ lọc thu nhỏ.
    /// `scale` = kích thước sau thu nhỏ / kích thước gốc, dùng để đổi toạ độ khuôn mặt về ảnh gốc.
    public static func load(_ data: Data, maxSide: Int, jpeg: JPEGMode = .turbo) throws -> (image: BGRAImage, scale: Double) {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { throw ImageLoaderError.notAnImage }
        let longSide = max(w, h)
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // Nhận JPEG theo 3 byte đầu như Pillow, không theo loại ImageIO báo (file MPO được ImageIO gọi là
        // "public.mpo-image" nhưng ảnh chính bên trong vẫn là JPEG).
        let isJPEG = data.count > 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])

        if jpeg == .thumbnail {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxSide, longSide),
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
                  let image = BGRAImage(cgImage: cg) else { throw ImageLoaderError.decodeFailed }
            return (image, Double(max(image.width, image.height)) / Double(longSide))
        }

        // Mức rút gọn PIL chọn (`Image.draft`): lớn nhất trong 1, 2, 4, 8 mà ảnh vẫn không nhỏ hơn kích thước cần.
        // findface chỉ gọi draft() khi `im.format == "JPEG"`; file MPO (vd. máy ảnh Sony) được giải mã đủ độ phân giải.
        var factor = 1
        let s = min(1.0, Double(maxSide) / Double(longSide))
        if s < 1, isJPEG, !pillowTreatsAsMPO(data) {
            let ratio = min(w / max(1, Int(Double(w) * s)), h / max(1, Int(Double(h) * s)))
            factor = ratio >= 8 ? 8 : ratio >= 4 ? 4 : ratio >= 2 ? 2 : 1
        }
        var decoded = isJPEG && jpeg == .turbo ? decodeWithTurbo(data, factor: factor) : nil
        if decoded == nil {  // không phải JPEG, hoặc loại JPEG mà lớp bọc không xử lý (CMYK, 12 bit), hoặc file hỏng
            var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
            guard let cg = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else { throw ImageLoaderError.decodeFailed }
            decoded = BGRAImage(cgImage: cg)
        }
        guard let decoded else { throw ImageLoaderError.decodeFailed }
        let image = PILResample.thumbnail(decoded.oriented(orientation), maxSide: maxSide)
        return (image, Double(max(image.width, image.height)) / Double(longSide))
    }

    /// Giải mã JPEG bằng libjpeg-turbo ở tỉ lệ 1/`factor`. Trả về `nil` nếu không giải mã được.
    static func decodeWithTurbo(_ data: Data, factor: Int) -> BGRAImage? {
        data.withUnsafeBytes { raw -> BGRAImage? in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var w: Int32 = 0, h: Int32 = 0
            guard ff_jpeg_output_size(bytes, raw.count, Int32(factor), &w, &h) == FF_JPEG_OK, w > 0, h > 0 else { return nil }
            let count = Int(w) * Int(h) * 4
            var ok = false
            let pixels = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                ok = ff_jpeg_decode_bgra(bytes, raw.count, Int32(factor), buffer.baseAddress, count) == FF_JPEG_OK
                if !ok { buffer.initialize(repeating: 0) }
                initialized = count
            }
            return ok ? BGRAImage(width: Int(w), height: Int(h), bytesPerRow: Int(w) * 4, data: pixels) : nil
        }
    }

    /// Pillow có coi file JPEG này là "MPO" không (`JpegImagePlugin.jpeg_factory`): có khối APP2 "MPF" khai báo nhiều
    /// hơn một ảnh, và không phải Ultra HDR. Nhiều máy ảnh (Sony...) ghi JPEG kiểu này vì kèm ảnh xem trước.
    static func pillowTreatsAsMPO(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n > 4, b[0] == 0xFF, b[1] == 0xD8 else { return false }
            let hdr = Array(" hdrgm:Version=\"".utf8)
            var i = 2, images = 0, ultraHDR = false
            while i + 4 <= n, b[i] == 0xFF {
                let marker = b[i + 1]
                if marker == 0xFF { i += 1; continue }                       // byte đệm
                if marker == 0xDA || marker == 0xD9 { break }                // tới dữ liệu ảnh: Pillow ngừng đọc header
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                let start = i + 4, end = i + 2 + length
                guard length >= 2, end <= n else { break }
                if marker == 0xE2, end - start >= 12, b[start] == 0x4D, b[start + 1] == 0x50, b[start + 2] == 0x46, b[start + 3] == 0 {
                    images = mpImageCount(b, start + 4, end) ?? 0
                } else if marker == 0xE1, end - start >= hdr.count {
                    var k = start
                    while k + hdr.count <= end, !ultraHDR {
                        if b[k] == hdr[0], (1..<hdr.count).allSatisfy({ b[k + $0] == hdr[$0] }) { ultraHDR = true }
                        k += 1
                    }
                }
                i = end
            }
            return images > 1 && !ultraHDR
        }
    }

    /// Đọc thẻ NumberOfImages (0xB001) trong MP Index IFD (cấu trúc kiểu TIFF bắt đầu tại `base`).
    private static func mpImageCount(_ b: UnsafeBufferPointer<UInt8>, _ base: Int, _ end: Int) -> Int? {
        let big = b[base] == 0x4D
        func u16(_ o: Int) -> Int { big ? Int(b[o]) << 8 | Int(b[o + 1]) : Int(b[o + 1]) << 8 | Int(b[o]) }
        func u32(_ o: Int) -> Int { big ? u16(o) << 16 | u16(o + 2) : u16(o + 2) << 16 | u16(o) }
        let ifd = base + u32(base + 4)
        guard ifd + 2 <= end else { return nil }
        for e in 0..<u16(ifd) {
            let entry = ifd + 2 + e * 12
            guard entry + 12 <= end else { return nil }
            if u16(entry) == 0xB001 { return u32(entry + 8) }
        }
        return nil
    }
}
