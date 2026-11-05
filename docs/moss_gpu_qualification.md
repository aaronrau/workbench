# MOSS Android OpenCL development qualification

The tested target is a representative RedMagic phone with an Adreno 840 GPU,
Android 16 / API 36. This qualifies only this device family, model, and runtime
combination. Repeat the gate after changing device family, OS, model, runtime,
or the native adapter. VAD is a separate CPU worker and has no GPU claim.

## Runtime and proof

- MOSS runtime: `190a569c13b4b247450f2fb3b2a431244e84833e`.
- ggml: `eced84c86f8b012c752c016f7fe789adea168e1e`.
- Model: MOSS 0.9B Q5_K, 648,174,592 bytes, SHA-256
  `6fe985fd9a9cd043728f7be49659d10de6901872dad73b49e3c30e1340582e79`.
- Khronos OpenCL headers: `82f60316cc142e7b21dc1d8983b26de18858fbd9`.
- Adapter: `strict-provider-1`, implemented in `moss_backend.cpp`.
- App integration: development build 168; native qualification also uses the
  opt-in `WORKBENCH_MOSS_BUILD_PROBE` target with the same pinned sources.

The binary statically includes and registers ggml's OpenCL backend, embeds its
Adreno kernels, and opens the phone's public vendor OpenCL library. It checks
that the selected device is a GPU. It checks each non-metadata graph node for
provider support, allocates the graph only on that backend, and executes it
without a CPU scheduler or fallback device. An unsupported graph fails.

The pinned Q5_K token embedding cannot use OpenCL GET_ROWS directly. Loading
expands that one table to its exact dequantized F32 values before GPU upload;
all model graph operations, including embedding lookup and the tied output
head, then run on the GPU. Host mel preprocessing, tokenization, weight
conversion, and greedy token selection remain host operations.

Native graph assignment counters are paired with actual OpenCL kernel event
start/end timestamps. A successful 11-second decode reported 56,570 GPU graph
nodes, **zero CPU graph nodes**, 48,893 GPU kernel events, and 6.46 seconds of
aggregate GPU event time. Ready/completed markers identify the owning provider.
The app rejects a GPU completion without positive GPU nodes and timing events,
or with any CPU nodes. Profiling retains bounded numeric aggregates; it writes
no tensor dumps or trace CSVs. Each private `.moss.json` records the model and
runtime hashes/revisions, app build, Android version, provider, and profile.

## Saved-file measurements

These are development probe measurements with four CPU threads, a serial
worker, and Android thermal status 0 before and after each trial. They exclude
cold model load. They are single trials, not repeated medians, a sustained
operation qualification, or a ranking of recognizers on physical G2 audio.

The source is the public whisper.cpp [JFK sample](https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav),
SHA-256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
CPU and GPU received identical source bytes. The long fixture repeats that
same source three times; it is synthetic and does not test real speaker changes.

| Input | Provider | Decode | Word error rate | Final words covered |
| --- | --- | --- | --- | --- |
| 3 seconds, cropped sample | OpenCL | 5.70 s | Not scored | Not scored |
| 11 seconds | CPU | 17.30 s | 0% | Yes |
| Same 11 seconds | OpenCL | 8.61 s | 0% | Yes |
| 16 seconds, extended sample | OpenCL | 10.96 s | Not scored | Not scored |
| 33 seconds, repeated sample | OpenCL | 21.36 s | 0% | Yes |

Sampled peak process RSS was approximately 803–805 MiB for the GPU cases and
905 MiB for CPU, with zero sampled process swap. These RSS values exclude
vendor GPU allocations and are not total application memory measurements.
Short and medium cases reported 18,746 and 90,454 GPU graph nodes respectively;
the long case reported 173,807. All reported zero CPU graph nodes.

Vulkan trials failed with device loss or stalled encoder execution, including
with newer shaders; it is not offered as a working backend. An experimental
fused encoder-attention trial was slower and changed the output, so the app
keeps the tested F32 manual attention graph. None of those failures is counted
as a successful accelerator trial.

## Live behavior and limits

MOSS exposes file-based inference, not incremental encoder state. Its frontend
pads short input to 30 seconds. Repeated very short or overlapping full-model
requests therefore waste work. The live path uses CPU Silero VAD, approximately
800 ms of quiet to close an utterance, an eight-second preferred word boundary,
and a twelve-second hard limit. Only hard rollover adds one second of overlap;
the existing turn assembler removes exact boundary overlap and defers command
routing until the final chunk. Anonymous speaker labels remain chunk-local.

Newly captured jobs take priority over recovered files. Recovered work starts
only after input has been inactive for 30 seconds; connecting, microphone
capture, or arriving PCM pauses that recovery dispatch. An active live decode remains serial. Starting input cancels an active
recovered decode in the isolated MOSS process, preserves its queued WAV, and
reloads the worker for live work. Malformed deterministic output is preserved
without repeated identical inference. WAVs remain durable throughout.

Physical Kokoro evidence is separate from the table above. The first build-165
trial passed the required reconnect preflight and playback markers, but G2 audio
summaries stopped during playback. It failed transport/activity and produced
no scorable transcript. That failed trial is retained as private temporary test
evidence. It is not a recognition-accuracy pass, and saved-WAV GPU qualification
must not be presented as a successful acoustic run.

The second trial, on build 166 with recovery dispatch paused during listening,
failed the fresh-audio connection preflight. Its computer fixture was never
played. Both trials are retained (0/2 acoustic passes); no G2 end-to-end accuracy
claim is made. Saved-file acceleration and the 429 passing Flutter tests are
separate evidence. Build 168 adds partial-WAV recovery isolation, recovered-job preemption, and tests that
recovered VAD segments cannot route commands; it leaves the native GPU graph
and live capture/VAD implementation from build 166 unchanged.

Final installation reports version name `1.0.0`, build `168`. On-device settings
were switched to CPU and back to OpenCL; each produced the matching native
ready marker, and the final loaded provider is OpenCL. The packaged arm64 MOSS
library SHA-256 is `908db68ba1d19780edb845a4d74a0d3389b6e6d5043048001fc8ac73a0c71b17`, unchanged from builds 166 and 167. The
application also completed GPU inference on build 165 with positive hardware
kernel timings and zero CPU graph nodes; malformed legacy noise-window output
was preserved rather than accepted as an accuracy result.

Q4_0 was separately profiled for the optional build-169 weights selector; see
[the quantization comparison](moss_quantization_comparison.md). That comparison
preserves the Q5_K default and records the smaller model's accuracy tradeoff.
