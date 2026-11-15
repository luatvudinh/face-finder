import Accelerate
import Foundation

// Phần "so khớp" của findface.py, chép 1:1: xác định người cần tìm từ ảnh mẫu, chấm điểm, tự mở rộng ảnh mẫu,
// ngưỡng "Cần kiểm tra" tự điều chỉnh. Mọi thay đổi ở đây phải cho điểm giống CLI trên cùng bộ ảnh.

/// Một khuôn mặt trong ảnh mẫu được coi là của người cần tìm.
public struct RefFace: Sendable {
    public let item: ImageItem
    public let faceIndex: Int
    public let face: FaceRecord
    /// Độ giống (cosine) với "tâm" của người này.
    public let similarity: Float
}

/// Một người có thể là "người cần tìm": mỗi ảnh mẫu đóng góp khuôn mặt giống người đó nhất.
public struct Identity: Sendable {
    public let members: [RefFace]
    /// Những khuôn mặt (ảnh + số thứ tự) thật sự thuộc về người này (giống >= `Scorer.minRefSimilarity`).
    public let cover: Set<String>
    public let score: Double

    /// Các khuôn mặt dùng làm mẫu.
    public var references: [RefFace] { members.filter { $0.similarity >= Scorer.minRefSimilarity } }
}

public struct ItemScore: Sendable {
    public let item: ImageItem
    /// Điểm của ảnh = khuôn mặt giống nhất; -1 nếu ảnh không có khuôn mặt nào.
    public let score: Float
    public let face: FaceRecord?
    public let faceCount: Int

    public init(item: ImageItem, score: Float, face: FaceRecord?, faceCount: Int) {
        self.item = item; self.score = score; self.face = face; self.faceCount = faceCount
    }
}

public enum MatchStatus: String, Sendable {
    case matched = "Khớp", review = "Cần kiểm tra", none = "Không"
    /// Người dùng đánh dấu ✗ (không phải người này).
    case rejected = "Đã loại"
}

/// Đánh dấu của người dùng trên kết quả ("học thêm", PLAN.md mục 4): ảnh ✓ được thêm vào ảnh mẫu, ảnh ✗ bị loại.
public struct SearchMarks: Sendable, Equatable {
    /// Ảnh đã xác nhận đúng → vân mặt của khuôn mặt đã khớp trong ảnh đó (dùng làm mẫu bổ sung).
    public var confirmed: [String: [Float]]
    /// Ảnh đã đánh dấu sai.
    public var rejected: Set<String>

    public init(confirmed: [String: [Float]] = [:], rejected: Set<String> = []) {
        self.confirmed = confirmed
        self.rejected = rejected
    }
}

public struct SearchOptions: Sendable {
    public var threshold = 0.475
    /// Cận dưới của "Cần kiểm tra"; `nil` = tự điều chỉnh theo bộ ảnh.
    public var review: Double?
    public var expand = true
    public var expandThreshold = 0.60
    public var expandLimit = 200

    public init() {}
}

public struct SearchResult: Sendable {
    /// Mọi ảnh, điểm giảm dần.
    public let scores: [ItemScore]
    public let threshold: Double
    public let review: Double
    /// Cận dưới "Cần kiểm tra" khi chưa bị chặn bởi ngưỡng (`review = min(threshold, reviewBase)`).
    public let reviewBase: Double
    /// Số khuôn mặt mẫu được bổ sung ở bước mở rộng.
    public let expandedBy: Int
    /// Ảnh người dùng đã đánh dấu ✓ (luôn "Khớp") và ✗ (luôn "Đã loại").
    public let confirmed: Set<String>
    public let rejected: Set<String>

    public init(scores: [ItemScore], threshold: Double, review: Double, reviewBase: Double, expandedBy: Int,
                confirmed: Set<String> = [], rejected: Set<String> = []) {
        self.scores = scores
        self.threshold = threshold
        self.review = review
        self.reviewBase = reviewBase
        self.expandedBy = expandedBy
        self.confirmed = confirmed
        self.rejected = rejected
    }

