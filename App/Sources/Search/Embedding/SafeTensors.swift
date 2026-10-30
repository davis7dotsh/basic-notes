import Foundation

/// Read-only, memory-mapped safetensors file. F32 tensors are used in place (clean, file-backed pages);
/// F16/BF16 tensors are widened into owned buffers.
nonisolated final class SafeTensors: @unchecked Sendable {
    enum LoadError: Error { case open(String), format(String), missing(String) }

    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let dataStart: Int
    private var tensors: [String: (dtype: String, shape: [Int], start: Int, end: Int)] = [:]
    private var owned: [UnsafeMutablePointer<Float>] = []

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw LoadError.open(url.path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 8 else { throw LoadError.format("empty file") }
        length = Int(st.st_size)
        guard let p = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw LoadError.open("mmap failed")
        }
        base = p
        let headerLen = Int(p.loadUnaligned(as: UInt64.self).littleEndian)
        guard headerLen > 0, 8 + headerLen <= length else { munmap(p, length); throw LoadError.format("bad header length") }
        dataStart = 8 + headerLen
        let header = Data(bytes: p + 8, count: headerLen)
        guard let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            munmap(p, length); throw LoadError.format("bad header json")
        }
        for (name, value) in json where name != "__metadata__" {
            guard let d = value as? [String: Any], let dtype = d["dtype"] as? String,
                  let shape = d["shape"] as? [Int], let offs = d["data_offsets"] as? [Int], offs.count == 2,
                  dataStart + offs[1] <= length, offs[0] <= offs[1] else { continue }
            // Normalize names like "bert.encoder..." / "model.encoder..." to "encoder...".
            var key = name
            for prefix in ["bert.", "model."] where key.hasPrefix(prefix) { key = String(key.dropFirst(prefix.count)) }
            tensors[key] = (dtype, shape, dataStart + offs[0], dataStart + offs[1])
        }
    }

    deinit {
        owned.forEach { $0.deallocate() }
        munmap(base, length)
    }

    func shape(_ name: String) -> [Int]? { tensors[name]?.shape }

    /// Float32 view of a tensor (zero-copy when F32 and aligned).
    func floats(_ name: String) throws -> UnsafePointer<Float> {
        guard let t = tensors[name] else { throw LoadError.missing(name) }
        let count = t.shape.reduce(1, *)
        let src = base + t.start
        switch t.dtype {
        case "F32":
            guard t.end - t.start == count * 4 else { throw LoadError.format("size mismatch \(name)") }
            if Int(bitPattern: src) % MemoryLayout<Float>.alignment == 0 {
                return UnsafePointer(src.assumingMemoryBound(to: Float.self))
            }
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
            memcpy(buf, src, count * 4)
            owned.append(buf)
            return UnsafePointer(buf)
        case "F16", "BF16":
            guard t.end - t.start == count * 2 else { throw LoadError.format("size mismatch \(name)") }
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: count)
            for i in 0..<count {
                let bits = src.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
                buf[i] = t.dtype == "F16" ? Float(Float16(bitPattern: bits)) : Float(bitPattern: UInt32(bits) << 16)
            }
            owned.append(buf)
            return UnsafePointer(buf)
        default:
            throw LoadError.format("unsupported dtype \(t.dtype) for \(name)")
        }
    }
}
