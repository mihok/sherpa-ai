# LiteRT-LM calls back into Kotlin from JNI (LiteRtLmJni callbacks, Message/Content/ToolCall built from native
# JSON) and its @Tool reflection path uses kotlin-reflect. Keep the package intact under R8 (UNVERIFIED which
# members are strictly needed; the library ships no consumer rules of its own).
-keep class com.google.ai.edge.litertlm.** { *; }
-dontwarn com.google.ai.edge.litertlm.**