    /// Cùng kết quả với ngưỡng khác: điểm không đổi, chỉ chia nhóm lại (thanh trượt ngưỡng trong app).
    /// Bước mở rộng dùng ngưỡng riêng (0.60) nên không phải chấm lại.
    public func with(threshold: Double) -> SearchResult {
        SearchResult(scores: scores, threshold: threshold, review: min(threshold, reviewBase), reviewBase: reviewBase,
                     expandedBy: expandedBy, confirmed: confirmed, rejected: rejected)
    }

    /// Nhóm theo điểm (không xét đánh dấu của người dùng).
    public func status(of score: Float) -> MatchStatus {
        Double(score) >= threshold ? .matched : Double(score) >= review ? .review : .none
    }

    /// Nhóm của một ảnh: đánh dấu của người dùng thắng điểm số.
    public func status(of s: ItemScore) -> MatchStatus {
        if rejected.contains(s.item.key) { return .rejected }
        if confirmed.contains(s.item.key) { return .matched }
        return status(of: s.score)
    }

    public var matched: [ItemScore] { scores.filter { status(of: $0) == .matched } }
    public var needsReview: [ItemScore] { scores.filter { status(of: $0) == .review } }
    public var rejectedScores: [ItemScore] { scores.filter { status(of: $0) == .rejected } }
}

public enum ScorerError: Error, CustomStringConvertible {
    case anchorNotFound(String)

    public var description: String {
        switch self {
        case .anchorNotFound(let name): return String(localized: "'\(name)' không phải ảnh mẫu nào có khuôn mặt", bundle: .module)
        }
    }
}

public enum Scorer {
    /// Mặt trong ảnh mẫu phải giống "người cần tìm" ít nhất mức này.
    public static let minRefSimilarity: Float = 0.35
    /// Ưu tiên người có mặt to (nổi bật) trong ảnh mẫu.
    static let prominence = 0.3

    struct RefImage {
        let item: ImageItem
        let faces: [FaceRecord]
        /// Diện tích mặt so với mặt lớn nhất trong ảnh.
        let prominence: [Float]
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }

    /// Vị trí giá trị lớn nhất đầu tiên (như `np.argmax`).
    static func argmax(_ v: [Float]) -> Int {
        var best = 0
        for i in v.indices where v[i] > v[best] { best = i }
        return best
    }

