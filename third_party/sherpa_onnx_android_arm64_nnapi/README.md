# Work Bench Sherpa-ONNX arm64 NNAPI runtime

This local Flutter FFI package replaces the public
`sherpa_onnx_android_arm64` artifact. It keeps the same package name so the
upstream `sherpa_onnx` Dart API loads it without application-specific bindings.

The package pins:

- Sherpa-ONNX `v1.13.4`, commit
  `142807252687d81b40d6315f23470a1512a00de3`
- ONNX Runtime `v1.27.0`, commit
  `8f0278c77bf44b0cc83c098c6c722b92a36ac4b5`
- Android ABI `arm64-v8a`
- Android compile platform `android-27`

The Sherpa session factory is patched to register the ONNX Runtime NNAPI
execution provider with `NNAPI_FLAG_CPU_DISABLED`. This excludes NNAPI's
reference-CPU device. ONNX Runtime's own CPU execution provider remains
available for unsupported graph nodes and as the application-level fallback.
The Sherpa C API is compiled with speaker diarization enabled so the optional
CPU pyannote and TitaNet conversation worker can use the same pinned runtime.
The rebuild gate requires both the diarization and speaker-embedding creation
symbols.

The diarizer also skips speaker segments that are too short for an embedding
after clipping a padded segmentation window to the real audio. Upstream exits
the host process on that input, which can repeatedly crash the app when a
durable conversation job resumes. The patch preserves valid speaker indexes
and progress callbacks, and returns an empty result if no embeddings survive.

The application does not claim NNAPI merely because a session initializes.
Each VAD and transcription model is warmed up with ONNX Runtime profiling, and
`nnapi` is accepted only when the profile contains at least one node assigned
to `NnapiExecutionProvider`. A zero-node or unreadable profile falls back to
the normal Sherpa CPU provider.

Run `./tool/build_sherpa_nnapi_runtime.sh` from the repository root to rebuild
the three shared libraries and refresh `RUNTIME_MANIFEST.sha256`. The build
script uses only a fresh temporary source checkout and requires `ANDROID_NDK`
and `ANDROID_SDK` plus CMake 3.28 or newer. It builds ONNX Runtime itself with
CPU and NNAPI support, then links the patched Sherpa C API against that result.
Compiler source paths are mapped to generic `/usr/src/onnxruntime` and
`/usr/src/workbench/sherpa-onnx` prefixes. No model, device, user, or local
path is embedded in the checked-in instructions.

Set `DIARIZATION_TEST_OUTPUT` to an absolute temporary output path when rebuilding
to retain the native regression executable. Run it on an explicitly selected
Android device through the Work Bench app identity, with the pinned segmentation
and embedding model paths as its two arguments and the rebuilt ONNX Runtime on
its library path. It checks short and clipped segments mixed with valid speakers,
all-short input, preserved speaker indexes and progress, and a later valid call.
It uses synthetic in-memory samples and never records or plays audio.

Sherpa-ONNX is Apache-2.0 licensed. ONNX Runtime is MIT licensed. See
`THIRD_PARTY_NOTICES.md` at the repository root and the license files in this
directory.
