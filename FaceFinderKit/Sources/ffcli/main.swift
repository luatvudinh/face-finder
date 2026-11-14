import FaceFinderKit
import Foundation

func log(_ message: String = "") {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    log("Lỗi: \(message)")
    exit(1)
}

/// Đọc tham số dạng `--tên giá_trị...` (một tên có thể nhận nhiều giá trị) và vài tên tắt kiểu `-r`.
struct Arguments {
    private static let aliases = ["-r": "ref", "-i": "input", "-o": "output", "-t": "threshold", "-y": "yes"]
    private var values: [String: [String]] = [:]

    init(_ args: [String]) {
        var current: String?
        for a in args {
            if let name = Self.aliases[a] ?? (a.hasPrefix("--") ? String(a.dropFirst(2)) : nil) {
                current = name
                values[name, default: []] += []
            } else if let current {
                values[current, default: []].append(a)
            } else {
                fail("tham số không hiểu: \(a)")
            }
        }
    }

    func has(_ name: String) -> Bool { values[name] != nil }
    func list(_ name: String) -> [String] { values[name] ?? [] }
    func string(_ name: String) -> String? { values[name]?.first }
    func string(_ name: String, default def: String) -> String { string(name) ?? def }
    func int(_ name: String) -> Int? {
        guard let s = string(name) else { return nil }
        guard let v = Int(s) else { fail("--\(name) phải là số nguyên") }
        return v
    }
    func int(_ name: String, default def: Int) -> Int { int(name) ?? def }
    func double(_ name: String) -> Double? {
        guard let s = string(name) else { return nil }
        guard let v = Double(s) else { fail("--\(name) phải là số") }
        return v
    }
    func url(_ name: String, default def: String) -> URL {
        URL(fileURLWithPath: (string(name, default: def) as NSString).expandingTildeInPath)
    }
    /// Thư mục chứa model: `--models`, không thì `./models`, không nữa thì thư mục `models` gần nhất phía trên file
    /// chạy (để gọi ffcli từ đâu cũng được, không chỉ từ gốc dự án).
    func modelsURL() -> URL {
        if has("models") { return url("models", default: "models") }
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: "models")]
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("models"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("YuNet.mlpackage").path)
            || fm.fileExists(atPath: $0.appendingPathComponent("YuNet.mlmodelc").path) } ?? candidates[0]
    }

    func device(_ name: String, default def: ComputeDevice) -> ComputeDevice {
        guard let s = string(name) else { return def }
        guard let d = ComputeDevice(rawValue: s) else { fail("--\(name) phải là một trong: auto, gpu, ne, cpu") }
        return d
    }
}

let usage = """
ffcli — công cụ dòng lệnh của FaceFinderKit (đo tốc độ, so với CLI Python)

  ffcli find -r ẢNH_MẪU... -i NGUỒN... -o THƯ_MỤC [tuỳ chọn]
      Tìm ảnh có mặt người trong ảnh mẫu; ghi THƯ_MỤC/_báo cáo/ket_qua.csv cùng định dạng với findface.
      Chưa chép ảnh ra thư mục kết quả (việc đó thuộc về app, PLAN.md mục 4.1).
        -t, --threshold 0.475     điểm tối thiểu để coi là khớp
        --review X                cận dưới "Cần kiểm tra" (mặc định: tự điều chỉnh)
        --no-expand               tắt bước tự mở rộng ảnh mẫu
        --expand-threshold 0.60
        --pick N                  ảnh mẫu có nhiều người: chọn người số N
        --anchor TÊN_FILE         ảnh mẫu dùng làm chuẩn (lấy khuôn mặt lớn nhất)
        -y, --yes                 ảnh mẫu mơ hồ thì chọn người số 1
        --since THỜI_GIAN         chỉ quét file sửa từ: today, 3d, 12h hoặc YYYY-MM-DD
        --device gpu|ne|cpu|auto  thiết bị chạy ArcFace (mặc định gpu)
        --detector-device ...     thiết bị chạy YuNet (mặc định như --device)
        --jpeg turbo|imageio|thumbnail   bộ giải mã JPEG (mặc định turbo = libjpeg-turbo, trùng CLI)
        --workers N               số luồng giải mã + phát hiện mặt
        --models THƯ_MỤC          nơi có YuNet.mlpackage, ArcFaceR50.mlpackage (mặc định ./models, hoặc models/ ở gốc dự án)
        --index FILE              file chỉ mục SQLite;  --no-cache: không dùng chỉ mục

  ffcli pixels -i NGUỒN... [--golden golden] [--jpeg turbo|imageio|thumbnail] [--limit N]
      Đọc lại file gốc của các ảnh trong golden data, so pixel và vân mặt với CLI (chọn cách giải mã/thu nhỏ).

  ffcli phase0 [--golden golden] [--models models] [--devices gpu,ne,cpu] [--limit N]
      So ArcFace và YuNet bản Core ML với đáp án mẫu của CLI (tools/export_golden.py).
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { print(usage); exit(0) }
do {
    switch command {
    case "find": try await Find(Arguments(Array(argv.dropFirst()))).run()
    case "pixels": try await Pixels(Arguments(Array(argv.dropFirst()))).run()
    case "phase0": try await Phase0(Arguments(Array(argv.dropFirst()))).run()
    case "-h", "--help", "help": print(usage)
    default: fail("không có lệnh '\(command)'\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
