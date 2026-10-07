import Foundation
import CoreGraphics

struct Monitor: Identifiable {
    let id: String
    let name: String
    var brightness: Double?
    var volume: Double?
    var brightnessMax: Int = 100
    var volumeMax: Int = 100
    var manual = false
    var builtIn = false
    var displayID: CGDirectDisplayID = 0
}

enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

actor DDC {
    private let executable: URL = {
        if let resources = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: resources.appendingPathComponent("m1ddc").path) { return resources.appendingPathComponent("m1ddc") }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/m1ddc/m1ddc")
    }()

    func run(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else { throw ControlError.message(output.isEmpty ? "Ekran geçerli bir DDC yanıtı vermedi. Ekranın menüsünden DDC/CI ayarını kontrol edin." : output) }
        return output
    }

    static func parseList(_ text: String, builtInIDs: Set<String>) -> [Monitor] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("["), let endIndex = line.firstIndex(of: "]"), let open = line.range(of: " (", options: .backwards), line.hasSuffix(")") else { return nil }
            let id = String(line[open.upperBound..<line.index(before: line.endIndex)])
            guard UUID(uuidString: id) != nil, !builtInIDs.contains(id.uppercased()) else { return nil }
            let name = String(line[line.index(after: endIndex)..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            return Monitor(id: id, name: name)
        }
    }

    func discover(builtInIDs: Set<String>) throws -> [Monitor] {
        var monitors = Self.parseList(try run(["display", "list"]), builtInIDs: builtInIDs)
        for index in monitors.indices {
            if let reading = try? read(monitors[index].id, feature: "luminance") {
                monitors[index].brightness = reading.value; monitors[index].brightnessMax = reading.max
            }
            if let reading = try? read(monitors[index].id, feature: "volume") {
                monitors[index].volume = reading.value; monitors[index].volumeMax = reading.max
            }
        }
        return monitors
    }

    func read(_ id: String, feature: String) throws -> (value: Double, max: Int) {
        guard let current = Int(try run(["display", id, "get", feature])), let max = Int(try run(["display", id, "max", feature])), max > 0, max <= 65535, current >= 0, current <= max else { throw ControlError.message("DDC değeri geçersiz.") }
        return (Double(current) / Double(max), max)
    }

    func write(_ id: String, feature: String, value: Double, max: Int) throws -> Double? {
        try send(id, feature: feature, value: value, max: max)
        // A successful I2C write is not proof that the display applied the value.
        return try? read(id, feature: feature).value
    }
    func send(_ id: String, feature: String, value: Double, max: Int) throws {
        _ = try run(["display", id, "set", feature, String(Int((value.clamped * Double(max)).rounded()))])
    }
}

extension Double { var clamped: Double { min(1, max(0, self)) } }
