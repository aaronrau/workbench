#!/usr/bin/env bash
set -euo pipefail

SHERPA_REPOSITORY=https://github.com/k2-fsa/sherpa-onnx.git
SHERPA_REVISION=142807252687d81b40d6315f23470a1512a00de3
ONNXRUNTIME_REPOSITORY=https://github.com/microsoft/onnxruntime.git
ONNXRUNTIME_REVISION=8f0278c77bf44b0cc83c098c6c722b92a36ac4b5
ANDROID_PLATFORM=android-27
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE_DIR="$PROJECT_DIR/third_party/sherpa_onnx_android_arm64_nnapi"
LIB_DIR="$PACKAGE_DIR/android/src/main/jniLibs/arm64-v8a"
PATCH_DIRECTORY="$PACKAGE_DIR/patches"

if [ -z "${ANDROID_NDK:-}" ] || [ ! -d "$ANDROID_NDK" ]; then
  echo "Set ANDROID_NDK to an installed Android NDK directory." >&2
  exit 1
fi
if [ -z "${ANDROID_SDK:-}" ] || [ ! -d "$ANDROID_SDK" ]; then
  echo "Set ANDROID_SDK to an installed Android SDK directory." >&2
  exit 1
fi
CMAKE_BIN=${CMAKE_BIN:-$(command -v cmake || true)}
CTEST_BIN=${CTEST_BIN:-$(command -v ctest || true)}
if [ -z "$CMAKE_BIN" ] || [ ! -x "$CMAKE_BIN" ]; then
  echo "Set CMAKE_BIN to CMake 3.28 or newer." >&2
  exit 1
fi
if [ -z "$CTEST_BIN" ] || [ ! -x "$CTEST_BIN" ]; then
  echo "Set CTEST_BIN to the ctest paired with CMake." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required by the ONNX Runtime build." >&2
  exit 1
fi
for required_tool in awk head make nm rg sha256sum sort strings; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "$required_tool is required." >&2
    exit 1
  fi
done
CMAKE_VERSION=$("$CMAKE_BIN" --version | awk 'NR == 1 { print $3 }')
if [ "$(printf '3.28\n%s\n' "$CMAKE_VERSION" | sort -V | head -n 1)" != "3.28" ]; then
  echo "CMake 3.28 or newer is required; found $CMAKE_VERSION." >&2
  exit 1
fi
CMAKE_DIRECTORY=$(dirname -- "$CMAKE_BIN")

BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workbench-sherpa-nnapi.XXXXXX")
cleanup() {
  case "$BUILD_ROOT" in
    "${TMPDIR:-/tmp}"/workbench-sherpa-nnapi.*)
      rm -rf -- "$BUILD_ROOT"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

git clone --filter=blob:none --no-checkout "$ONNXRUNTIME_REPOSITORY" \
  "$BUILD_ROOT/onnxruntime"
git -C "$BUILD_ROOT/onnxruntime" checkout --detach "$ONNXRUNTIME_REVISION"
git -C "$BUILD_ROOT/onnxruntime" submodule update \
  --init --recursive --depth 1

ONNXRUNTIME_BUILD="$BUILD_ROOT/onnxruntime-build"
ONNXRUNTIME_INSTALL="$BUILD_ROOT/onnxruntime-install"
"$BUILD_ROOT/onnxruntime/build.sh" \
  --build_dir "$ONNXRUNTIME_BUILD" \
  --config Release \
  --android \
  --android_sdk_path "$ANDROID_SDK" \
  --android_ndk_path "$ANDROID_NDK" \
  --android_abi arm64-v8a \
  --android_api 27 \
  --use_nnapi \
  --nnapi_min_api 27 \
  --build_shared_lib \
  --skip_tests \
  --parallel 4 \
  --cmake_path "$CMAKE_BIN" \
  --ctest_path "$CTEST_BIN" \
  --cmake_extra_defines \
    "CMAKE_C_FLAGS=-ffile-prefix-map=$BUILD_ROOT/onnxruntime=/usr/src/onnxruntime -ffile-prefix-map=$ONNXRUNTIME_BUILD=/usr/src/onnxruntime-build" \
    "CMAKE_CXX_FLAGS=-ffile-prefix-map=$BUILD_ROOT/onnxruntime=/usr/src/onnxruntime -ffile-prefix-map=$ONNXRUNTIME_BUILD=/usr/src/onnxruntime-build" \
    onnxruntime_BUILD_UNIT_TESTS=OFF
