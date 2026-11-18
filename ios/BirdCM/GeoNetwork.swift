import Foundation
import Accelerate

/// Fixed BirdNET+ v3.0.4 FP32 graph, exported with tools/export_geo.py. Weights stay in the public ONNX.
/// Deliberately CPU/Accelerate: no added runtime and no republished converted model required.
final class GeoNetwork {
    struct Tensor { var values: [Float]; var rows: Int; var cols: Int }
    struct Initial: Decodable { var offset: Int?; var count: Int?; var shape: [Int]; var values: [Float]? }
    struct Node: Decodable { var op: String; var inputs: [String]; var outputs: [String]; var epsilon: Float }
    struct Graph: Decodable { var initial: [String:Initial]; var nodes: [Node] }
    let graph: Graph
    let constants: [String:Tensor]
    init(weights: URL, graphURL: URL) throws {
        graph = try JSONDecoder().decode(Graph.self, from: Data(contentsOf:graphURL))
        let data = try Data(contentsOf:weights,options:.mappedIfSafe)
        var c: [String:Tensor] = [:]
        for (key,v) in graph.initial {
            let values: [Float]
            if let offset = v.offset, let count = v.count {
                guard offset >= 0, offset + count*4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                values = data.withUnsafeBytes { b in (0..<count).map { Float(bitPattern:b.loadUnaligned(fromByteOffset:offset+$0*4,as:UInt32.self)) } }
            } else { values = v.values! }
            c[key] = Tensor(values:values,rows:v.shape.count == 2 ? v.shape[0] : 1,cols:v.shape.last ?? 1)
        }
        constants = c
    }
    func predict(_ points: [[Float]]) throws -> [[Float]] {
        guard !points.isEmpty, points.allSatisfy({ $0.count == 3 }) else { return [] }
        var env = constants
        env["input"] = Tensor(values:points.flatMap{$0},rows:points.count,cols:3)
        for n in graph.nodes {
            let args = try n.inputs.map { name -> Tensor in
                guard let t = env[name] else { throw CocoaError(.fileReadCorruptFile) }; return t
            }
            let a = args[0]
            var result: Tensor
            switch n.op {
            case "Gather":
                let index = Int(args[1].values[0])
                result = Tensor(values:(0..<a.rows).map{ a.values[$0*a.cols+index] },rows:a.rows,cols:1)
            case "Unsqueeze": result = a
            case "Concat":
                let cols = args.reduce(0){$0+$1.cols}
                var v = [Float](); v.reserveCapacity(a.rows*cols)
                for r in 0..<a.rows { for t in args { v.append(contentsOf:t.values[r*t.cols..<(r+1)*t.cols]) } }
                result = Tensor(values:v,rows:a.rows,cols:cols)
            case "Gemm":
                let w = args[1], b = args[2], cols = w.rows
                var v = [Float](repeating:0,count:a.rows*cols)
                cblas_sgemm(CblasRowMajor,CblasNoTrans,CblasTrans,Int32(a.rows),Int32(cols),Int32(a.cols),1,a.values,Int32(a.cols),w.values,Int32(w.cols),0,&v,Int32(cols))
                for i in v.indices { v[i] += b.values[i%cols] }
                result = Tensor(values:v,rows:a.rows,cols:cols)
            case "LayerNormalization":
                var v = a.values
                for r in 0..<a.rows {
                    let start = r*a.cols
                    let mean = a.values[start..<start+a.cols].reduce(0,+)/Float(a.cols)
                    let variance = a.values[start..<start+a.cols].reduce(Float(0)){ $0+($1-mean)*($1-mean) }/Float(a.cols)
                    let inv = 1/sqrt(variance+n.epsilon)
                    for j in 0..<a.cols { v[start+j] = (a.values[start+j]-mean)*inv*args[1].values[j]+args[2].values[j] }
                }
                result = Tensor(values:v,rows:a.rows,cols:a.cols)
            case "Split":
                let half = a.cols/2
                for k in 0..<2 {
                    var v = [Float](); v.reserveCapacity(a.rows*half)
                    for r in 0..<a.rows { v.append(contentsOf:a.values[r*a.cols+k*half..<r*a.cols+(k+1)*half]) }
                    env[n.outputs[k]] = Tensor(values:v,rows:a.rows,cols:half)
                }
                continue
            case "Mul", "Add", "Sub", "Div":
                let b = args[1], rows = max(a.rows,b.rows), cols = max(a.cols,b.cols)
                var v = [Float](repeating:0,count:rows*cols)
                for r in 0..<rows { for j in 0..<cols {
                    let x = a.values[(a.rows==1 ? 0:r)*a.cols+(a.cols==1 ? 0:j)]
                    let y = b.values[(b.rows==1 ? 0:r)*b.cols+(b.cols==1 ? 0:j)]
                    switch n.op { case "Mul":v[r*cols+j]=x*y; case "Add":v[r*cols+j]=x+y; case "Sub":v[r*cols+j]=x-y; default:v[r*cols+j]=x/y }
                } }
                result = Tensor(values:v,rows:rows,cols:cols)
            case "Sin", "Cos", "Erf", "Tanh", "Sigmoid":
                result = Tensor(values:a.values.map { x in
                    switch n.op { case "Sin":return sin(x); case "Cos":return cos(x); case "Erf":return erf(x); case "Tanh":return tanh(x); default:return 1/(1+exp(-x)) }
                },rows:a.rows,cols:a.cols)
            default: throw CocoaError(.fileReadCorruptFile)
            }
            env[n.outputs[0]] = result
            // Keep only constants and still-needed activations (the graph is small, release at call end).
        }
        guard let out = env["probabilities"] else { throw CocoaError(.fileReadCorruptFile) }
        return (0..<out.rows).map { Array(out.values[$0*out.cols..<($0+1)*out.cols]) }
    }
}
