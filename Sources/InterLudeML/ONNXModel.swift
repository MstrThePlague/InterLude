import Foundation
import COnnxRuntime

/// A model with one float input and one float output, run with ONNX Runtime's C API on the CPU.
/// Sessions are safe to run from several threads at once, as ONNX Runtime documents.
final class ONNXModel: @unchecked Sendable {
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memory: OpaquePointer?
    private let inputName: String
    private let outputName: String

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "ONNX Runtime: \(message)" }
    }

    init(path: String, input: String, output: String, threads: Int32 = 2) throws {
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw Failure(message: "this build of ONNX Runtime doesn't offer API version \(ORT_API_VERSION)")
        }
        self.api = api; inputName = input; outputName = output
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "interlude", &env))
        var options: OpaquePointer?
        try check(api.pointee.CreateSessionOptions(&options))
        defer { api.pointee.ReleaseSessionOptions(options) }
        try check(api.pointee.SetIntraOpNumThreads(options, threads))
        try check(api.pointee.CreateSession(env, path, options, &session))
        try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
    }

    deinit {
        api.pointee.ReleaseMemoryInfo(memory)
        api.pointee.ReleaseSession(session)
        api.pointee.ReleaseEnv(env)
    }

    /// Runs the model on a one-dimensional input. Returns the output's values and shape.
    func run(_ input: [Float]) throws -> (values: [Float], shape: [Int]) {
        var data = input
        var shape: [Int64] = [Int64(input.count)]
        var inValue: OpaquePointer?
        try data.withUnsafeMutableBytes { bytes in
            try check(api.pointee.CreateTensorWithDataAsOrtValue(memory, bytes.baseAddress, bytes.count, &shape, 1,
                                                                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inValue))
        }
        defer { api.pointee.ReleaseValue(inValue) }
        var outValue: OpaquePointer?
        try inputName.withCString { inName in
            try outputName.withCString { outName in
                var inNames: [UnsafePointer<CChar>?] = [inName], outNames: [UnsafePointer<CChar>?] = [outName]
                var inputs: [OpaquePointer?] = [inValue]
                try check(api.pointee.Run(session, nil, &inNames, &inputs, 1, &outNames, 1, &outValue))
            }
        }
        defer { api.pointee.ReleaseValue(outValue) }
        var info: OpaquePointer?
        try check(api.pointee.GetTensorTypeAndShape(outValue, &info))
        defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
        var rank = 0
        try check(api.pointee.GetDimensionsCount(info, &rank))
        var dims = [Int64](repeating: 0, count: rank)
        try check(api.pointee.GetDimensions(info, &dims, rank))
        let count = dims.reduce(1) { $0 * Int($1) }
        var raw: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(outValue, &raw))
        guard let raw else { throw Failure(message: "no output data") }
        let values = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count))
        return (values, dims.map(Int.init))
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        defer { api.pointee.ReleaseStatus(status) }
        throw Failure(message: api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error")
    }
}
