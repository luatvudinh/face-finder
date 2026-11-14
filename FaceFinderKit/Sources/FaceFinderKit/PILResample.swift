import Foundation

/// Thu nhỏ ảnh đúng như Pillow (`Image.thumbnail(..., Image.BILINEAR)`), để ảnh đưa vào nhận diện trùng với CLI.
///
/// ImageIO/vImage dùng bộ lọc khác (sắc nét hơn), làm YuNet và ArcFace cho kết quả lệch: đo trên 1416 ảnh thì 21%
/// số ảnh lệch điểm >= 0.01 và 10% số ảnh khác số khuôn mặt. Vì vậy phần này chép lại `libImaging/Resample.c`:
/// lọc tam giác có độ rộng tỉ lệ với mức thu nhỏ, hệ số nguyên 22 bit, làm ngang trước rồi dọc.
enum PILResample {
    private static let precisionBits: Int32 = 32 - 8 - 2

    /// Kích thước sau `thumbnail((maxSide, maxSide))`: giữ tỉ lệ, làm tròn về phía cho tỉ lệ gần ảnh gốc hơn.
    static func thumbnailSize(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int)? {
        if maxSide >= width && maxSide >= height { return nil }
        let aspect = Double(width) / Double(height)
        func pick(_ value: Double, _ error: (Int) -> Double) -> Int {
            let lo = Int(value.rounded(.down)), hi = Int(value.rounded(.up))
            return max(error(hi) < error(lo) ? hi : lo, 1)  // bằng nhau thì lấy số nhỏ, như min() của Python
        }
        if 1.0 >= aspect {
            return (pick(Double(maxSide) * aspect) { abs(aspect - Double($0) / Double(maxSide)) }, maxSide)
        }
        return (maxSide, pick(Double(maxSide) / aspect) { $0 == 0 ? 0 : abs(aspect - Double(maxSide) / Double($0)) })
    }

    /// Như `Image.resize(size, BILINEAR, reducing_gap=2.0)`: nếu thu nhỏ từ 2 lần trở lên thì gộp khối nguyên trước.
    static func thumbnail(_ image: BGRAImage, maxSide: Int) -> BGRAImage {
        guard let size = thumbnailSize(width: image.width, height: image.height, maxSide: maxSide) else { return image }
        let fx = max(1, Int(Double(image.width) / Double(size.width) / 2.0))
        let fy = max(1, Int(Double(image.height) / Double(size.height) / 2.0))
        let source = fx > 1 || fy > 1 ? reduce(image, fx, fy) : image
        // Sau khi gộp khối, PIL vẫn tính tỉ lệ theo kích thước gốc chia cho hệ số (có thể lẻ, vd. 517/2 = 258.5).
        return resize(source, width: size.width, height: size.height,
                      boxWidth: Double(image.width) / Double(fx), boxHeight: Double(image.height) / Double(fy))
    }

