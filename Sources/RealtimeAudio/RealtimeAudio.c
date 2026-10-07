#include "RealtimeAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct UnisonDSP {
    _Atomic float gain;
    _Atomic unsigned callbacks;
    _Atomic unsigned signalBlocks;
    _Atomic unsigned inputLayout;
    _Atomic unsigned outputLayout;
    _Atomic unsigned deviceSignalBlocks[16];
    _Atomic float deviceGain[16];
    unsigned channels[16]; // Set before AudioDeviceStart; immutable while running.
};
UnisonDSP *unison_dsp_create(void) {
    UnisonDSP *s = calloc(1, sizeof(*s));
    if (s) { atomic_init(&s->gain, 1); atomic_init(&s->callbacks, 0); atomic_init(&s->signalBlocks, 0); atomic_init(&s->inputLayout, 0); atomic_init(&s->outputLayout, 0); for (int i=0; i<16; i++) { atomic_init(&s->deviceGain[i], 1); atomic_init(&s->deviceSignalBlocks[i], 0); } if (!atomic_is_lock_free(&s->gain)) { free(s); return NULL; } }
    return s;
}
void unison_dsp_destroy(UnisonDSP *s) { free(s); }
void unison_dsp_set_gain(UnisonDSP *s, float value) { atomic_store_explicit(&s->gain, isfinite(value) ? fminf(1, fmaxf(0, value)) : 0, memory_order_relaxed); }
void unison_dsp_set_device(UnisonDSP *s, unsigned index, unsigned channels, float gain) {
    if (index >= 16) return;
    if (channels) s->channels[index] = channels;
    atomic_store_explicit(&s->deviceGain[index], fminf(1, fmaxf(0, gain)), memory_order_relaxed);
}
void unison_dsp_render(UnisonDSP *s, const AudioBufferList *input, AudioBufferList *output) {
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    // The tap is validated as packed interleaved Float32 stereo before starting.
    const AudioBuffer *source = input && input->mNumberBuffers ? &input->mBuffers[input->mNumberBuffers - 1] : NULL;
    atomic_store_explicit(&s->inputLayout, ((input ? input->mNumberBuffers : 0) << 16) | (source ? source->mNumberChannels : 0), memory_order_relaxed);
    unsigned inputFrames = source && source->mData && source->mNumberChannels == 2 ? source->mDataByteSize / (2 * sizeof(float)) : 0;
    const float *samples = inputFrames ? source->mData : NULL;
    for (unsigned i=0; i<inputFrames * 2; i++) {
        if (fabsf(samples[i]) > 0.00001f) { atomic_fetch_add_explicit(&s->signalBlocks, 1, memory_order_relaxed); break; }
    }
    float master = atomic_load_explicit(&s->gain, memory_order_relaxed);
    unsigned channelOffset = 0;
    bool hasSignal[16] = {false};
    for (unsigned b=0; b<output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels) { channelOffset += buffer->mNumberChannels; continue; }
        memset(buffer->mData, 0, buffer->mDataByteSize);
        unsigned frames = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (frames > inputFrames) frames = inputFrames;
        float *dest = buffer->mData;
        for (unsigned ch=0; ch<buffer->mNumberChannels; ch++) {
            unsigned globalChannel = channelOffset + ch, start = 0, device = 0;
            while (device < 16 && s->channels[device] && globalChannel >= start + s->channels[device]) { start += s->channels[device]; device++; }
            // Leave channels outside the configured device layout silent.
            if (device >= 16 || !s->channels[device]) continue;
            float gain = master * atomic_load_explicit(&s->deviceGain[device], memory_order_relaxed);
            unsigned sourceChannel = (globalChannel - start) % 2;
            for (unsigned frame=0; frame<frames; frame++) {
                float value = samples[frame * 2 + sourceChannel] * gain;
                dest[frame * buffer->mNumberChannels + ch] = value;
                if (fabsf(value) > 0.00001f) hasSignal[device] = true;
            }
        }
        channelOffset += buffer->mNumberChannels;
    }
    atomic_store_explicit(&s->outputLayout, (output->mNumberBuffers << 16) | channelOffset, memory_order_relaxed);
    for (unsigned device=0; device<16; device++) if (hasSignal[device]) atomic_fetch_add_explicit(&s->deviceSignalBlocks[device], 1, memory_order_relaxed);
}
unsigned unison_dsp_callback_count(UnisonDSP *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
unsigned unison_dsp_signal_count(UnisonDSP *s) { return atomic_load_explicit(&s->signalBlocks, memory_order_relaxed); }
unsigned unison_dsp_input_layout(UnisonDSP *s) { return atomic_load_explicit(&s->inputLayout, memory_order_relaxed); }
unsigned unison_dsp_output_layout(UnisonDSP *s) { return atomic_load_explicit(&s->outputLayout, memory_order_relaxed); }
unsigned unison_dsp_device_signal_count(UnisonDSP *s, unsigned index) { return index < 16 ? atomic_load_explicit(&s->deviceSignalBlocks[index], memory_order_relaxed) : 0; }
OSStatus unison_audio_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    unison_dsp_render(context, input, output);
    return noErr;
}
