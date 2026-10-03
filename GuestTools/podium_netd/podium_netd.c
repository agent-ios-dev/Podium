// iOS 6 guest tunnel. No simulated WLAN firmware is required: XNU's utun
// interface feeds IP packets to the host through a private emulator call.
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <errno.h>
#include <dlfcn.h>
#include <netdb.h>
#include <sys/time.h>

// Public iOS SDKs omit these legacy kernel-control/routing declarations.
// Layouts/constants are the 32-bit XNU 2050 ABI, not the host Mac ABI.
#define SYSPROTO_CONTROL 2
#define AF_SYS_CONTROL 2
#define CTLIOCGINFO 0xc0644e03UL
#undef SIOCAIFADDR
#undef SIOCSIFMTU
#define SIOCAIFADDR 0x8040691aUL
#define SIOCSIFMTU 0x80206934UL
#define RTM_VERSION 5
#define RTM_ADD 1
#define RTF_UP 1
#define RTF_GATEWAY 2
#define RTF_STATIC 0x800
#define RTA_DST 1
#define RTA_GATEWAY 2
#define RTA_NETMASK 4
struct ctl_info { unsigned ctl_id; char ctl_name[96]; };
struct sockaddr_ctl { unsigned char sc_len,sc_family; unsigned short ss_sysaddr; unsigned sc_id,sc_unit,sc_reserved[5]; };
struct legacy_alias { char ifra_name[16]; struct sockaddr ifra_addr,ifra_broadaddr,ifra_mask; };
struct legacy_route { unsigned short rtm_msglen; unsigned char rtm_version,rtm_type; unsigned short rtm_index,padding; int rtm_flags,rtm_addrs,rtm_pid,rtm_seq,rtm_errno,rtm_use; unsigned rtm_inits,metrics[14]; };

