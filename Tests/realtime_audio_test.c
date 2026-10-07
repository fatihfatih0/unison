#include "RealtimeAudio.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void test_sixteen_devices(void) {
    UnisonDSP *state = unison_dsp_create();
    assert(state);
    float samples[] = {1, -1, 0.5, -0.25};
    AudioBufferList input = {.mNumberBuffers=1, .mBuffers={{2, sizeof(samples), samples}}};
    AudioBufferList *output = calloc(1, sizeof(AudioBufferList) + 15 * sizeof(AudioBuffer));
    assert(output);
    float destination[16][4] = {{0}};
    unsigned totalChannels = 0;
    for (unsigned device=0; device<16; device++) {
        unsigned channels = device % 3 == 0 ? 1 : 2;
        totalChannels += channels;
        unison_dsp_set_device(state, device, channels, (device + 1) / 16.0f);
        output->mBuffers[device] = (AudioBuffer){channels, 2 * channels * sizeof(float), destination[device]};
    }
    output->mNumberBuffers = 16;
    unison_dsp_render(state, &input, output);
    for (unsigned device=0; device<16; device++) {
        unsigned channels = output->mBuffers[device].mNumberChannels;
        float gain = (device + 1) / 16.0f;
        for (unsigned frame=0; frame<2; frame++) {
            for (unsigned ch=0; ch<channels; ch++) {
                assert(destination[device][frame * channels + ch] == samples[frame * 2 + ch] * gain);
            }
        }
        assert(unison_dsp_device_signal_count(state, device) == 1);
    }
    assert(destination[14][0] != destination[15][0]);
    unison_dsp_set_device(state, 15, 0, 0);
    unison_dsp_set_device(state, 16, 2, 0); // Invalid indices must be ignored.
    unison_dsp_render(state, &input, output);
    assert(destination[14][0] == 15 / 16.0f);
    for (unsigned i=0; i<2; i++) assert(destination[15][i] == 0);
    assert(unison_dsp_device_signal_count(state, 14) == 2);
    assert(unison_dsp_device_signal_count(state, 15) == 1);

    // The same device boundaries apply inside one interleaved output buffer.
    unison_dsp_set_device(state, 15, 0, 1);
    float interleaved[64] = {0};
    AudioBufferList combined = {.mNumberBuffers=1, .mBuffers={{totalChannels, 2 * totalChannels * sizeof(float), interleaved}}};
    unison_dsp_render(state, &input, &combined);
    unsigned offset = 0;
    for (unsigned device=0; device<16; device++) {
        unsigned channels = output->mBuffers[device].mNumberChannels;
        for (unsigned frame=0; frame<2; frame++) {
            for (unsigned ch=0; ch<channels; ch++) {
                assert(interleaved[frame * totalChannels + offset + ch] == samples[frame * 2 + ch] * ((device + 1) / 16.0f));
            }
        }
        offset += channels;
    }
    free(output);
    unison_dsp_destroy(state);
}

static void test_unconfigured_channels_stay_silent(void) {
    UnisonDSP *state = unison_dsp_create();
    assert(state);
    for (unsigned device=0; device<16; device++) unison_dsp_set_device(state, device, 2, 1);
    float samples[] = {1, -1};
    float destination[34] = {0};
    AudioBufferList input = {.mNumberBuffers=1, .mBuffers={{2, sizeof(samples), samples}}};
    AudioBufferList output = {.mNumberBuffers=1, .mBuffers={{34, sizeof(destination), destination}}};
    unison_dsp_render(state, &input, &output);
    for (unsigned ch=0; ch<32; ch++) assert(destination[ch] == samples[ch % 2]);
    assert(destination[32] == 0 && destination[33] == 0);
    unison_dsp_destroy(state);
}

int main(void) {
    test_sixteen_devices();
    test_unconfigured_channels_stay_silent();
    UnisonDSP *state = unison_dsp_create();
    assert(state);
    unison_dsp_set_device(state, 0, 2, 1);
    unison_dsp_set_device(state, 1, 2, 0.5);
    unison_dsp_set_gain(state, 0.5);
    float inputSamples[] = {1, -1, 0.5, -0.25};
    AudioBufferList input = {.mNumberBuffers=1, .mBuffers={{2, sizeof(inputSamples), inputSamples}}};
    float destination[8] = {0};
    AudioBufferList output = {.mNumberBuffers=1, .mBuffers={{4, sizeof(destination), destination}}};
    unison_dsp_render(state, &input, &output);
    assert(destination[0] == 0.5 && destination[1] == -0.5);
    assert(destination[2] == 0.25 && destination[3] == -0.25);
    assert(destination[4] == 0.25 && destination[5] == -0.125);
    assert(destination[6] == 0.125 && destination[7] == -0.0625);
    unison_dsp_set_gain(state, 0);
    unison_dsp_render(state, &input, &output);
    for (int i=0; i<8; i++) assert(destination[i] == 0);
    // Separate stereo streams must receive the same source with distinct device gain.
    AudioBufferList *split = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    float a[6] = {0}, b[6] = {0};
    split->mNumberBuffers = 2;
    split->mBuffers[0] = (AudioBuffer){2, sizeof(a), a};
    split->mBuffers[1] = (AudioBuffer){2, sizeof(b), b};
    unison_dsp_set_gain(state, 1);
    unison_dsp_render(state, &input, split);
    assert(a[0] == 1 && a[1] == -1 && b[0] == 0.5 && b[1] == -0.5);
    assert(a[4] == 0 && a[5] == 0 && b[4] == 0 && b[5] == 0);
    // A disabled first stream still owns its channel range. The second stream
    // must retain device 1's gain rather than accidentally adopting device 0's.
    split->mBuffers[0].mData = NULL;
    unison_dsp_set_device(state, 0, 0, 0);
    unison_dsp_set_device(state, 1, 0, 0.5);
    unison_dsp_render(state, &input, split);
    assert(b[0] == 0.5 && b[1] == -0.5);
    split->mBuffers[0].mData = a;
    input.mBuffers[0].mData = NULL;
    unison_dsp_render(state, &input, split);
    for (int i=0; i<6; i++) assert(a[i] == 0 && b[i] == 0);
    free(split);
    unison_dsp_destroy(state);
    puts("DSP: stereo dağıtımı, 16 cihaz, ayrı kazanç/sessizlik, ortak ses ve yapılandırılmamış/devre dışı çıkış kanalları geçti.");
}
