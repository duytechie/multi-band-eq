#ifndef EQDSP_H
#define EQDSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
CF_ASSUME_NONNULL_BEGIN

#define EQ_BANDS 31
typedef struct EQProcessor EQProcessor;
extern const double EQFrequencies[EQ_BANDS];

// Lifetime/configuration: call only while the device is stopped.
EQProcessor * _Nullable EQCreate(double sampleRate, uint32_t firstInputChannel);
void EQDestroy(EQProcessor *processor);
// Single control-thread producer; false means queue full, retry the latest state later.
bool EQSetGains(EQProcessor *processor, const float *left, const float *right, float masterDB);
// Single render-thread consumer; also used by the offline tests.
void EQProcess(EQProcessor *processor, const float *left, const float *right,
               float *outLeft, float *outRight, uint32_t frames);
OSStatus EQDeviceIO(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
float EQTakePeak(EQProcessor * _Nullable processor);
uint64_t EQCallbackCount(EQProcessor * _Nullable processor);
uint64_t EQFaultCount(EQProcessor * _Nullable processor);
CF_ASSUME_NONNULL_END
#endif