    /// Trung bình các vector rồi chuẩn hoá về độ dài 1.
    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(sum.count)) }
        var n = Float(vectors.count)
        vDSP_vsdiv(sum, 1, &n, &sum, 1, vDSP_Length(sum.count))
        var sq: Float = 0
        vDSP_svesq(sum, 1, &sq, vDSP_Length(sum.count))
        var norm = sq.squareRoot()
        vDSP_vsdiv(sum, 1, &norm, &sum, 1, vDSP_Length(sum.count))
        return sum
    }

    /// Lặp: chọn mặt giống nhất trong mỗi ảnh mẫu, lấy tâm các mặt đó làm chuẩn mới.
    static func refine(_ images: [RefImage], target start: [Float], iterations: Int = 3) -> [RefFace] {
        var target = start
        for _ in 0..<iterations {
            var good: [[Float]] = []
            for img in images {
                let sims = img.faces.map { dot($0.embedding, target) }
                let m = argmax(sims)
                if sims[m] >= minRefSimilarity { good.append(img.faces[m].embedding) }
            }
            if good.isEmpty { break }
            target = centroid(good)
        }
        return images.map { img in
            let sims = img.faces.map { dot($0.embedding, target) }
            let j = argmax(sims)
            return RefFace(item: img.item, faceIndex: j, face: img.faces[j], similarity: sims[j])
        }
    }

    /// Tìm những người có thể là "người cần tìm" trong các ảnh mẫu, xếp theo độ tin cậy.
    ///
    /// Điểm của một ứng viên = mức độ xuất hiện nhất quán qua các ảnh mẫu + độ nổi bật (mặt to).
    /// `usable` = số ảnh mẫu có ít nhất một khuôn mặt.
    public static func findIdentities(references: [ImageItem], faces: [String: [FaceRecord]], anchor: String? = nil,
                                      maxIdentities: Int? = nil) throws
        -> (identities: [Identity], noFace: [ImageItem], usable: Int) {
        var images: [RefImage] = [], noFace: [ImageItem] = []
        for item in references {
            let fs = faces[item.key] ?? []
            if fs.isEmpty { noFace.append(item); continue }
            let area = fs.map { $0.width * $0.height }
            let largest = area.max()!
            images.append(RefImage(item: item, faces: fs, prominence: area.map { $0 / largest }))
        }
        if images.isEmpty { return ([], noFace, 0) }
        let n = images.count
        let limit = maxIdentities ?? (n == 1 ? 12 : 8)

        var candidates: [(score: Double, i: Int, j: Int)] = []
        if let anchor {
            guard let i = images.firstIndex(where: { $0.item.name == anchor || $0.item.key == anchor }) else {
                throw ScorerError.anchorNotFound(anchor)
            }
            candidates = [(1.0, i, argmax(images[i].prominence))]
        } else {
            for (i, img) in images.enumerated() {
                for j in img.faces.indices {
                    var score = Double(img.prominence[j])
                    if n > 1 {
                        var consistency = 0.0, prominent = Double(img.prominence[j])
                        for (k, other) in images.enumerated() where k != i {
                            let sims = other.faces.map { dot($0.embedding, img.faces[j].embedding) }
                            let m = argmax(sims)
                            consistency += Double(sims[m])
                            if sims[m] >= minRefSimilarity { prominent += Double(other.prominence[m]) }
                        }
                        score = consistency / Double(n - 1) + prominence * prominent / Double(n)
                    }
                    candidates.append((score, i, j))
                }
            }
            candidates.sort { a, b in  // giảm dần theo (điểm, ảnh, mặt), như sort(reverse=True) trên tuple
                a.score != b.score ? a.score > b.score : a.i != b.i ? a.i > b.i : a.j > b.j
            }
        }

        var identities: [Identity] = []
        for c in candidates {
            // 1 ảnh mẫu: chỉ xét thêm những mặt to gần bằng mặt lớn nhất
            if n == 1, !identities.isEmpty, images[c.i].prominence[c.j] < 0.4 { break }
            let members = refine(images, target: images[c.i].faces[c.j].embedding)
            let cover = Set(members.filter { $0.similarity >= minRefSimilarity }.map { "\($0.item.key)#\($0.faceIndex)" })
            if identities.contains(where: { cover.intersection($0.cover).count * 2 >= max(cover.count, 1) }) {
                continue  // trùng với một người đã có
            }
            identities.append(Identity(members: members, cover: cover, score: c.score))
            if identities.count >= limit || anchor != nil { break }
        }
        return (identities, noFace, n)
    }

    /// Mơ hồ khi người thứ hai gần như ngang người thứ nhất: cùng xuất hiện trong phần lớn ảnh mẫu và điểm chỉ kém
    /// một chút (vd. ảnh nhóm chụp liên tiếp), hoặc 1 ảnh mẫu có 2 mặt to gần bằng nhau.
    public static func isAmbiguous(_ identities: [Identity], usableReferences n: Int, margin: Double = 0.15) -> Bool {
        guard identities.count >= 2 else { return false }
        let a = identities[0], b = identities[1]
        if n == 1 { return b.score >= 0.5 }  // mặt thứ hai có diện tích >= 50% mặt lớn nhất
        let need = max(2, Int((0.6 * Double(n)).rounded(.up)))
        return b.cover.count >= need && b.score >= a.score - margin
    }

    /// Các ảnh mẫu gần như giống hệt nhau (cùng một loạt chụp)? Khi đó nên thêm ảnh ở cảnh/góc khác.
    public static func referencesNearlyIdentical(_ refs: [RefFace]) -> Bool {
        guard refs.count >= 2 else { return false }
        var sum = 0.0, count = 0
        for i in refs.indices {
            for j in refs.indices where i != j {
                sum += Double(dot(refs[i].face.embedding, refs[j].face.embedding))
                count += 1
            }
        }
        return sum / Double(count) >= 0.85
    }

    /// Điểm khuôn mặt = độ giống (cosine) với "tâm" các khuôn mặt mẫu; điểm ảnh = khuôn mặt cao nhất.
    static func score(_ items: [ImageItem], _ faces: [String: [FaceRecord]], target: [Float]) -> (scores: [ItemScore], faceScores: [Float]) {
        var out: [ItemScore] = [], all: [Float] = []
        out.reserveCapacity(items.count)
        for item in items {
            let fs = faces[item.key] ?? []
            if fs.isEmpty {
                out.append(ItemScore(item: item, score: -1, face: nil, faceCount: 0))
                continue
            }
            let sims = fs.map { dot($0.embedding, target) }
            all += sims
            let j = argmax(sims)
            out.append(ItemScore(item: item, score: sims[j], face: fs[j], faceCount: fs.count))
        }
        return (out, all)
    }

    /// Cận dưới vùng "Cần kiểm tra", tự điều chỉnh theo mức giống của *người khác* trong chính bộ ảnh này.
    ///
    /// Gần như mọi khuôn mặt trong bộ ảnh là người khác, nên trung bình + 3 độ lệch chuẩn ước lượng mức điểm cao nhất
    /// mà người lạ thường đạt. Trẻ em cùng lớp trông giống nhau → cận dưới cao (ít ảnh rác); người lớn → cận dưới
    /// thấp (giữ lại ảnh khó).
    public static func autoReviewThreshold(faceScores: [Float], threshold: Double) -> Double {
        if faceScores.count < 300 { return min(0.40, threshold) }
        let n = Double(faceScores.count)
        let mean = faceScores.reduce(0.0) { $0 + Double($1) } / n
        let variance = faceScores.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
        return min(threshold, max(0.40, mean + 3 * variance.squareRoot()))
    }

    /// Chấm điểm toàn bộ ảnh theo các khuôn mặt mẫu; tuỳ chọn tự mở rộng (dùng thêm ảnh khớp chắc chắn làm mẫu
    /// rồi chấm lại).
    public static func search(references: [RefFace], items: [ImageItem], faces: [String: [FaceRecord]],
                              options: SearchOptions = SearchOptions()) -> SearchResult {
        search(embeddings: references.map(\.face.embedding), items: items, faces: faces, options: options)
    }

    /// Như trên, với vân mặt mẫu đã lưu sẵn (người đã tạo trong app).
    public static func search(embeddings: [[Float]], items: [ImageItem], faces: [String: [FaceRecord]],
                              options: SearchOptions = SearchOptions(), marks: SearchMarks = SearchMarks()) -> SearchResult {
        // ảnh ✓: khuôn mặt đã khớp trong ảnh đó thành ảnh mẫu bổ sung (thứ tự cố định để kết quả lặp lại được)
        let base = embeddings + marks.confirmed.keys.sorted().compactMap { marks.confirmed[$0] }
        var (scores, faceScores) = score(items, faces, target: centroid(base))
        var added = 0
        if options.expand {
            // sắp xếp ổn định theo điểm giảm dần, như sorted(key=-score) của Python
            let confident = scores.enumerated()
                .filter { Double($0.element.score) >= options.expandThreshold && !marks.rejected.contains($0.element.item.key) }
                .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
                .prefix(options.expandLimit)
                .compactMap { $0.element.face?.embedding }
            if !confident.isEmpty {
                (scores, faceScores) = score(items, faces, target: centroid(base + confident))
                added = confident.count
            }
        }
        let reviewBase = options.review ?? autoReviewThreshold(faceScores: faceScores, threshold: 1)
        let review = min(options.threshold, reviewBase)
        let sorted = scores.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        return SearchResult(scores: sorted, threshold: options.threshold, review: review, reviewBase: reviewBase, expandedBy: added,
                            confirmed: Set(marks.confirmed.keys), rejected: marks.rejected)
    }
}
