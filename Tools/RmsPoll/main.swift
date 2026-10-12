import Foundation

// rms-poll <serviceId> <minutes> <outFile>
// Polls the RMS "latest segments" endpoint every 30 seconds and appends one JSON line per poll:
// {"polledAt": <unix seconds>, "status": <http>, "body": <raw response as a string>}
let a = CommandLine.arguments
guard a.count >= 4, let minutes = Double(a[2]) else { print("usage: rms-poll <serviceId> <minutes> <outFile>"); exit(2) }
let url = URL(string: "https://rms.api.bbc.co.uk/v2/services/\(a[1])/segments/latest?limit=10")!
let out = URL(fileURLWithPath: a[3])
FileManager.default.createFile(atPath: out.path, contents: nil, attributes: nil)
let handle = try FileHandle(forWritingTo: out)
let end = Date().addingTimeInterval(minutes * 60)
var backoff = 30.0
while Date() < end {
    var status = 0, body = ""
    do {
        let (d, r) = try await URLSession.shared.data(from: url)
        status = (r as? HTTPURLResponse)?.statusCode ?? 0
        body = String(decoding: d, as: UTF8.self)
        backoff = 30
    } catch { body = "error: \(error.localizedDescription)"; backoff = min(backoff * 2, 300) }
    let line: [String: Any] = ["polledAt": Date().timeIntervalSince1970, "status": status, "body": body]
    handle.write(try JSONSerialization.data(withJSONObject: line))
    handle.write(Data("\n".utf8))
    try await Task.sleep(for: .seconds(backoff))
}
print("done")
