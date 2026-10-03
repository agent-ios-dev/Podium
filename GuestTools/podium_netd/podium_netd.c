// iOS 6 guest tunnel. No simulated WLAN firmware is required: XNU's utun
// interface feeds IP packets to the host through a private emulator call.
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <errno.h>

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
    pid_t child=fork();
    if (!child) { execl("/usr/bin/uicache", "uicache", (char *)0); _exit(1); }
    int status=1; if(child>0) waitpid(child,&status,0);
    if(status==0) { FILE *f=fopen("/private/var/lib/podium-cydia-ready","w"); if(f) fclose(f); logline("Cydia uicache completed"); }
}
int main(void) {
    install_cydia();
    int tunnel=socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    struct ctl_info info={0}; strcpy(info.ctl_name,"com.apple.net.utun_control");
    if(tunnel<0 || ioctl(tunnel,CTLIOCGINFO,&info)) { logline("utun lookup failed"); return 1; }
    struct sockaddr_ctl ctl={0}; ctl.sc_len=sizeof(ctl); ctl.sc_family=AF_SYSTEM;
    ctl.ss_sysaddr=AF_SYS_CONTROL; ctl.sc_id=info.ctl_id;
    if(connect(tunnel,(struct sockaddr *)&ctl,sizeof(ctl))) { logline("utun connect failed"); return 1; }
    char name[IFNAMSIZ]={0}; socklen_t length=sizeof(name);
    if(getsockopt(tunnel,SYSPROTO_CONTROL,2,name,&length)) { logline("utun name failed"); return 1; }
    int config=socket(AF_INET,SOCK_DGRAM,0);
    struct ifaliasreq alias={0}; strcpy(alias.ifra_name,name);
    *(struct sockaddr_in *)&alias.ifra_addr=address("10.0.2.15");
    *(struct sockaddr_in *)&alias.ifra_broadaddr=address("10.0.2.2");
    *(struct sockaddr_in *)&alias.ifra_mask=address("255.255.255.255");
    if(ioctl(config,SIOCAIFADDR,&alias)) { logline("utun address failed"); return 1; }
    struct ifreq req={0}; strcpy(req.ifr_name,name); req.ifr_mtu=1400;
    ioctl(config,SIOCSIFMTU,&req); close(config);
    struct { struct rt_msghdr header; struct sockaddr_in destination,gateway,mask; } route={0};
    route.header.rtm_msglen=sizeof(route); route.header.rtm_version=RTM_VERSION;
    route.header.rtm_type=RTM_ADD; route.header.rtm_flags=RTF_UP|RTF_GATEWAY|RTF_STATIC;
    route.header.rtm_addrs=RTA_DST|RTA_GATEWAY|RTA_NETMASK; route.header.rtm_seq=1;
    route.destination=address("0.0.0.0"); route.gateway=address("10.0.2.2"); route.mask=address("0.0.0.0");
    int routing=socket(PF_ROUTE,SOCK_RAW,0);
    if(write(routing,&route,sizeof(route))<0) logline("default route failed"); close(routing);
    FILE *resolver=fopen("/private/etc/resolv.conf","w");
    if(resolver) { fputs("nameserver 10.0.2.2\n",resolver); fclose(resolver); }
    fcntl(tunnel,F_SETFL,O_NONBLOCK);
    logline("utun configured 10.0.2.15 -> 10.0.2.2");
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
