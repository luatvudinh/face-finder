import Accelerate
import Foundation

/// Chuyển Float32 <-> Float16 bằng vImage. Không dùng kiểu `Float16` của Swift vì nó không có trên Mac Intel (x86_64).
/// Làm tròn về số gần nhất (như `numpy.astype(float16)` của CLI và `Float16(x)` của Swift).
public enum Half {
    /// Mã hoá thành dữ liệu Float16 (2 byte mỗi số, little-endian).
    public static func encode(_ values: [Float]) -> Data {
        var out = Data(count: values.count * 2)
        guard !values.isEmpty else { return out }
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    public static func decode(_ data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        guard n > 0 else { return out }
        data.withUnsafeBytes { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(n), rowBytes: n * 2)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// Làm tròn qua Float16 (dữ liệu trong chỉ mục lưu ở độ chính xác này).
    public static func round(_ values: [Float]) -> [Float] { decode(encode(values)) }
}
