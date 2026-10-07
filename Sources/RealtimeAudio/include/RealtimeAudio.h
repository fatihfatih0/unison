#include <CoreAudio/CoreAudio.h>
#pragma clang assume_nonnull begin
typedef struct UnisonDSP UnisonDSP;
UnisonDSP * _Nullable unison_dsp_create(void);
void unison_dsp_destroy(UnisonDSP *state);
void unison_dsp_set_gain(UnisonDSP *state, float gain);
void unison_dsp_set_device(UnisonDSP *state, unsigned index, unsigned channels, float gain);
void unison_dsp_render(UnisonDSP *state, const AudioBufferList *input, AudioBufferList *output);
unsigned unison_dsp_callback_count(UnisonDSP *state);
unsigned unison_dsp_signal_count(UnisonDSP *state);
unsigned unison_dsp_input_layout(UnisonDSP *state);
unsigned unison_dsp_device_signal_count(UnisonDSP *state, unsigned index);
unsigned unison_dsp_output_layout(UnisonDSP *state);
float unison_dsp_input_peak(UnisonDSP *state);
float unison_dsp_device_peak(UnisonDSP *state, unsigned index);
OSStatus unison_audio_callback(AudioObjectID device, const AudioTimeStamp * _Nonnull now, const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime, AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#pragma clang assume_nonnull end
