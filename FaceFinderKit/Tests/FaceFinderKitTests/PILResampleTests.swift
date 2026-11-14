import Foundation
import Testing
@testable import FaceFinderKit

/// Bước thu nhỏ phải cho ra đúng từng byte như Pillow. Dữ liệu tạo bởi tools/make_test_fixtures.py (ảnh nhiễu).
@Suite struct PILResampleTests {
    private func load(_ name: String) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let w = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16, h = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16
        return (w, h, [UInt8](data.dropFirst(8)))
    }

    private func image(_ f: (width: Int, height: Int, rgb: [UInt8])) -> BGRAImage {
        var bgra = [UInt8](repeating: 255, count: f.width * f.height * 4)
        for i in 0..<(f.width * f.height) {
            bgra[i * 4] = f.rgb[i * 3 + 2]; bgra[i * 4 + 1] = f.rgb[i * 3 + 1]; bgra[i * 4 + 2] = f.rgb[i * 3]
        }
        return BGRAImage(width: f.width, height: f.height, bytesPerRow: f.width * 4, data: bgra)
    }

    @Test(arguments: [("small", 208), ("large", 96), ("tall", 200)])
    func thumbnailMatchesPillow(name: String, side: Int) throws {
        let input = image(try load("resample_\(name)_in"))
        let want = try load("resample_\(name)_out_\(side)")
        let got = PILResample.thumbnail(input, maxSide: side)
        #expect(got.width == want.width && got.height == want.height)
        let bgr = got.bgrBytes()
        var different = 0
        for i in 0..<(want.width * want.height) where bgr[i * 3] != want.rgb[i * 3 + 2] || bgr[i * 3 + 1] != want.rgb[i * 3 + 1] || bgr[i * 3 + 2] != want.rgb[i * 3] {
            different += 1
        }
        #expect(different == 0, "\(different) pixel khác Pillow")
    }

    @Test func noUpscaling() {
        let img = BGRAImage(width: 40, height: 30, bytesPerRow: 160, data: [UInt8](repeating: 7, count: 4800))
        let out = PILResample.thumbnail(img, maxSide: 2400)
        #expect(out.width == 40 && out.height == 30)
    }

    @Test func orientationRotatesClockwise() {
        // ảnh 2x1: [A, B]; EXIF 6 = xoay 90° theo chiều kim đồng hồ -> ảnh 1x2: A ở trên, B ở dưới
        let img = BGRAImage(width: 2, height: 1, bytesPerRow: 8, data: [1, 1, 1, 255, 2, 2, 2, 255])
        let out = img.oriented(6)
        #expect(out.width == 1 && out.height == 2 && out.data[0] == 1 && out.data[4] == 2)
        let back = out.oriented(8)
        #expect(back.width == 2 && back.height == 1 && back.data[0] == 1 && back.data[4] == 2)
    }
}
