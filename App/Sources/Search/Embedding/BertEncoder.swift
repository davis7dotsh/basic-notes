import Accelerate
import Foundation

/// Minimal BERT encoder forward pass on Accelerate (sgemm runs on the AMX units).
/// Weights are memory-mapped from safetensors; sequences in a batch are packed (no padding).
/// Thread-safe: weights are read-only and all scratch buffers are per call.
nonisolated final class BertEncoder: @unchecked Sendable {
    struct Config: Sendable {
        var hidden: Int, layers: Int, heads: Int, intermediate: Int, eps: Float, maxPositions: Int
    }

    private struct Layer {
        let qW, qB, kW, kB, vW, vB, oW, oB, ln1G, ln1B, iW, iB, o2W, o2B, ln2G, ln2B: UnsafePointer<Float>
    }

    let config: Config
    private let weights: SafeTensors
    private let wordEmb, posEmb, typeEmb, embLnG, embLnB: UnsafePointer<Float>
    private let layers: [Layer]

    init(directory: URL) throws {
        let cfgData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let c = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let hidden = c["hidden_size"] as? Int, let nLayers = c["num_hidden_layers"] as? Int,
              let heads = c["num_attention_heads"] as? Int, let inter = c["intermediate_size"] as? Int
        else { throw SafeTensors.LoadError.format("bad config.json") }
        config = Config(
            hidden: hidden, layers: nLayers, heads: heads, intermediate: inter,
            eps: Float((c["layer_norm_eps"] as? Double) ?? 1e-12),
            maxPositions: (c["max_position_embeddings"] as? Int) ?? 512)
        let w = try SafeTensors(url: directory.appendingPathComponent("model.safetensors"))
        weights = w
        wordEmb = try w.floats("embeddings.word_embeddings.weight")
        posEmb = try w.floats("embeddings.position_embeddings.weight")
        typeEmb = try w.floats("embeddings.token_type_embeddings.weight")
        embLnG = try w.floats("embeddings.LayerNorm.weight")
        embLnB = try w.floats("embeddings.LayerNorm.bias")
        guard w.shape("embeddings.word_embeddings.weight")?.last == hidden else {
            throw SafeTensors.LoadError.format("embedding shape mismatch")
        }
        layers = try (0..<nLayers).map { i in
            let p = "encoder.layer.\(i)."
            func t(_ s: String) throws -> UnsafePointer<Float> { try w.floats(p + s) }
            return Layer(
                qW: try t("attention.self.query.weight"), qB: try t("attention.self.query.bias"),
                kW: try t("attention.self.key.weight"), kB: try t("attention.self.key.bias"),
                vW: try t("attention.self.value.weight"), vB: try t("attention.self.value.bias"),
                oW: try t("attention.output.dense.weight"), oB: try t("attention.output.dense.bias"),
                ln1G: try t("attention.output.LayerNorm.weight"), ln1B: try t("attention.output.LayerNorm.bias"),
                iW: try t("intermediate.dense.weight"), iB: try t("intermediate.dense.bias"),
                o2W: try t("output.dense.weight"), o2B: try t("output.dense.bias"),
                ln2G: try t("output.LayerNorm.weight"), ln2B: try t("output.LayerNorm.bias"))
        }
    }

    enum Pooling: Sendable { case cls, mean }

    /// Returns one L2-normalized vector per sequence.
    func embed(_ batch: [[Int32]], pooling: Pooling) -> [[Float]] {
        let seqs = batch.map { Array($0.prefix(config.maxPositions)) }.filter { !$0.isEmpty }
        guard seqs.count == batch.count else { return batch.map { _ in [Float](repeating: 0, count: config.hidden) } }
        let H = config.hidden, I = config.intermediate, nH = config.heads, dH = H / nH
        let T = seqs.reduce(0) { $0 + $1.count }
        let maxL = seqs.map(\.count).max() ?? 0
        var offsets: [Int] = []
        var o = 0
        for s in seqs { offsets.append(o); o += s.count }

        let x = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let q = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let k = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let v = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let ctx = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: T * H)
        let inter = UnsafeMutablePointer<Float>.allocate(capacity: T * I)
        let scores = UnsafeMutablePointer<Float>.allocate(capacity: maxL * maxL)
        defer { [x, q, k, v, ctx, tmp, inter, scores].forEach { $0.deallocate() } }

        // Embeddings
        for (si, s) in seqs.enumerated() {
            for (p, id) in s.enumerated() {
                let row = x + (offsets[si] + p) * H
                let tok = Int(id) >= 0 ? Int(id) : 0
                vDSP_vadd(wordEmb + tok * H, 1, posEmb + p * H, 1, row, 1, vDSP_Length(H))
                vDSP_vadd(row, 1, typeEmb, 1, row, 1, vDSP_Length(H))
            }
        }
        layerNorm(x, rows: T, cols: H, g: embLnG, b: embLnB)

        let scale = 1 / Float(dH).squareRoot()
        for L in layers {
            linear(x, rows: T, inDim: H, w: L.qW, b: L.qB, outDim: H, out: q)
            linear(x, rows: T, inDim: H, w: L.kW, b: L.kB, outDim: H, out: k)
            linear(x, rows: T, inDim: H, w: L.vW, b: L.vB, outDim: H, out: v)
            for (si, s) in seqs.enumerated() {
                let n = s.count, off = offsets[si] * H
                for h in 0..<nH {
                    let col = h * dH
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(n), Int32(dH),
                                scale, q + off + col, Int32(H), k + off + col, Int32(H), 0, scores, Int32(n))
                    for r in 0..<n { softmax(scores + r * n, n) }
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(dH), Int32(n),
                                1, scores, Int32(n), v + off + col, Int32(H), 0, ctx + off + col, Int32(H))
                }
            }
            linear(ctx, rows: T, inDim: H, w: L.oW, b: L.oB, outDim: H, out: tmp)
            vDSP_vadd(x, 1, tmp, 1, x, 1, vDSP_Length(T * H))
            layerNorm(x, rows: T, cols: H, g: L.ln1G, b: L.ln1B)

            linear(x, rows: T, inDim: H, w: L.iW, b: L.iB, outDim: I, out: inter)
            gelu(inter, T * I)
            linear(inter, rows: T, inDim: I, w: L.o2W, b: L.o2B, outDim: H, out: tmp)
            vDSP_vadd(x, 1, tmp, 1, x, 1, vDSP_Length(T * H))
            layerNorm(x, rows: T, cols: H, g: L.ln2G, b: L.ln2B)
        }

        return seqs.indices.map { si in
            var out = [Float](repeating: 0, count: H)
            let start = x + offsets[si] * H
            switch pooling {
            case .cls:
                out = Array(UnsafeBufferPointer(start: start, count: H))
            case .mean:
                let n = seqs[si].count
                for r in 0..<n { vDSP_vadd(out, 1, start + r * H, 1, &out, 1, vDSP_Length(H)) }
                var inv = 1 / Float(n)
                vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(H))
            }
            var norm: Float = 0
            vDSP_svesq(out, 1, &norm, vDSP_Length(H))
            var inv = 1 / max(norm.squareRoot(), 1e-12)
            vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(H))
            return out
        }
    }

    // out[rows, outDim] = x[rows, inDim] * W^T + b   (W is PyTorch [outDim, inDim])
    private func linear(_ x: UnsafePointer<Float>, rows: Int, inDim: Int, w: UnsafePointer<Float>, b: UnsafePointer<Float>,
                        outDim: Int, out: UnsafeMutablePointer<Float>) {
        for r in 0..<rows { memcpy(out + r * outDim, b, outDim * 4) }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outDim), Int32(inDim),
                    1, x, Int32(inDim), w, Int32(inDim), 1, out, Int32(outDim))
    }

    private func layerNorm(_ x: UnsafeMutablePointer<Float>, rows: Int, cols: Int, g: UnsafePointer<Float>, b: UnsafePointer<Float>) {
        let n = vDSP_Length(cols)
        for r in 0..<rows {
            let row = x + r * cols
            var mean: Float = 0, meanSq: Float = 0
            vDSP_meanv(row, 1, &mean, n)
            vDSP_measqv(row, 1, &meanSq, n)
            var s = 1 / max(meanSq - mean * mean + config.eps, 1e-12).squareRoot()
            var shift = -mean * s
            vDSP_vsmsa(row, 1, &s, &shift, row, 1, n)
            vDSP_vma(row, 1, g, 1, b, 1, row, 1, n)
        }
    }

    private func softmax(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        var mx: Float = 0
        vDSP_maxv(p, 1, &mx, vDSP_Length(n))
        var neg = -mx
        vDSP_vsadd(p, 1, &neg, p, 1, vDSP_Length(n))
        var cnt = Int32(n)
        vvexpf(p, p, &cnt)
        var sum: Float = 0
        vDSP_sve(p, 1, &sum, vDSP_Length(n))
        var inv = 1 / sum
        vDSP_vsmul(p, 1, &inv, p, 1, vDSP_Length(n))
    }

    /// GELU, tanh form (max abs deviation from the erf form ~5e-4; ~3x faster), vectorized in cache-sized blocks.
    private func gelu(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        let block = 4096
        let u = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { u.deallocate() }
        var c1: Float = 0.044715, one: Float = 1, c2 = (2 / Float.pi).squareRoot(), half: Float = 0.5
        var start = 0
        while start < n {
            let m = min(block, n - start), x = p + start, len = vDSP_Length(m)
            vDSP_vsq(x, 1, u, 1, len)
            vDSP_vsmsa(u, 1, &c1, &one, u, 1, len)
            vDSP_vmul(u, 1, x, 1, u, 1, len)
            vDSP_vsmul(u, 1, &c2, u, 1, len)
            var cnt = Int32(m)
            vvtanhf(u, u, &cnt)
            vDSP_vsmsa(u, 1, &half, &half, u, 1, len)
            vDSP_vmul(x, 1, u, 1, x, 1, len)
            start += m
        }
    }
}
