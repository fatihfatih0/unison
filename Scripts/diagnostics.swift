import Foundation
import CoreAudio

@main
struct Diagnostics {
    static func main() throws {
        let previous = AudioControl.defaultOutput()
        let outputs = AudioControl.outputs()
        for output in outputs { print("\(output.name): ses=\(output.volume.map { String(Int($0 * 100)) } ?? "desteklenmiyor"), birleşik=\(output.isAggregate)") }
        let physical = outputs.filter { !$0.isAggregate }
        guard physical.count >= 2 else { print("Çoklu çıkış testi için en az iki fiziksel çıkış gerekli."); return }
        let id = try AudioControl.aggregate(Array(physical.prefix(2)))
        defer { _ = AudioHardwareDestroyAggregateDevice(id) }
        var address = AudioControl.address(kAudioAggregateDevicePropertyComposition)
        var composition: Unmanaged<CFDictionary>?, size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try AudioControl.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition))
        let dict = composition!.takeRetainedValue() as NSDictionary
        guard let stacked = dict[kAudioAggregateDeviceIsStackedKey] as? NSNumber, stacked.intValue == 1 else { throw ControlError.message("Paylaşılan stereo çıkış modu doğrulanamadı.") }
        guard AudioControl.defaultOutput() == previous else { throw ControlError.message("Tanılama sırasında sistem çıkışı değişti.") }
        print("İki fiziksel çıkışla grup oluşturuldu; paylaşılan stereo mod (stacked=1) doğrulandı. Sistem çıkışı değişmedi. Test grubu temizleniyor.")
    }
}
