# LiteRT-LM resolves its own Kotlin classes and members from
# liblitertlm_jni.so by name. The published AAR ships no consumer rules, so a
# minified release build renames them (Engine became g0.f) and drops others
# (Content, Contents$Companion). The JNI lookup then fails, the native layer
# calls back into ART with a pending exception, and ART aborts the :gemma
# process from nativeCreateConversation. Every transcript correction died that
# way in release builds while debug builds kept working.
-keep class com.google.ai.edge.litertlm.** { *; }
-keepclassmembers class com.google.ai.edge.litertlm.** { *; }

# Keep the Kotlin metadata the library reads back for its own types.
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations
-keepattributes InnerClasses,Signature,EnclosingMethod
