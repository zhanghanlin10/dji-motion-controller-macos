// dji_hud.c — DJI Motion Controller (0x2CA3:0x1020) live HUD + center capture
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <termios.h>
#include <time.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <CoreFoundation/CoreFoundation.h>

static volatile sig_atomic_t g_stop=0;
static void on_sig(int s){(void)s;g_stop=1;}
static long cur[5]; static long ctr[5]; static long omin[5],omax[5];
static unsigned btn=0;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static long le16(const uint8_t*p){return (long)(int16_t)((unsigned)p[0]|((unsigned)p[1]<<8));}
static const char*NAM[5]={"X  pitch?","Y  roll?","Z  trigger","Rx yaw?","Ry gimbal"};
static long newv[5]; static int fresh=0;

static void cb(void*c,IOReturn r,void*s,IOHIDReportType ty,uint32_t rid,uint8_t*rep,CFIndex len){
    (void)c;(void)r;(void)s;(void)ty;(void)rid; if(len<13)return;
    for(int i=0;i<5;i++) newv[i]=le16(rep+3+2*i);
    btn=(unsigned)rep[0]|((unsigned)rep[1]<<8)|((unsigned)rep[2]<<16);
    fresh=1;
}
static void bars(long v,long c){
    double n=(double)(v-c)/1024.0; if(n>1)n=1; if(n<-1)n=-1;
    int W=24, pos=(int)((n+1.0)*W/2.0); if(pos<0)pos=0; if(pos>W)pos=W;
    char b[64]; memset(b,'-',W+1); b[W+1]=0;
    if(pos==W/2) b[W/2]='|'; else { b[pos]='@'; b[W/2]='|'; }
    printf("[%s]", b);
}
int main(int argc,char**argv){
    int plain = !isatty(1) || (argc>1 && !strcmp(argv[1],"--plain"));
    signal(SIGINT,on_sig); signal(SIGTERM,on_sig);
    IOHIDManagerRef m=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    int vid=0x2CA3,pid=0x1020;
    CFNumberRef nv=CFNumberCreate(NULL,kCFNumberIntType,&vid),np=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFMutableDictionaryRef mt=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(mt,CFSTR(kIOHIDVendorIDKey),nv); CFDictionarySetValue(mt,CFSTR(kIOHIDProductIDKey),np);
    IOHIDManagerSetDeviceMatching(m,mt); IOHIDManagerRegisterInputReportCallback(m,cb,NULL);
    IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    if(IOHIDManagerOpen(m,kIOHIDOptionsTypeNone)){fprintf(stderr,"HID open failed\n");return 1;}

    struct termios orig,raw;
    if(!plain){ tcgetattr(0,&orig); raw=orig; raw.c_lflag&=~(ICANON|ECHO); raw.c_cc[VMIN]=0; raw.c_cc[VTIME]=0; tcsetattr(0,TCSANOW,&raw); }

    // 等第一帧，用它做初始中位
    double t0=now(); while(!fresh && now()-t0<3.0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,true);
    for(int i=0;i<5;i++){ ctr[i]=newv[i]; cur[i]=newv[i]; omin[i]=newv[i]; omax[i]=newv[i]; }

    int calibrated=1;
    while(!g_stop){
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,true);
        if(fresh){
            fresh=0;
            for(int i=0;i<5;i++){ cur[i]=newv[i];
                if(calibrated && labs(cur[i]-ctr[i])>40){ if(cur[i]<omin[i])omin[i]=cur[i]; if(cur[i]>omax[i])omax[i]=cur[i]; } }
        }
        if(!plain && isatty(0)){ char c; if(read(0,&c,1)==1){
                if(c=='c'){ for(int i=0;i<5;i++){ctr[i]=cur[i];omin[i]=cur[i];omax[i]=cur[i];} calibrated=1; }
                else if(c=='q') g_stop=1; } }
        if(!plain) printf("\033[H\033[2J");
        printf("DJI Motion Controller C5  VID 0x2CA3 PID 0x1020   1kHz HID GamePad\n");
        printf("────────────────────────────────────────────────────────────────────────\n");
        printf("%-11s %6s %7s  %8s  %-26s %s\n","axis","raw","center","norm","bar","observed min..max");
        for(int i=0;i<5;i++){
            double n=(double)(cur[i]-ctr[i])/1024.0; if(n>1)n=1; if(n<-1)n=-1;
            printf("%-11s %6ld %7ld  %+8.3f  ", NAM[i], cur[i], ctr[i], n);
            bars(cur[i],ctr[i]);
            printf(" %6ld..%6ld\n", omin[i], omax[i]);
        }
        printf("────────────────────────────────────────────────────────────────────────\n");
        printf("buttons: 0x%06x  ", btn);
        for(int i=0;i<24;i++) if(btn>>i&1) printf("#%d ", i+1);
        printf("\n\n[c] 以当前姿态为中立点(校准)   [q] 退出\n");
        fflush(stdout);
        if(plain) usleep(300000);
    }
    if(!plain){ tcsetattr(0,TCSANOW,&orig); printf("\033[H\033[2J"); }
    IOHIDManagerClose(m,kIOHIDOptionsTypeNone);
    printf("\n=== 本次观测到的行程（对照 X-Plane 标定）===\n");
    for(int i=0;i<5;i++) printf("  %-11s center=%6ld  min=%6ld  max=%6ld\n", NAM[i], ctr[i], omin[i], omax[i]);
    return 0;
}
