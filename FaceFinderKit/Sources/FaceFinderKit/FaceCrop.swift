import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ảnh nhỏ quanh một khuôn mặt, để hiển thị (không dùng cho nhận diện nên giải mã bằng ImageIO cho nhanh).
public enum FaceCrop {
    /// `x, y, width, height`: khung mặt theo toạ độ ảnh gốc đã xoay đúng chiều (như `FaceRecord`).
    /// Lấy rộng ra `margin` x cạnh mặt mỗi phía (như ảnh ghép của CLI); cạnh dài kết quả khoảng >= `side` px.
    public static func image(from data: Data, x: Float, y: Float, width: Float, height: Float, side: Int = 240,
                             margin: Double = 0.6) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let (w, h) = orientation >= 5 ? (ph, pw) : (pw, ph)
        let m = margin * Double(max(width, height))
        let region = CGRect(x: Double(x) - m, y: Double(y) - m, width: Double(width) + 2 * m, height: Double(height) + 2 * m)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        // giải mã ở độ phân giải thấp nhất mà vùng mặt vẫn đủ `side` px
        var factor = 8
        while factor > 1, max(region.width, region.height) / Double(factor) < Double(side) { factor /= 2 }
        let longSide = max(w, h)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longSide / factor),
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let s = Double(max(full.width, full.height)) / Double(longSide)
        let r = CGRect(x: region.minX * s, y: region.minY * s, width: region.width * s, height: region.height * s).integral
        return full.cropping(to: r)
    }

    /// Mã hoá JPEG (để lưu ảnh khuôn mặt mẫu).
    public static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