    /// Gộp khối fx x fy bằng trung bình (như `Image.reduce`); cột/hàng lẻ ở mép lấy trung bình phần còn lại.
    static func reduce(_ image: BGRAImage, _ fx: Int, _ fy: Int) -> BGRAImage {
        let w = (image.width + fx - 1) / fx, h = (image.height + fy - 1) / fy
        var out = [UInt8](repeating: 255, count: w * h * 4)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let y0 = y * fy, y1 = min(image.height, y0 + fy)
                    for x in 0..<w {
                        let x0 = x * fx, x1 = min(image.width, x0 + fx)
                        var b = 0, g = 0, r = 0
                        for yy in y0..<y1 {
                            var i = yy * image.bytesPerRow + x0 * 4
                            for _ in x0..<x1 { b += Int(src[i]); g += Int(src[i + 1]); r += Int(src[i + 2]); i += 4 }
                        }
                        let n = (y1 - y0) * (x1 - x0), o = (y * w + x) * 4
                        dst[o] = UInt8((b + n / 2) / n); dst[o + 1] = UInt8((g + n / 2) / n); dst[o + 2] = UInt8((r + n / 2) / n)
                    }
                }
            }
        }
        return BGRAImage(width: w, height: h, bytesPerRow: w * 4, data: out)
    }

    private struct Coefficients {
        var ksize: Int
        var first: [Int]    // vị trí điểm nguồn đầu tiên cho từng điểm đích
        var count: [Int]    // số điểm nguồn tham gia
        var weights: [Int32]  // count.count * ksize hệ số, thang 2^22
    }

    private static func coefficients(inSize: Int, box: Double, outSize: Int) -> Coefficients {
        let scale = Double(Float(box)) / Double(outSize)  // PIL giữ khung nguồn bằng float 32 bit
        let filterScale = max(scale, 1.0)
        let support = filterScale  // bộ lọc tam giác có support = 1
        let ksize = Int(support.rounded(.up)) * 2 + 1
        var c = Coefficients(ksize: ksize, first: [], count: [], weights: [Int32](repeating: 0, count: outSize * ksize))
        var w = [Double](repeating: 0, count: ksize)
        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            let xmin = max(0, Int(center - support + 0.5))
            let n = min(inSize, Int(center + support + 0.5)) - xmin
            var total = 0.0
            for x in 0..<n {
                let t = abs((Double(x + xmin) - center + 0.5) / filterScale)
                w[x] = t < 1 ? 1 - t : 0
                total += w[x]
            }
            for x in 0..<n {
                let k = total != 0 ? w[x] / total : w[x]
                c.weights[xx * ksize + x] = Int32(0.5 + k * Double(1 << precisionBits))
            }
            c.first.append(xmin)
            c.count.append(n)
        }
        return c
    }

    @inline(__always) private static func clip8(_ v: Int32) -> UInt8 {
        let s = v >> precisionBits
        return s < 0 ? 0 : s > 255 ? 255 : UInt8(truncatingIfNeeded: s)
    }

    static func resize(_ image: BGRAImage, width: Int, height: Int, boxWidth: Double? = nil, boxHeight: Double? = nil) -> BGRAImage {
        let boxWidth = boxWidth ?? Double(image.width), boxHeight = boxHeight ?? Double(image.height)
        let half: Int32 = 1 << (precisionBits - 1)
        var current = image

        if width != current.width || boxWidth != Double(current.width) {  // chiều ngang trước
            let c = coefficients(inSize: current.width, box: boxWidth, outSize: width)
            let h = current.height, srcRow = current.bytesPerRow
            var out = [UInt8](repeating: 255, count: width * h * 4)
            current.data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    c.weights.withUnsafeBufferPointer { kk in
                        for y in 0..<h {
                            let rowIn = src.baseAddress! + y * srcRow
                            let rowOut = dst.baseAddress! + y * width * 4
                            for xx in 0..<width {
                                var p = rowIn + c.first[xx] * 4
                                let k = kk.baseAddress! + xx * c.ksize
                                var b = half, g = half, r = half
                                for x in 0..<c.count[xx] {
                                    let wt = k[x]
                                    b += Int32(p[0]) * wt; g += Int32(p[1]) * wt; r += Int32(p[2]) * wt
                                    p += 4
                                }
                                let o = rowOut + xx * 4
                                o[0] = clip8(b); o[1] = clip8(g); o[2] = clip8(r)
                            }
                        }
                    }
                }
            }
            current = BGRAImage(width: width, height: h, bytesPerRow: width * 4, data: out)
        }

        if height != current.height || boxHeight != Double(current.height) {  // rồi tới chiều dọc: cộng dồn từng hàng nguồn
            let c = coefficients(inSize: current.height, box: boxHeight, outSize: height)
            let w = current.width, srcRow = current.bytesPerRow, n = w * 4
            var out = [UInt8](repeating: 255, count: n * height)
            var acc = [Int32](repeating: 0, count: n)
            current.data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    acc.withUnsafeMutableBufferPointer { a in
                        for yy in 0..<height {
                            for i in 0..<n { a[i] = half }
                            for t in 0..<c.count[yy] {
                                let wt = c.weights[yy * c.ksize + t]
                                let row = src.baseAddress! + (c.first[yy] + t) * srcRow
                                for i in 0..<n { a[i] &+= Int32(row[i]) &* wt }
                            }
                            let o = dst.baseAddress! + yy * n
                            for i in 0..<n { o[i] = clip8(a[i]) }
                        }
                    }
                }
            }
            current = BGRAImage(width: w, height: height, bytesPerRow: n, data: out)
        }
        return current
    }
}

extension BGRAImage {
    /// Xoay/lật theo thẻ EXIF Orientation (1...8), như `ImageOps.exif_transpose`.
    func oriented(_ orientation: Int) -> BGRAImage {
        guard (2...8).contains(orientation) else { return self }
        let swap = orientation >= 5
        let w = swap ? height : width, h = swap ? width : height
        let W = width, H = height, row = bytesPerRow
        var out = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        let sx: Int, sy: Int
                        switch orientation {
                        case 2: (sx, sy) = (W - 1 - x, y)          // lật ngang
                        case 3: (sx, sy) = (W - 1 - x, H - 1 - y)  // xoay 180°
                        case 4: (sx, sy) = (x, H - 1 - y)          // lật dọc
                        case 5: (sx, sy) = (y, x)                  // lật qua đường chéo chính
                        case 6: (sx, sy) = (y, H - 1 - x)          // xoay 90° theo chiều kim đồng hồ
                        case 7: (sx, sy) = (W - 1 - y, H - 1 - x)  // lật qua đường chéo phụ
                        default: (sx, sy) = (W - 1 - y, x)         // 8: xoay 90° ngược chiều kim đồng hồ
                        }
                        let i = sy * row + sx * 4, o = (y * w + x) * 4
                        dst[o] = src[i]; dst[o + 1] = src[i + 1]; dst[o + 2] = src[i + 2]; dst[o + 3] = src[i + 3]
                    }
                }
            }
        }
        return BGRAImage(width: w, height: h, bytesPerRow: w * 4, data: out)
    }
}
