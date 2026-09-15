#include "EQDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Peaking filters from Robert Bristow-Johnson's Audio EQ Cookbook:
// https://www.w3.org/TR/audio-eq-cookbook/ (one-third octave bandwidth).
const double EQFrequencies[EQ_BANDS] = {
    20,25,31.5,40,50,63,80,100,125,160,200,250,315,400,500,630,
    800,1000,1250,1600,2000,2500,3150,4000,5000,6300,8000,10000,12500,16000,20000
};
enum { QUEUE_SIZE = 8, CHANNELS = 2, COEFFS = 5 };
typedef struct { double c[CHANNELS][EQ_BANDS][COEFFS]; double master; } Parameters;
typedef struct { double x1,x2,y1,y2; } History;
struct EQProcessor {
    double sampleRate;
    uint32_t firstInputChannel;
    Parameters queue[QUEUE_SIZE];
    _Atomic unsigned writeIndex, readIndex;
    Parameters current, target, delta;
    History history[CHANNELS][EQ_BANDS];
    uint32_t rampRemaining, rampLength;
    _Atomic uint32_t peakBits;
    _Atomic uint64_t callbacks, faults;
};
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio callback requires lock-free integer atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio callback requires lock-free counters");

static double bounded(double x, double lo, double hi) {
    return isfinite(x) ? fmin(hi, fmax(lo, x)) : 0;
}
static void coefficients(double rate, double frequency, double gain, double *c) {
    c[0]=1; c[1]=c[2]=c[3]=c[4]=0;
    if (frequency >= rate * .5 || fabs(gain) < 1e-8) return;
    double w=2*M_PI*frequency/rate, s=sin(w), a=pow(10,gain/40);
    // Cap the argument only at extreme proximity to Nyquist to avoid overflow.
    double alpha=s*sinh(fmin(40, log(2)/6*w/s)), a0=1+alpha/a;
    c[0]=(1+alpha*a)/a0; c[1]=-2*cos(w)/a0; c[2]=(1-alpha*a)/a0;
    c[3]=c[1]; c[4]=(1-alpha/a)/a0;
}
EQProcessor *EQCreate(double sampleRate, uint32_t firstInputChannel) {
    if (!isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 384000) return NULL;
    EQProcessor *p=calloc(1,sizeof(*p));
    if (!p) return NULL;
    p->sampleRate=sampleRate; p->firstInputChannel=firstInputChannel;
    p->rampLength=(uint32_t)(sampleRate*.015);
    atomic_init(&p->writeIndex,0); atomic_init(&p->readIndex,0);
    atomic_init(&p->peakBits,0); atomic_init(&p->callbacks,0); atomic_init(&p->faults,0);
    p->current.master=p->target.master=1;
    for (int c=0;c<CHANNELS;c++) for (int b=0;b<EQ_BANDS;b++) {
        p->current.c[c][b][0]=p->target.c[c][b][0]=1;
    }
    return p;
}
void EQDestroy(EQProcessor *p) { free(p); }
bool EQSetGains(EQProcessor *p, const float *left, const float *right, float masterDB) {
    if (!p || !left || !right) return false;
    unsigned w=atomic_load_explicit(&p->writeIndex,memory_order_relaxed);
    unsigned next=(w+1)%QUEUE_SIZE;
    if (next==atomic_load_explicit(&p->readIndex,memory_order_acquire)) return false;
    Parameters *q=&p->queue[w];
    for (int c=0;c<CHANNELS;c++) for (int b=0;b<EQ_BANDS;b++)
        coefficients(p->sampleRate,EQFrequencies[b],bounded(c ? right[b] : left[b],-12,12),q->c[c][b]);
    q->master=pow(10,bounded(masterDB,-24,12)/20);
    atomic_store_explicit(&p->writeIndex,next,memory_order_release);
    return true;
}
static void beginBlock(EQProcessor *p) {
    unsigned r=atomic_load_explicit(&p->readIndex,memory_order_relaxed);
    unsigned w=atomic_load_explicit(&p->writeIndex,memory_order_acquire);
    if (r==w) return;
    // Snapshot the newest fully published entry. Bound work even if the producer is busy.
    p->target=p->queue[(w+QUEUE_SIZE-1)%QUEUE_SIZE];
    atomic_store_explicit(&p->readIndex,w,memory_order_release);
    p->rampRemaining=p->rampLength;
    for (int c=0;c<CHANNELS;c++) for (int b=0;b<EQ_BANDS;b++) for(int k=0;k<COEFFS;k++)
        p->delta.c[c][b][k]=(p->target.c[c][b][k]-p->current.c[c][b][k])/p->rampLength;
    p->delta.master=(p->target.master-p->current.master)/p->rampLength;
}
static void step(EQProcessor *p) {
    if (!p->rampRemaining) return;
    if (--p->rampRemaining==0) { p->current=p->target; return; }
    for (int c=0;c<CHANNELS;c++) for (int b=0;b<EQ_BANDS;b++) for(int k=0;k<COEFFS;k++)
        p->current.c[c][b][k]+=p->delta.c[c][b][k];
    p->current.master+=p->delta.master;
}
static float sample(EQProcessor *p, float input, int channel) {
    double x=(isfinite(input) ? input : 0)*p->current.master;
    for (int b=0;b<EQ_BANDS;b++) {
        double *c=p->current.c[channel][b]; History *h=&p->history[channel][b];
        double y=c[0]*x+c[1]*h->x1+c[2]*h->x2-c[3]*h->y1-c[4]*h->y2;
        if (!isfinite(y)) { memset(h,0,sizeof(*h)); y=0; atomic_fetch_add_explicit(&p->faults,1,memory_order_relaxed); }
        if (fabs(y)<1e-24) y=0;
        h->x2=h->x1; h->x1=x; h->y2=h->y1; h->y1=y; x=y;
    }
    // Do not limit the user's curve: report peaks so master attenuation can be adjusted.
    return (float)x;
}
static void publishPeak(EQProcessor *p,float peak) {
    uint32_t bits; memcpy(&bits,&peak,sizeof(bits));
    // Nonnegative IEEE float bit patterns have the same order as unsigned integers.
    uint32_t old=atomic_load_explicit(&p->peakBits,memory_order_relaxed);
    // One bounded CAS: if UI cleared it concurrently, the next audio block updates it.
    if (bits>old) atomic_compare_exchange_strong_explicit(&p->peakBits,&old,bits,memory_order_relaxed,memory_order_relaxed);
}
void EQProcess(EQProcessor *p,const float *left,const float *right,float *outLeft,float *outRight,uint32_t frames) {
    if (!p) return;
    beginBlock(p); float peak=0;
    for(uint32_t i=0;i<frames;i++) {
        step(p); outLeft[i]=sample(p,left[i],0); outRight[i]=sample(p,right[i],1);
        peak=fmaxf(peak,fmaxf(fabsf(outLeft[i]),fabsf(outRight[i])));
    }
    publishPeak(p,peak);
}
typedef struct { float *data; uint32_t stride, frames; } Channel;
static Channel findChannel(const AudioBufferList *list,uint32_t channel) {
    if (list) for(uint32_t b=0;b<list->mNumberBuffers;b++) {
        const AudioBuffer *buffer=&list->mBuffers[b];
        if (channel<buffer->mNumberChannels) {
            if (!buffer->mData || !buffer->mNumberChannels) break;
            return (Channel){(float*)buffer->mData+channel,buffer->mNumberChannels,
                buffer->mDataByteSize/(sizeof(float)*buffer->mNumberChannels)};
        }
        channel-=buffer->mNumberChannels;
    }
    return (Channel){0};
}
OSStatus EQDeviceIO(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,
    const AudioTimeStamp *inputTime,AudioBufferList *output,const AudioTimeStamp *outputTime,void *context) {
    EQProcessor *p=context;
    if (!p || !output) return noErr;
    atomic_fetch_add_explicit(&p->callbacks,1,memory_order_relaxed);
    // Silence all unhandled channels and tails, including devices with additional outputs.
    for(uint32_t b=0;b<output->mNumberBuffers;b++) if(output->mBuffers[b].mData)
        memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    Channel inL=findChannel(input,p->firstInputChannel), inR=findChannel(input,p->firstInputChannel+1);
    Channel outL=findChannel(output,0), outR=findChannel(output,1);
    if (!inL.data || !inR.data || !outL.data || !outR.data) {
        atomic_fetch_add_explicit(&p->faults,1,memory_order_relaxed); return noErr;
    }
    uint32_t frames=inL.frames;
    if(inR.frames<frames) frames=inR.frames;
    if(outL.frames<frames) frames=outL.frames;
    if(outR.frames<frames) frames=outR.frames;
    beginBlock(p); float peak=0;
    for(uint32_t i=0;i<frames;i++) {
        step(p);
        float l=sample(p,inL.data[i*inL.stride],0), r=sample(p,inR.data[i*inR.stride],1);
        outL.data[i*outL.stride]=l; outR.data[i*outR.stride]=r;
        peak=fmaxf(peak,fmaxf(fabsf(l),fabsf(r)));
    }
    publishPeak(p,peak); return noErr;
}
float EQTakePeak(EQProcessor *p) {
    if(!p) return 0;
    uint32_t bits=atomic_exchange_explicit(&p->peakBits,0,memory_order_relaxed);
    float value; memcpy(&value,&bits,sizeof(value)); return value;
}
uint64_t EQCallbackCount(EQProcessor *p) { return p ? atomic_load_explicit(&p->callbacks,memory_order_relaxed) : 0; }
uint64_t EQFaultCount(EQProcessor *p) { return p ? atomic_load_explicit(&p->faults,memory_order_relaxed) : 0; }