"$CMAKE_BIN" --install "$ONNXRUNTIME_BUILD/Release" \
  --prefix "$ONNXRUNTIME_INSTALL"

git clone --filter=blob:none --no-checkout "$SHERPA_REPOSITORY" \
  "$BUILD_ROOT/sherpa-onnx"
git -C "$BUILD_ROOT/sherpa-onnx" checkout --detach "$SHERPA_REVISION"
for patch_file in "$PATCH_DIRECTORY"/*.patch; do
  git -C "$BUILD_ROOT/sherpa-onnx" apply --check "$patch_file"
  git -C "$BUILD_ROOT/sherpa-onnx" apply "$patch_file"
done

# Optionally retain the model-backed native regression executable for a
# separately selected device. Its synthetic samples never leave memory.
if [ -n "${DIARIZATION_TEST_OUTPUT:-}" ]; then
  cp "$PACKAGE_DIR/tests/diarization_short_segments_test.cc" \
    "$BUILD_ROOT/sherpa-onnx/workbench-diarization-short-segments-test.cc"
  cat >> "$BUILD_ROOT/sherpa-onnx/CMakeLists.txt" <<'CMAKE'

add_executable(workbench-diarization-short-segments-test
  workbench-diarization-short-segments-test.cc)
target_include_directories(workbench-diarization-short-segments-test
  PRIVATE ${PROJECT_SOURCE_DIR})
target_link_libraries(workbench-diarization-short-segments-test sherpa-onnx-core)
CMAKE
fi

(
  cd "$BUILD_ROOT/sherpa-onnx"
  PATH="$CMAKE_DIRECTORY:$PATH" \
  ANDROID_NDK="$ANDROID_NDK" \
  BUILD_SHARED_LIBS=ON \
  SHERPA_ONNX_ANDROID_PLATFORM="$ANDROID_PLATFORM" \
  SHERPA_ONNXRUNTIME_LIB_DIR="$ONNXRUNTIME_INSTALL/lib" \
  SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ONNXRUNTIME_INSTALL/include/onnxruntime" \
  SHERPA_ONNX_ENABLE_BINARY=OFF \
  SHERPA_ONNX_ENABLE_C_API=ON \
  SHERPA_ONNX_ENABLE_JNI=OFF \
  SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
  SHERPA_ONNX_ENABLE_TTS=OFF \
    ./build-android-arm64-v8a.sh
)

RUNTIME_BUILD_LIB="$BUILD_ROOT/sherpa-onnx/build-android-arm64-v8a/install/lib"
if [ -n "${DIARIZATION_TEST_OUTPUT:-}" ]; then
  install -m 0755 \
    "$BUILD_ROOT/sherpa-onnx/build-android-arm64-v8a/bin/workbench-diarization-short-segments-test" \
    "$DIARIZATION_TEST_OUTPUT"
fi
nm -D "$RUNTIME_BUILD_LIB/libonnxruntime.so" |
  rg --quiet 'OrtSessionOptionsAppendExecutionProvider_Nnapi'
nm -D "$RUNTIME_BUILD_LIB/libsherpa-onnx-c-api.so" |
  rg --quiet 'SherpaOnnxCreateOfflineSpeakerDiarization'
nm -D "$RUNTIME_BUILD_LIB/libsherpa-onnx-c-api.so" |
  rg --quiet 'SherpaOnnxCreateSpeakerEmbeddingExtractor'
if strings "$RUNTIME_BUILD_LIB/libonnxruntime.so" \
    "$RUNTIME_BUILD_LIB/libsherpa-onnx-c-api.so" |
    rg --fixed-strings --quiet "$BUILD_ROOT"; then
  echo "Native libraries retained a temporary build path." >&2
  exit 1
fi

mkdir -p "$LIB_DIR"
for library in \
  libonnxruntime.so \
  libsherpa-onnx-c-api.so \
  libsherpa-onnx-cxx-api.so
do
  install -m 0644 \
    "$RUNTIME_BUILD_LIB/$library" \
    "$LIB_DIR/$library"
done

(
  cd "$PACKAGE_DIR"
  sha256sum \
    android/src/main/jniLibs/arm64-v8a/libonnxruntime.so \
    android/src/main/jniLibs/arm64-v8a/libsherpa-onnx-c-api.so \
    android/src/main/jniLibs/arm64-v8a/libsherpa-onnx-cxx-api.so \
    > RUNTIME_MANIFEST.sha256
)

echo "Rebuilt the pinned Work Bench Sherpa-ONNX arm64 NNAPI runtime."
