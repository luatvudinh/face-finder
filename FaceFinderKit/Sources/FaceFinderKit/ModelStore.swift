import CoreML
import Foundation

/// Thiết bị tính cho Core ML (mục Cài đặt của app).
public enum ComputeDevice: String, Sendable, CaseIterable {
    case auto, gpu, neuralEngine = "ne", cpu

    public var units: MLComputeUnits {
        switch self {
        case .auto: return .all
        case .gpu: return .cpuAndGPU
        case .neuralEngine: return .cpuAndNeuralEngine
        case .cpu: return .cpuOnly
        }
    }
}

public enum ModelError: Error, CustomStringConvertible {
    case notFound(URL)
    case badOutput(String)

    public var description: String {
        switch self {
        case .notFound(let url): return "Không tìm thấy model: \(url.path). Chạy tools/convert_models.py trước."
        case .badOutput(let what): return "Model trả về dữ liệu không đúng định dạng: \(what)"
        }
    }
}

public enum ModelStore {
    /// Nạp model từ `.mlmodelc` (đã biên dịch, như trong bundle của app) hoặc `.mlpackage` (biên dịch một lần rồi
    /// lưu vào thư mục cache; lần sau nạp lại ngay).
    public static func load(_ url: URL, device: ComputeDevice) async throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.notFound(url) }
        let config = MLModelConfiguration()
        config.computeUnits = device.units
        let compiled = url.pathExtension == "mlmodelc" ? url : try await compiledURL(for: url)
        return try MLModel(contentsOf: compiled, configuration: config)
    }

    private static func compiledURL(for package: URL) async throws -> URL {
        let fm = FileManager.default
        // Khoá cache = tên + thời điểm sửa file trọng số, để chuyển model lại thì biên dịch lại.
        var stamp = (try? fm.attributesOfItem(atPath: package.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let e = fm.enumerator(at: package, includingPropertiesForKeys: [.contentModificationDateKey]) {
            while let f = e.nextObject() as? URL {
                let t = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                stamp = max(stamp, t?.timeIntervalSince1970 ?? 0)
            }
        }
        let cacheDir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FaceFinder/models", isDirectory: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let name = package.deletingPathExtension().lastPathComponent
        let dest = cacheDir.appendingPathComponent("\(name)-\(Int(stamp)).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) { return dest }
        let tmp = try await MLModel.compileModel(at: package)
        for old in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(name + "-") {
            try? fm.removeItem(at: old)
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}
