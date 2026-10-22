# Keep rules for apps that shrink with R8 (Flutter release builds do).
#
# The JNI shim (src/main/cpp/sherpa_jni.c) finds these by name in JNI_OnLoad:
# FindClass + RegisterNatives on NativeEngine, the (int, byte[]) constructor
# of EngineError, and ProgressSink.onProgress(float). Only native code calls
# the last two, so without these rules R8 removes or renames them and the
# engine fails to load in release builds.
-keep class io.github.mihok.sherpa_inference.engine.NativeEngine {
    native <methods>;
}
-keep class io.github.mihok.sherpa_inference.engine.EngineError {
    <init>(int, byte[]);
}
-keep interface io.github.mihok.sherpa_inference.engine.ProgressSink {
    boolean onProgress(float);
}
-keep class * implements io.github.mihok.sherpa_inference.engine.ProgressSink {
    boolean onProgress(float);
}
