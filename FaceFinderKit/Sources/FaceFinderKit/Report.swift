import Foundation

public enum Report {
    public static let reviewDirectory = "Cần kiểm tra"
    public static let reportDirectory = "_báo cáo"
    public static let csvName = "ket_qua.csv"

    /// `ket_qua.csv` cùng định dạng với CLI Python (UTF-8 có BOM để Excel mở đúng tiếng Việt, xuống dòng CRLF).
    public static func csv(_ result: SearchResult, errors: [String: String]) -> Data {
        var text = "\u{FEFF}" + row(["tên file", "điểm", "kết quả", "số khuôn mặt", "nguồn", "lỗi"])
        for s in result.scores {
            let error = errors[s.item.key]
            let status = error != nil ? "Lỗi đọc ảnh" : result.status(of: s).rawValue
            text += row([s.item.name, String(format: "%.3f", s.score), status, String(s.faceCount), s.item.key, error ?? ""])
        }
        return Data(text.utf8)
    }

    private static func row(_ fields: [String]) -> String {
        fields.map { f in
            f.contains(where: { ",\"\r\n".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: ",") + "\r\n"
    }
}
