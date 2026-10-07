// Unison system-volume endpoint. Audio is rendered by the Unison process-tap engine.
// libASPL is Copyright (c) Victor Gaydov and contributors, licensed under MIT.
#include <aspl/Driver.hpp>

class ControlOnlyOutput final : public aspl::IORequestHandler {
public:
    // Do not apply volume here: Unison applies the control's gain to its physical
    // outputs. HAL still sees real volume/mute controls and uses its native HUD.
    void OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>&, Float64, Float64,
                              Float32*, UInt32, UInt32) override {}
};

extern "C" void* UnisonAudioFactory(CFAllocatorRef, CFUUIDRef type) {
    if (!CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    static std::shared_ptr<aspl::Driver> driver = [] {
        auto context = std::make_shared<aspl::Context>();
        aspl::DeviceParameters parameters;
        parameters.Name = "Unison";
        parameters.Manufacturer = "Unison";
        parameters.DeviceUID = "org.unison.output";
        parameters.ModelUID = "org.unison.audio.model";
        parameters.SampleRate = 48000;
        parameters.ChannelCount = 2;
        parameters.EnableMixing = true;
        parameters.EnableRealtimeTracing = false;
        auto device = std::make_shared<aspl::Device>(context, parameters);
        aspl::StreamParameters stream;
        stream.Direction = aspl::Direction::Output;
        stream.Format = AudioStreamBasicDescription{48000, kAudioFormatLinearPCM,
            kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            8, 1, 8, 2, 32, 0};
        device->AddStreamWithControlsAsync(stream);
        device->SetIOHandler(std::make_shared<ControlOnlyOutput>());
        auto plugin = std::make_shared<aspl::Plugin>(context);
        plugin->AddDevice(device);
        return std::make_shared<aspl::Driver>(context, plugin);
    }();
    return driver->GetReference();
}
