import Foundation

struct BenchmarkMeasurement: Encodable {
    let name: String
    let loops: Int
    let elapsed_ns: UInt64
    let checksum: String
    let raw_bytes: Int?
    var accumulated_checksum: String? = nil

    func report() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        print("measurement " + String(decoding: data, as: UTF8.self))
    }
}
