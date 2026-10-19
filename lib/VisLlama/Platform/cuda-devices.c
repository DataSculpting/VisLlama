/* GPL-3.0-only. Use the selected backend's runtime enumeration and join driver
 * UUIDs by PCI bus. No CUDA SDK or headers are required to build this helper. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { unsigned char bytes[16]; } gpu_uuid;
static void fail(const char *op,int code) {fprintf(stderr,"CUDA identity probe: %s failed (%d)\n",op,code);exit(1);}
int main(int argc,char **argv) {
 if(argc!=2 && argc!=3) fail("backend argument",-1);
 void *backend=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
 if(!backend) {fprintf(stderr,"CUDA backend load failed: %s\n",dlerror());return 1;}
 int (*count)(int *)=dlsym(backend,"cudaGetDeviceCount");
 int (*bus_id)(char *,int,int)=dlsym(backend,"cudaDeviceGetPCIBusId");
 if(!count||!bus_id) fail("selected backend runtime symbols (static/hidden runtime unsupported)",-1);
 if(argc==3) {
  Dl_info info;char *actual=NULL,*expected=realpath(argv[2],NULL);
  if(dladdr((void *)count,&info) && info.dli_fname) actual=realpath(info.dli_fname,NULL);
  if(!actual||!expected||strcmp(actual,expected)) fail("selected executable/runtime linkage mismatch",-1);
  free(actual);free(expected);
 }
 void *driver=dlopen("libcuda.so.1",RTLD_NOW|RTLD_LOCAL);
 if(!driver) {fprintf(stderr,"CUDA driver load failed: %s\n",dlerror());return 1;}
 int (*init)(unsigned int)=dlsym(driver,"cuInit");
 int (*by_bus)(int *,const char *)=dlsym(driver,"cuDeviceGetByPCIBusId");
 int (*uuid)(gpu_uuid *,int)=dlsym(driver,"cuDeviceGetUuid_v2");
 if(!uuid) uuid=dlsym(driver,"cuDeviceGetUuid");
 if(!init||!by_bus||!uuid) fail("driver symbols",-1);
 int rc=init(0);if(rc) fail("cuInit",rc);
 int n=0;rc=count(&n);if(rc) fail("cudaGetDeviceCount",rc);
 if(n<0||n>256) fail("device count",n);
 printf("[");
 for(int i=0;i<n;i++) {
  char bus[64]={0};int device=0;gpu_uuid id;
  rc=bus_id(bus,sizeof(bus),i);if(rc) fail("cudaDeviceGetPCIBusId",rc);
  for(size_t k=0;k<strlen(bus);k++) if(!strchr("0123456789abcdefABCDEF:.",bus[k])) fail("PCI bus format",-1);
  rc=by_bus(&device,bus);if(rc) fail("cuDeviceGetByPCIBusId",rc);
  rc=uuid(&id,device);if(rc) fail("cuDeviceGetUuid",rc);
  printf("%s{\"id\":\"CUDA%d\",\"bus\":\"%s\",\"uuid\":\"GPU-",i?",":"",i,bus);
  for(int j=0;j<16;j++) {if(j==4||j==6||j==8||j==10) printf("-");printf("%02x",id.bytes[j]);}
  printf("\"}");
 }
 printf("]\n");return 0;
}
