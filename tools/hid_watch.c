// hid_watch.c — turn raw DJI C5 HID reports into discrete "which control moved" events
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <CoreFoundation/CoreFoundation.h>

#define THRESH 6
static volatile sig_atomic_t g_stop=0;
static void on_sig(int s){(void)s;g_stop=1;}
static double t0;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static long le16(const uint8_t*p){return (long)(int16_t)((unsigned)p[0]|((unsigned)p[1]<<8));}
static const char*AX[5]={"X","Y","Z","Rx","Ry"};

static long prev[5], ev_from[5], ev_min[5], ev_max[5];
static unsigned pbtn=0xFFFFFFFF; static int moving=0, have=0;
static double last_ch=0; static int evno=0;

static void cb(void*c,IOReturn r,void*s,IOHIDReportType ty,uint32_t rid,uint8_t*rep,CFIndex len){
    (void)c;(void)r;(void)s;(void)ty;(void)rid; if(len<13)return;
    double t=now()-t0;
    long nx[5]; for(int i=0;i<5;i++) nx[i]=le16(rep+3+2*i);
    unsigned b=(unsigned)rep[0]|((unsigned)rep[1]<<8)|((unsigned)rep[2]<<16);

    // buttons: report each transition
    if(pbtn!=0xFFFFFFFFu && b!=pbtn){
        for(int i=0;i<24;i++){ int o=(pbtn>>i)&1, n=(b>>i)&1;
            if(o!=n) printf("[%7.2fs] BUTTON #%d  %s\n", t, i+1, n?"PRESS":"release"); }
        fflush(stdout);
    }
    pbtn=b;

    if(!have){ for(int i=0;i<5;i++) prev[i]=nx[i]; have=1; last_ch=t; return; }
    int moved=0; for(int i=0;i<5;i++) if(labs(nx[i]-prev[i])>=THRESH) moved=1;
    if(moved){
        if(!moving){ moving=1; for(int i=0;i<5;i++){ ev_from[i]=prev[i]; ev_min[i]=nx[i]; ev_max[i]=nx[i]; } }
        else for(int i=0;i<5;i++){ if(nx[i]<ev_min[i])ev_min[i]=nx[i]; if(nx[i]>ev_max[i])ev_max[i]=nx[i]; }
        last_ch=t;
    }
    for(int i=0;i<5;i++) prev[i]=nx[i];
    if(moving && t-last_ch>0.30){
        evno++; printf("[%7.2fs] EVENT %d:", t, evno);
        int any=0;
        for(int i=0;i<5;i++){
            long span = ev_max[i]-ev_min[i];
            if(span>=THRESH){ printf("  %s %ld..%ld (span %ld)", AX[i], ev_min[i], ev_max[i], span); any=1; }
        }
        if(!any) printf("  (only buttons)");
        printf("\n"); fflush(stdout);
        moving=0;
    }
}
int main(int argc,char**argv){
    double secs=(argc>1)?atof(argv[1]):300.0;
    signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
    IOHIDManagerRef m=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    int vid=0x2CA3,pid=0x1020;
    CFNumberRef nv=CFNumberCreate(NULL,kCFNumberIntType,&vid),np=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFMutableDictionaryRef mt=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(mt,CFSTR(kIOHIDVendorIDKey),nv);
    CFDictionarySetValue(mt,CFSTR(kIOHIDProductIDKey),np);
    IOHIDManagerSetDeviceMatching(m,mt);
    IOHIDManagerRegisterInputReportCallback(m,cb,NULL);
    IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    if(IOHIDManagerOpen(m,kIOHIDOptionsTypeNone)){fprintf(stderr,"open failed\n");return 1;}
    t0=now(); fprintf(stderr,"watch %.0fs\n",secs);
    while(!g_stop && now()-t0<secs) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,true);
    IOHIDManagerClose(m,kIOHIDOptionsTypeNone);
    fprintf(stderr,"done\n"); return 0;
}
