# Strata configuration fixtures

`strata-iq3_xxs.json` is a regression configuration with Windows paths, combined
pack/native/PLE inputs, expert settings, speculation/MTP, context/cache and
CUDA/GPU metadata. These paths are literal test inputs, not bundled model data
or host configuration. The fixture contains no credentials and does not establish
hardware compatibility. Portable Create-mode tests use temporary files.

`strata-definition-1.2.json` is VisLlama's unchanged bundled Strata definition from
1.5.9. It tests reviewed default-definition updates and preservation of locally
edited rules. It is intentional historical regression input covered by the
project's GPLv3 and separate additional terms.
