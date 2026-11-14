import Testing
@testable import FaceFinderKit

@Suite struct AlignerTests {
    /// Biến đổi biết trước: xoay 20°, phóng 1.7, tịnh tiến (30, -12).
    private let known = Similarity(a: 1.7 * 0.9396926, b: 1.7 * 0.3420201, tx: 30, ty: -12)

    @Test func leastSquaresRecoversKnownTransform() throws {
        let src = Aligner.template
        let m = try #require(Aligner.leastSquares(src, src.map(known.apply)))
        for (got, want) in zip(m.matrix, known.matrix) { #expect(abs(got - want) < 1e-9) }
    }

    @Test func robustIgnoresOneBadLandmark() throws {
        let src = Aligner.template
        var dst = src.map(known.apply)
        dst[4] += SIMD2(25, -18)  // một điểm mốc lệch hẳn
        let m = try #require(Aligner.robust(src, dst))
        for (got, want) in zip(m.matrix, known.matrix) { #expect(abs(got - want) < 1e-9) }
        let plain = try #require(Aligner.leastSquares(src, dst))
        #expect(abs(plain.tx - known.tx) > 1)  // bình phương tối thiểu thường thì bị kéo lệch
    }

    @Test func orderedPutsLeftmostFirst() {
        // YuNet trả về mắt phải của người (bên trái ảnh) trước; ảnh lộn ngược thì đảo lại.
        let lm: [SIMD2<Float>] = [SIMD2(80, 50), SIMD2(40, 50), SIMD2(60, 70), SIMD2(75, 90), SIMD2(45, 90)]
        let o = Aligner.ordered(lm)
        #expect(o[0].x == 40 && o[1].x == 80 && o[3].x == 45 && o[4].x == 75)
    }

    @Test func warpWithIdentityCopiesPixels() {
        let n = Aligner.size
        var data = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            data[i * 4] = UInt8(i % 251); data[i * 4 + 1] = UInt8(i % 241); data[i * 4 + 2] = UInt8(i % 239); data[i * 4 + 3] = 255
        }
        let out = Aligner.warp(BGRAImage(width: n, height: n, bytesPerRow: n * 4, data: data), Similarity(a: 1, b: 0, tx: 0, ty: 0))
        for i in stride(from: 0, to: n * n, by: 97) {
            #expect(out[i * 3] == data[i * 4 + 2] && out[i * 3 + 1] == data[i * 4 + 1] && out[i * 3 + 2] == data[i * 4])
        }
    }
}
