#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cassert>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <cstdio>
#include <unistd.h>
#include <vector>

int main(int argc, char** argv) {
    assert(argc == 2);
    auto handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    using Factory = void* (*)(CFAllocatorRef, CFUUIDRef);
    auto factory = reinterpret_cast<Factory>(dlsym(handle, "UnisonAudioFactory"));
    assert(factory);
    auto driver = reinterpret_cast<AudioServerPlugInDriverRef>(factory(nullptr, kAudioServerPlugInTypeUUID));
    assert(driver);
    auto get = [&](AudioObjectID object, AudioObjectPropertySelector selector, void* data, UInt32 size, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
        AudioObjectPropertyAddress address{selector, scope, 0}; UInt32 used = 0;
        return (*driver)->GetPropertyData(driver, object, getpid(), &address, 0, nullptr, size, &used, data);
    };
    AudioObjectID device = 0;
    assert(get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, &device, 4) == noErr && device);
    CFStringRef name = nullptr, uid = nullptr;
    assert(get(device, kAudioObjectPropertyName, &name, sizeof(name)) == noErr);
    assert(CFEqual(name, CFSTR("Unison")));
    assert(get(device, kAudioDevicePropertyDeviceUID, &uid, sizeof(uid)) == noErr);
    assert(CFEqual(uid, CFSTR("org.unison.output")));
    CFRelease(name); CFRelease(uid);
    AudioObjectID stream = 0;
    assert(get(device, kAudioDevicePropertyStreams, &stream, 4, kAudioObjectPropertyScopeOutput) == noErr && stream);
    AudioStreamBasicDescription format{};
    assert(get(stream, kAudioStreamPropertyVirtualFormat, &format, sizeof(format)) == noErr);
    assert(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && (format.mFormatFlags & kAudioFormatFlagIsFloat));
    AudioObjectID controls[2]{};
    assert(get(device, kAudioObjectPropertyControlList, controls, sizeof(controls)) == noErr);
    bool volumeChecked = false, muteChecked = false;
    for (auto control : controls) {
        UInt32 klass = 0, scope = 0;
        assert(get(control, kAudioObjectPropertyClass, &klass, 4) == noErr);
        assert(get(control, kAudioControlPropertyScope, &scope, 4) == noErr && scope == kAudioObjectPropertyScopeOutput);
        AudioObjectPropertySelector selector = klass == kAudioVolumeControlClassID ? kAudioLevelControlPropertyScalarValue : kAudioBooleanControlPropertyValue;
        AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, 0};
        Boolean writable = false;
        assert((*driver)->IsPropertySettable(driver, control, getpid(), &address, &writable) == noErr && writable);
        if (klass == kAudioVolumeControlClassID) {
            Float32 value = 0.625, observed = 0;
            assert((*driver)->SetPropertyData(driver, control, getpid(), &address, 0, nullptr, 4, &value) == noErr);
            assert(get(control, selector, &observed, 4) == noErr && fabs(observed - value) < 0.002);
            volumeChecked = true;
        } else {
            assert(klass == kAudioMuteControlClassID);
            UInt32 value = 1, observed = 0;
            assert((*driver)->SetPropertyData(driver, control, getpid(), &address, 0, nullptr, 4, &value) == noErr);
            assert(get(control, selector, &observed, 4) == noErr && observed == 1);
            muteChecked = true;
        }
    }
    assert(volumeChecked && muteChecked);
    AudioServerPlugInClientInfo client{};
    client.mClientID = 7; client.mProcessID = getpid(); client.mIsNativeEndian = true;
    client.mBundleID = CFSTR("org.unison.driver.test");
    assert((*driver)->AddDeviceClient(driver, device, &client) == noErr);
    assert((*driver)->StartIO(driver, device, client.mClientID) == noErr);
    Float64 sampleTime = -1; UInt64 hostTime = 0, seed = 0;
    assert((*driver)->GetZeroTimeStamp(driver, device, client.mClientID, &sampleTime, &hostTime, &seed) == noErr);
    assert(sampleTime >= 0 && hostTime > 0);
    Boolean willDo = false, inPlace = false;
    assert((*driver)->WillDoIOOperation(driver, device, client.mClientID, kAudioServerPlugInIOOperationProcessMix, &willDo, &inPlace) == noErr && willDo);
    std::vector<Float32> samples(256, 0.25f);
    AudioServerPlugInIOCycleInfo cycle{};
    assert((*driver)->DoIOOperation(driver, device, stream, client.mClientID, kAudioServerPlugInIOOperationProcessMix, 128, &cycle, samples.data(), nullptr) == noErr);
    for (auto sample : samples) assert(sample == 0.25f); // App applies gain, not this endpoint.
    assert((*driver)->StopIO(driver, device, client.mClientID) == noErr);
    assert((*driver)->RemoveDeviceClient(driver, device, &client) == noErr);
    printf("driver_name_and_uid=PASS\noutput_stream_48k_stereo=PASS\nvolume_control_readback=PASS\nmute_control_readback=PASS\nrealtime_io_clock_and_no_double_gain=PASS\n");
    // Driver intentionally remains loaded until process exit (static shared owner).
    return 0;
}
