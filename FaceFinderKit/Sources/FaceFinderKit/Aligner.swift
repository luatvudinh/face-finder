import Foundation

/// Phép biến đổi đồng dạng 2D (xoay + co giãn đều + tịnh tiến):  x' = a·x − b·y + tx,  y' = b·x + a·y + ty.
public struct Similarity: Sendable, Equatable {
    public var a: Double, b: Double, tx: Double, ty: Double

    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
    }

    /// Ma trận 2x3 theo hàng, cùng thứ tự với `M.ravel()` của OpenCV.
    public var matrix: [Double] { [a, -b, tx, b, a, ty] }
}

/// Căn khuôn mặt theo 5 điểm mốc về khung chuẩn 112x112 của ArcFace.
public enum Aligner {
    public static let size = 112

    /// Vị trí chuẩn: mắt trái, mắt phải, mũi, khoé miệng trái, khoé miệng phải (trái/phải theo ảnh).
    public static let template: [SIMD2<Double>] = [
        SIMD2(38.2946, 51.6963), SIMD2(73.5318, 51.5014), SIMD2(56.0252, 71.7366),
        SIMD2(41.5493, 92.3655), SIMD2(70.7299, 92.2041),
    ]

    /// Dãy cặp điểm mà LMEDS của OpenCV thử khi có 5 điểm: cv::RNG (MWC, hệ số 4164903690) khởi tạo bằng
    /// 2^64 − 1, mỗi lần lấy 2 chỉ số khác nhau theo `next() % 5`, lặp 13 lần (độ tin cậy 0.99, tỉ lệ ngoại lai 0.45).
    static let opencvPairs: [(Int, Int)] = [
        (0, 4), (0, 3), (1, 2), (1, 0), (3, 0), (0, 4), (1, 4), (3, 1), (0, 3), (0, 1), (0, 4), (4, 1), (0, 3),
    ]

    /// Sắp lại điểm mốc của YuNet cho khớp `template`, y hệt `findface.analyze()`: điểm nào nằm bên trái ảnh
    /// thì đứng trước.
    public static func ordered(_ landmarks: [SIMD2<Float>]) -> [SIMD2<Double>] {
        var lm = landmarks.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        if lm[0].x > lm[1].x { lm.swapAt(0, 1) }
        if lm[3].x > lm[4].x { lm.swapAt(3, 4) }
        return lm
    }

    /// Bình phương tối thiểu trên toàn bộ các điểm (nghiệm đóng).
    public static func leastSquares(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>]) -> Similarity? {
        let n = Double(src.count)
        guard src.count >= 2, src.count == dst.count else { return nil }
        let ms = src.reduce(SIMD2<Double>.zero, +) / n, md = dst.reduce(SIMD2<Double>.zero, +) / n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for (p, q) in zip(src, dst) {
            let u = p - ms, v = q - md
            dot += u.x * v.x + u.y * v.y
            cross += u.x * v.y - u.y * v.x
            norm += u.x * u.x + u.y * u.y
        }
        guard norm > 1e-12 else { return nil }
        let a = dot / norm, b = cross / norm
        return Similarity(a: a, b: b, tx: md.x - (a * ms.x - b * ms.y), ty: md.y - (b * ms.x + a * ms.y))
    }

    /// Ước lượng bền vững, tương đương `cv2.estimateAffinePartial2D(method=LMEDS)` mà CLI dùng:
    /// thử mô hình dựng từ từng cặp điểm, lấy mô hình có trung vị sai số nhỏ nhất, loại điểm lệch quá xa
    /// rồi tính lại bằng bình phương tối thiểu trên các điểm còn lại.
    ///
    /// OpenCV thử 13 cặp "ngẫu nhiên", nhưng bộ sinh số luôn khởi tạo cùng một giá trị nên với 5 điểm thì lần nào
    /// cũng là đúng dãy cặp trong `opencvPairs` (chỉ 6 cặp khác nhau, luôn chứa một con mắt). Dùng lại đúng dãy
    /// đó thì ma trận trùng CLI trên toàn bộ golden data; thử đủ 10 cặp thì lệch ở ~0,15% số mặt.
    public static func robust(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>]) -> Similarity? {
        let n = src.count
        guard n == dst.count, n >= 2 else { return nil }
        if n == 2 { return leastSquares(src, dst) }
        func errors(_ m: Similarity) -> [Double] {
            zip(src, dst).map { p, q in let d = m.apply(p) - q; return d.x * d.x + d.y * d.y }
        }
        let pairs = n == 5 ? opencvPairs : (0..<n).flatMap { i in ((i + 1)..<n).map { (i, $0) } }
        var best: Similarity?, bestMedian = Double.infinity
        for (i, j) in pairs {
            guard let m = leastSquares([src[i], src[j]], [dst[i], dst[j]]) else { continue }
            let e = errors(m).sorted()
            let median = n % 2 == 1 ? e[n / 2] : (e[n / 2 - 1] + e[n / 2]) / 2
            if median < bestMedian { bestMedian = median; best = m }
        }
        guard let model = best else { return nil }
        let sigma = max(2.5 * 1.4826 * (1 + 5.0 / Double(n - 2)) * bestMedian.squareRoot(), 0.001)
        let inliers = errors(model).enumerated().filter { $0.element <= sigma * sigma }.map(\.offset)
        guard inliers.count > 2 else { return model }
        return leastSquares(inliers.map { src[$0] }, inliers.map { dst[$0] }) ?? model
    }

    /// Cắt + xoay khuôn mặt ra ảnh 112x112, nội suy song tuyến tính, ngoài ảnh là màu đen (như `cv2.warpAffine`).
    /// Trả về 112*112*3 byte theo thứ tự R, G, B.
    public static func warp(_ image: BGRAImage, _ m: Similarity) -> [UInt8] {
        let n = size
        var out = [UInt8](repeating: 0, count: n * n * 3)
        // nghịch đảo: từ toạ độ đích về toạ độ ảnh nguồn
        let det = m.a * m.a + m.b * m.b
        guard det > 1e-12 else { return out }
        let ia = m.a / det, ib = -m.b / det
        let itx = -(ia * m.tx - ib * m.ty), ity = -(ib * m.tx + ia * m.ty)
        let w = image.width, h = image.height, row = image.bytesPerRow
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<n {
                    for x in 0..<n {
                        let sx = ia * Double(x) - ib * Double(y) + itx, sy = ib * Double(x) + ia * Double(y) + ity
                        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                        if x0 < -1 || y0 < -1 || x0 >= w || y0 >= h { continue }
                        let fx = sx - Double(x0), fy = sy - Double(y0)
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        var b = 0.0, g = 0.0, r = 0.0
                        func add(_ px: Int, _ py: Int, _ wt: Double) {
                            guard px >= 0, py >= 0, px < w, py < h else { return }
                            let i = py * row + px * 4
                            b += wt * Double(src[i]); g += wt * Double(src[i + 1]); r += wt * Double(src[i + 2])
                        }
                        add(x0, y0, w00); add(x0 + 1, y0, w10); add(x0, y0 + 1, w01); add(x0 + 1, y0 + 1, w11)
                        let o = (y * n + x) * 3
                        dst[o] = UInt8(min(255, max(0, r.rounded())))
                        dst[o + 1] = UInt8(min(255, max(0, g.rounded())))
                        dst[o + 2] = UInt8(min(255, max(0, b.rounded())))
                    }
                }
            }
        }
        return out
    }
}
