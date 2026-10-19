/* Synthetic runtime/driver for Linux helper ABI tests. No hardware validation. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { unsigned char bytes[16]; } gpu_uuid;
#if defined(SERVER)
extern int ggml_fixture_count(int *);
int main(void) { int n=0;if(ggml_fixture_count(&n))return 1;printf("CUDA0: Same card\nCUDA1: Same card\n");return n==2?0:1; }
#elif defined(DRIVER)
int cuInit(unsigned int flags) { (void)flags;return 0; }
int cuDeviceGetByPCIBusId(int *id,const char *bus) { *id=strstr(bus,"43:")?1:0;return 0; }
int cuDeviceGetUuid_v2(gpu_uuid *id,int dev) { memset(id->bytes,dev?0xbb:0xaa,16);return 0; }
#else
int cudaGetDeviceCount(int *n) { if(getenv("VISLLAMA_TEST_PROBE_FAIL"))return 999;*n=2;return 0; }
int cudaDeviceGetPCIBusId(char *bus,int len,int dev) { snprintf(bus,len,"0000:%s:00.0",dev?"0c":"43");return 0; }
#endif
