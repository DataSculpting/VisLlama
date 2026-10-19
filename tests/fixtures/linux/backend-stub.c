/* Synthetic backend dependency; no hardware validation. */
extern int cudaGetDeviceCount(int *);
int ggml_fixture_count(int *n) { return cudaGetDeviceCount(n); }
