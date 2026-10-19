// sherpa_inference has no native code of its own: the engine is the prebuilt
// SherpaEngine.framework (native/llama/build_ios.sh), opened from Dart with
// DynamicLibrary.open('SherpaEngine.framework/SherpaEngine'). SwiftPM and
// CocoaPods need at least one source file in the plugin target; this one also
// records at build time whether the engine was linked, for diagnostics.
#include "sherpa_inference.h"

int sherpa_inference_engine_linked(void) {
#if SHERPA_INFERENCE_HAS_ENGINE
  return 1;
#else
  return 0;
#endif
}