static unsigned bridge(unsigned op, void *data, unsigned length) {
    register unsigned r0 __asm__("r0") = op;
    register void *r1 __asm__("r1") = data;
    register unsigned r2 __asm__("r2") = length;
    register unsigned call __asm__("r12") = 0x504f444e;
    __asm__ volatile("svc #0x80" : "+r"(r0) : "r"(r1), "r"(r2), "r"(call) : "r3", "memory", "cc");
    return r0;
}
static void logline(const char *text) { bridge(3, (void *)text, strlen(text)); }
static struct sockaddr_in address(const char *ip) {
    struct sockaddr_in a = {0}; a.sin_len = 16; a.sin_family = AF_INET;
    inet_pton(AF_INET, ip, &a.sin_addr); return a;
}
static void install_cydia(void) {
    if (access("/Applications/Cydia.app/Cydia", F_OK) || !access("/private/var/lib/podium-cydia-ready", F_OK)) return;
    pid_t setup=fork();
    if(!setup) { execl("/bin/bash","bash","/usr/libexec/cydia/startup",(char *)0); _exit(1); }
    int configured=1; if(setup>0) waitpid(setup,&configured,0);
    if(configured!=0) { logline("Cydia startup failed"); return; }
    pid_t child=fork();
    if (!child) { setgid(501); setuid(501); execl("/usr/bin/uicache", "uicache", (char *)0); _exit(1); }
    int status=1; if(child>0) waitpid(child,&status,0);
    if(status==0) { FILE *f=fopen("/private/var/lib/podium-cydia-ready","w"); if(f) fclose(f); logline("Cydia uicache completed"); }
    else logline("Cydia uicache failed");
}
static void publish(const char *key, const char *xml) {
    void *cf=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",RTLD_LAZY);
    void *sc=dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",RTLD_LAZY);
    if(!cf || !sc) { logline("SystemConfiguration unavailable"); return; }
    void *(*string)(void*,const char*,unsigned)=dlsym(cf,"CFStringCreateWithCString");
    void *(*data)(void*,const unsigned char*,long)=dlsym(cf,"CFDataCreate");
    void *(*plist)(void*,void*,unsigned long,void*,void*)=dlsym(cf,"CFPropertyListCreateWithData");
    void (*release)(void*)=dlsym(cf,"CFRelease");
    void *(*store)(void*,void*,void*,void*)=dlsym(sc,"SCDynamicStoreCreate");
    unsigned char (*set)(void*,void*,void*)=dlsym(sc,"SCDynamicStoreSetValue");
    if(!string||!data||!plist||!release||!store||!set) return;
    void *name=string(0,"Podium",0x08000100), *k=string(0,key,0x08000100);
    void *bytes=data(0,(const unsigned char*)xml,strlen(xml)), *value=plist(0,bytes,0,0,0);
    void *session=store(0,name,0,0);
    if(session && value && !set(session,k,value)) logline("Network state publication failed");
    if(session) release(session); if(value) release(value); release(bytes); release(k); release(name);
}
static void probe(void) {
    struct addrinfo hints={0}, *result=0; hints.ai_family=AF_INET; hints.ai_socktype=SOCK_STREAM;
    if(getaddrinfo("example.com","80",&hints,&result)) { logline("HTTP test DNS failed"); _exit(1); }
    int fd=socket(AF_INET,SOCK_STREAM,0); struct timeval timeout={20,0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    if(connect(fd,result->ai_addr,result->ai_addrlen)) { logline("HTTP test connect failed"); _exit(1); }
    freeaddrinfo(result);
    const char request[]="GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    write(fd,request,sizeof(request)-1); char body[4096]; int n=read(fd,body,sizeof(body));
    if(n>5 && !memcmp(body,"HTTP/",5)) logline("HTTP test received a real internet response");
    else logline("HTTP test response failed"); close(fd);
    void *cf=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",RTLD_LAZY);
    void *network=dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork",RTLD_LAZY);
    void *(*string)(void*,const char*,unsigned)=dlsym(cf,"CFStringCreateWithCString");
    void *(*urlCreate)(void*,void*,void*)=dlsym(cf,"CFURLCreateWithString");
    void *(*createRequest)(void*,void*,void*,void*)=dlsym(network,"CFHTTPMessageCreateRequest");
    void *(*streamCreate)(void*,void*)=dlsym(network,"CFReadStreamCreateForHTTPRequest");
    unsigned char (*openStream)(void*)=dlsym(cf,"CFReadStreamOpen");
    long (*readStream)(void*,unsigned char*,long)=dlsym(cf,"CFReadStreamRead");
    if(!cf||!network||!string||!urlCreate||!createRequest||!streamCreate||!openStream||!readStream) { logline("CFNetwork APIs unavailable"); _exit(1); }
    void *url=urlCreate(0,string(0,"http://example.com/",0x08000100),0);
    void *message=createRequest(0,string(0,"GET",0x08000100),url,string(0,"HTTP/1.1",0x08000100));
    void *stream=streamCreate(0,message);
    if(!stream||!openStream(stream)) { logline("CFNetwork open failed"); _exit(1); }
    int total=0;
    while(total<(int)sizeof(body)-1 && (n=readStream(stream,(unsigned char*)body+total,sizeof(body)-1-total))>0) total+=n;
    body[total]=0;
    if(strstr(body,"Example Domain")) logline("CFNetwork fetched Example Domain");
    else logline("CFNetwork page content failed");
    for(int i=0;i<100 && access("/private/var/lib/podium-cydia-ready",F_OK);++i) sleep(1);
    void *sbs=dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",RTLD_LAZY);
    int (*openURL)(void*,char)=dlsym(sbs,"SBSOpenSensitiveURLAndUnlock");
    void *(*frontmost)(void)=dlsym(sbs,"SBSCopyFrontmostApplicationDisplayIdentifier");
    unsigned char (*cstring)(void*,char*,long,unsigned)=dlsym(cf,"CFStringGetCString");
    void (*release)(void*)=dlsym(cf,"CFRelease");
    if(!openURL||!frontmost||!cstring||!release) { logline("Guest UI launch APIs unavailable"); _exit(1); }
    const char *urls[]={"http://example.com/","cydia://"};
    const char *apps[]={"com.apple.mobilesafari","com.saurik.Cydia"};
    for(int app=0;app<2;++app) {
        void *target=urlCreate(0,string(0,urls[app],0x08000100),0);
        openURL(target,1);
        int found=0;
        for(int i=0;i<40;++i) {
            sleep(1); void *identifier=frontmost(); char text[128]={0};
            if(identifier) { cstring(identifier,text,sizeof(text),0x08000100); release(identifier); }
            if(!strcmp(text,apps[app])) { found=1; logline(app ? "Cydia foreground" : "Safari foreground"); break; }
        }
        if(!found) logline(app ? "Cydia launch failed" : "Safari launch failed");
        sleep(app ? 15 : 20);
    }
    _exit(0);
}
static void audio_probe(void) {
    sleep(15);
    void *cf=dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",RTLD_LAZY);
    void *at=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_LAZY);
    void *(*fileURL)(void*,const unsigned char*,long,int)=dlsym(cf,"CFURLCreateFromFileSystemRepresentation");
    int (*createSound)(void*,unsigned int*)=dlsym(at,"AudioServicesCreateSystemSoundID");
    void (*playSound)(unsigned int)=dlsym(at,"AudioServicesPlaySystemSound");
    if(!fileURL||!createSound||!playSound) { logline("Audio APIs unavailable"); _exit(1); }
    const char *path="/private/var/tmp/podium-audio-test.wav";
    FILE *f=fopen(path,"wb");
    if(!f) _exit(1);
    unsigned int header[]={0x46464952,36+44100*4,0x45564157,0x20746d66,16,0x00020001,44100,44100*4,0x00100004,0x61746164,44100*4};
    fwrite(header,sizeof(header),1,f);
    for(int i=0;i<44100;++i) { short pair[2]={((i/50)&1)?3000:-3000,((i/50)&1)?3000:-3000}; fwrite(pair,sizeof(pair),1,f); }
    fclose(f);
    unsigned int sound=0;
    int status=createSound(fileURL(0,(const unsigned char*)path,strlen(path),0),&sound);
    char msg[128]; snprintf(msg,sizeof(msg),"Audio create status %d sound %u",status,sound); logline(msg);
    for(int i=0;i<3&&status==0;++i) { playSound(sound); logline("Audio test playback requested"); sleep(8); }
    _exit(0);
}
int main(void) {
    int tunnel=socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    struct ctl_info info={0}; strcpy(info.ctl_name,"com.apple.net.utun_control");
    if(tunnel<0 || ioctl(tunnel,CTLIOCGINFO,&info)) { logline("utun lookup failed"); return 1; }
    struct sockaddr_ctl ctl={0}; ctl.sc_len=sizeof(ctl); ctl.sc_family=AF_SYSTEM;
    ctl.ss_sysaddr=AF_SYS_CONTROL; ctl.sc_id=info.ctl_id;
    if(connect(tunnel,(struct sockaddr *)&ctl,sizeof(ctl))) { logline("utun connect failed"); return 1; }
    char name[IFNAMSIZ]={0}; socklen_t length=sizeof(name);
    if(getsockopt(tunnel,SYSPROTO_CONTROL,2,name,&length)) { logline("utun name failed"); return 1; }
    int config=socket(AF_INET,SOCK_DGRAM,0);
    struct legacy_alias alias={0}; strcpy(alias.ifra_name,name);
    *(struct sockaddr_in *)&alias.ifra_addr=address("10.0.2.15");
    *(struct sockaddr_in *)&alias.ifra_broadaddr=address("10.0.2.2");
    *(struct sockaddr_in *)&alias.ifra_mask=address("255.255.255.255");
    if(ioctl(config,SIOCAIFADDR,&alias)) { logline("utun address failed"); return 1; }
    struct ifreq req={0}; strcpy(req.ifr_name,name); req.ifr_mtu=1400;
    ioctl(config,SIOCSIFMTU,&req); close(config);
    struct { struct legacy_route header; struct sockaddr_in destination,gateway,mask; } route={0};
    route.header.rtm_msglen=sizeof(route); route.header.rtm_version=RTM_VERSION;
    route.header.rtm_type=RTM_ADD; route.header.rtm_flags=RTF_UP|RTF_GATEWAY|RTF_STATIC;
    route.header.rtm_addrs=RTA_DST|RTA_GATEWAY|RTA_NETMASK; route.header.rtm_seq=1;
    route.destination=address("0.0.0.0"); route.gateway=address("10.0.2.2"); route.mask=address("0.0.0.0");
    int routing=socket(PF_ROUTE,SOCK_RAW,0);
    if(write(routing,&route,sizeof(route))<0) logline("default route failed"); close(routing);
    FILE *resolver=fopen("/private/etc/resolv.conf","w");
    if(resolver) { fputs("nameserver 10.0.2.2\n",resolver); fclose(resolver); }
    char xml[1024];
    snprintf(xml,sizeof(xml),"<plist version=\"1.0\"><dict><key>Addresses</key><array><string>10.0.2.15</string></array><key>SubnetMasks</key><array><string>255.255.255.255</string></array><key>Router</key><string>10.0.2.2</string><key>InterfaceName</key><string>%s</string></dict></plist>",name);
    publish("State:/Network/Service/Podium/IPv4",xml);
    snprintf(xml,sizeof(xml),"<plist version=\"1.0\"><dict><key>PrimaryInterface</key><string>%s</string><key>PrimaryService</key><string>Podium</string><key>Router</key><string>10.0.2.2</string></dict></plist>",name);
    publish("State:/Network/Global/IPv4",xml);
    const char dns[]="<plist version=\"1.0\"><dict><key>ServerAddresses</key><array><string>10.0.2.2</string></array></dict></plist>";
    publish("State:/Network/Service/Podium/DNS",dns); publish("State:/Network/Global/DNS",dns);
    fcntl(tunnel,F_SETFL,O_NONBLOCK);
    logline("utun configured 10.0.2.15 -> 10.0.2.2");
    if(fork()==0) { sleep(10); install_cydia(); _exit(0); }
    if(bridge(4,0,0) && fork()==0) { sleep(3); probe(); }
    if(bridge(4,0,0) && fork()==0) { audio_probe(); }
    unsigned char packet[65536];
    for(;;) {
        int n; while((n=read(tunnel,packet,sizeof(packet)))>4) bridge(1,packet+4,n-4);
        while((n=bridge(2,packet+4,sizeof(packet)-4))>0) {
            packet[0]=packet[1]=packet[2]=0; packet[3]=AF_INET;
            if(write(tunnel,packet,n+4)<0) logline("utun inject failed");
        }
        usleep(10000);
    }
}
