import Foundation
import Testing
@testable import FaceFinderKit

/// `ImageLoader.load` phải cho ra đúng từng byte như `findface.load_image` của CLI Python (Pillow + libjpeg-turbo).
/// Dữ liệu tạo bởi tools/make_test_fixtures.py từ ảnh nhiễu.
@Suite struct ImageLoaderTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures")))
    }

    @Test(arguments: [("draft", 120), ("rotated", 150), ("mpo", 120), ("asis", 2400)])
    func loadMatchesFindface(name: String, side: Int) throws {
        let want = try fixture("load_\(name)_out_\(side)")
        let w = Int(want[0]) | Int(want[1]) << 8, h = Int(want[4]) | Int(want[5]) << 8
        let rgb = [UInt8](want.dropFirst(8))
        let (image, scale) = try ImageLoader.load(try fixture("load_\(name)_file"), maxSide: side)
        #expect(image.width == w && image.height == h)
        let bgr = image.bgrBytes()
        var different = 0
        for i in 0..<min(w * h, bgr.count / 3) where bgr[i * 3] != rgb[i * 3 + 2] || bgr[i * 3 + 1] != rgb[i * 3 + 1] || bgr[i * 3 + 2] != rgb[i * 3] {
            different += 1
        }
        #expect(different == 0, "\(different) pixel khác CLI")
        #expect(abs(scale - Double(max(w, h)) / 520) < 1e-12)
    }

    @Test func mpoIsDetectedLikePillow() throws {
        #expect(ImageLoader.pillowTreatsAsMPO(try fixture("load_mpo_file")))
        #expect(!ImageLoader.pillowTreatsAsMPO(try fixture("load_draft_file")))
        #expect(!ImageLoader.pillowTreatsAsMPO(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    @Test func brokenJPEGIsAnErrorNotACrash() throws {
        let data = try fixture("load_draft_file")
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(Data(data.prefix(40)), maxSide: 120) }
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(Data("không phải ảnh".utf8), maxSide: 120) }
        _ = try? ImageLoader.load(Data(data.prefix(data.count / 2)), maxSide: 120)  // cụt giữa chừng: không được treo/sập
    }

    @Test func bundledDecoderVersion() {
        #expect(ImageLoader.turboVersion == "3.1.4.1")  // phải cùng bản với Pillow của CLI; đổi thì đo lại (PLAN.md 5.1)
    }
}
