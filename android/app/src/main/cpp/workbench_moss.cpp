#include <jni.h>
#include <cstdlib>
#include <cstring>
#include "moss_transcribe_capi.h"
#include "common.hpp"
#include "ggml.h"
#include "backend.hpp"
#include "ggml-cpu.h"
extern "C" void wb_moss_profile_reset();
extern "C" void wb_moss_profile_get(uint64_t*);

// Only the serial worker in :moss owns this model. Never forward native logs:
// upstream errors may include paths, and future versions may print text.
static moss_transcribe_ctx* model = nullptr;
static void discard_mt(mt::mt_log_level, const char*, void*) {}
static void discard_ggml(ggml_log_level, const char*, void*) {}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_opensourceglasses_even_1g2_1r1_1poc_MossNative_load(
        JNIEnv* env, jobject, jstring path, jboolean use_gpu) {
    setenv("MTD_DEVICE", use_gpu ? "opencl" : "cpu", 1);
    setenv("MTD_THREADS", "4", 1);
    mt::set_log_callback(discard_mt, nullptr);
    ggml_log_set(discard_ggml, nullptr);
    const char* name = env->GetStringUTFChars(path, nullptr);
    if (!name) return false;
    moss_transcribe_capi_free(model);
    model = moss_transcribe_capi_load(name);
    env->ReleaseStringUTFChars(path, name);
    return model != nullptr && (!ggml_backend_is_cpu(mt::backend())) == bool(use_gpu);
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_opensourceglasses_even_1g2_1r1_1poc_MossNative_transcribe(
        JNIEnv* env, jobject, jstring path) {
    const char* name = env->GetStringUTFChars(path, nullptr);
    if (!name) return nullptr;
    wb_moss_profile_reset();
    char* text = moss_transcribe_capi_transcribe_path(model, name, 1024);
    env->ReleaseStringUTFChars(path, name);
    if (!text) return nullptr;
    const size_t length = strlen(text);
    if (length > 65536) { moss_transcribe_capi_free_string(text); return nullptr; }
    // Java's modified UTF-8 constructor would damage supplementary characters.
    jbyteArray bytes = env->NewByteArray(static_cast<jsize>(length));
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(length),
                           reinterpret_cast<const jbyte*>(text));
    moss_transcribe_capi_free_string(text);
    jclass cls = env->FindClass("java/lang/String");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V");
    return static_cast<jstring>(env->NewObject(cls, ctor, bytes, env->NewStringUTF("UTF-8")));
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_opensourceglasses_even_1g2_1r1_1poc_MossNative_profile(JNIEnv* env, jobject) {
    uint64_t values[5]; wb_moss_profile_get(values);
    jlong converted[5]; for (int i = 0; i < 5; ++i) converted[i] = values[i];
    auto result = env->NewLongArray(5); env->SetLongArrayRegion(result, 0, 5, converted);
    return result;
}
