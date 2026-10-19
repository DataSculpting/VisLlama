/* Linux-only native boundary fixture. The real PowerShell/C# helper runs
 * unchanged, against only documented CUDA 12.4 identity exports. No GPU calls.
 * Driver handles deliberately differ from runtime ordinals. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static int mode(const char *s) {
    const char *v=getenv("VISLLAMA_CUDA_MOCK_CASE");return v && strcmp(v,s)==0;
}
static int count(int *n) {*n=mode("single")?1:mode("zero")?0:2;return mode("count-error")?35:0;}
static int bus(char *s,int len,int device) {
    if(mode("bus-error")) return 101;
    if(device<0 || device>1 || len<13) return 1;
    snprintf(s,len,"0000:%s:00.0",device==0?"0c":"43");return 0;
}
static int init(unsigned flags) {return mode("init-error")?100:flags;}
static int by_bus(int *device,const char *s) {
    if(mode("lookup-error")) return 101;
    if(strcmp(s,"0000:0c:00.0")==0) *device=91;
    else if(strcmp(s,"0000:43:00.0")==0) *device=27;
    else return 1;
    return 0;
}
static int uuid(unsigned char *bytes,int device) {
    if(mode("uuid-error")) return 999;
    if(device!=91 && device!=27) return 101;
    for(int j=0;j<16;j++) bytes[j]=(device==91?0x10:0x80)+j;
    return 0;
}
/* Windows UTF-16 path, not platform wchar_t (which is 32-bit on Linux). */
void *LoadLibraryW(const uint16_t *path) {
    char s[4096];int i=0;while(path[i] && i<4095) {s[i]=(char)path[i];i++;}s[i]=0;
    if(strstr(s,"cudart64") && !mode("load-error")) return (void*)1;
    if(strstr(s,"nvcuda.dll")) return (void*)2;
    return NULL;
}
void *GetProcAddress(void *dll,const char *name) {
    if(dll==(void*)1) {
        if(strcmp(name,"cudaGetDeviceCount")==0) return count;
        if(strcmp(name,"cudaDeviceGetPCIBusId")==0) return bus;
    }
    if(dll==(void*)2) {
        if(strcmp(name,"cuInit")==0) return init;
        if(strcmp(name,"cuDeviceGetByPCIBusId")==0) return by_bus;
        if(strcmp(name,"cuDeviceGetUuid_v2")==0 && !mode("missing-export")) return uuid;
    }
    return NULL;
}
