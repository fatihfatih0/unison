import AppKit
import Darwin

enum NativeBrightness {
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private typealias Read = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (UInt32, Float) -> Int32
    static func read(_ display: CGDirectDisplayID) -> Double? {
        guard let library, let pointer = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        let function = unsafeBitCast(pointer, to: Read.self)
        var value: Float = 0
        return function(display, &value) == 0 ? Double(value) : nil
    }
    static func write(_ display: CGDirectDisplayID, value: Double) throws {
        guard let library, let pointer = dlsym(library, "DisplayServicesSetBrightness") else { throw ControlError.message("Yerleşik ekran parlaklık servisi bulunamadı.") }
        let function = unsafeBitCast(pointer, to: Write.self)
        guard function(display, Float(value.clamped)) == 0 else { throw ControlError.message("Yerleşik ekran parlaklığı değiştirilemedi.") }
    }
}
