// hid_dump.c — DJI C5 (VID 0x2CA3 / PID 0x1020) HID gamepad report dumper
// Report layout per report descriptor: 3 bytes button bitmap + 5 x int16 LE (X,Y,Z,Rx,Ry) = 13 bytes
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <CoreFoundation/CoreFoundation.h>

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s){ (void)s; g_stop = 1; }

static const char *AX[5] = {"X ","Y ","Z ","Rx","Ry"};
static long ax_min[5], ax_max[5], ax_last[5];
static unsigned long btn_or = 0, nrep = 0, nchange = 0;
static uint8_t last_rep[32]; static int have_last = 0;
static double t0 = 0;

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }
static long le16(const uint8_t*p){ return (long)(int16_t)((unsigned)p[0] | ((unsigned)p[1]<<8)); }

static void cb(void *c, IOReturn r, void *s, IOHIDReportType ty, uint32_t rid, uint8_t *rep, CFIndex len){
    (void)c;(void)r;(void)s;(void)ty;(void)rid;
    if (len < 13) return;
    nrep++;
    unsigned b = (unsigned)rep[0] | ((unsigned)rep[1]<<8) | ((unsigned)rep[2]<<16);
    btn_or |= b;
    for (int i=0;i<5;i++){ long v = le16(rep+3+2*i); ax_last[i]=v; if(v<ax_min[i]) ax_min[i]=v; if(v>ax_max[i]) ax_max[i]=v; }
    int changed = !have_last || memcmp(last_rep, rep, 13) != 0;
    if (changed) nchange++;
    memcpy(last_rep, rep, 13); have_last = 1;
    if (changed) {
        printf("[%7.3fs] %02x %02x %02x  X=%5ld Y=%5ld Z=%5ld Rx=%5ld Ry=%5ld  btn=0x%06x\n",
               now()-t0, rep[0],rep[1],rep[2], le16(rep+3), le16(rep+5), le16(rep+7), le16(rep+9), le16(rep+11), b);
        fflush(stdout);
    }
}
static void matched(void *c, IOReturn r, void *s, IOHIDDeviceRef d){ (void)c;(void)r;(void)s;
    CFStringRef p = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey));
    char buf[256]="?"; if(p) CFStringGetCString(p, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("== matched HID device: %s ==\n", buf);
}
int main(int argc, char**argv){
    double secs = (argc>1)? atof(argv[1]) : 10.0;
    for(int i=0;i<5;i++){ ax_min[i]= 32767; ax_max[i]=-32768; ax_last[i]=0; }
    signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = 0x2CA3, pid = 0x1020;
    CFNumberRef nv = CFNumberCreate(NULL,kCFNumberIntType,&vid), np = CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFMutableDictionaryRef mt = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(mt, CFSTR(kIOHIDVendorIDKey), nv);
    CFDictionarySetValue(mt, CFSTR(kIOHIDProductIDKey), np);
    IOHIDManagerSetDeviceMatching(m, mt);
    IOHIDManagerRegisterDeviceMatchingCallback(m, matched, NULL);
    IOHIDManagerRegisterInputReportCallback(m, cb, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn o = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    printf("IOHIDManagerOpen -> 0x%08x (%s)\n", o, o? "FAILED":"ok");
    t0 = now();
    printf("capturing %.1fs...\n", secs);
    while(!g_stop && now()-t0 < secs) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone);
    printf("\n===== SUMMARY =====\nreports=%lu  distinct=%lu\n", nrep, nchange);
    for(int i=0;i<5;i++) printf("  axis %s  min=%6ld  max=%6ld  range=%ld\n", AX[i], ax_min[i], ax_max[i], ax_max[i]-ax_min[i]);
    printf("  buttons ever pressed: 0x%06x\n", btn_or);
    for(int i=0;i<24;i++) if(btn_or>>i & 1) printf("    button %2d pressed\n", i+1);
    return 0;
}
