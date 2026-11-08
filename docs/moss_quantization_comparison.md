# MOSS Q4_0 comparison on Android

These are historical build-169 measurements. The newer native adapter has
separate [build-180 results](moss_english_validation.md#build-180-smaller-gpu-token-table);
do not assume the speed difference below applies to every runtime or workload.

Q4_0 is an optional trial setting. Q5_K remains the default because the smaller
model made a repeated word error in the longer fixture that Q5_K decoded
correctly. New installations and missing/unknown weight preferences retain
Q5_K. Changing weights while disconnected preserves both installed models and
all captured audio; the choice persists across launches.

## Matched saved-WAV results

The representative RedMagic / Adreno 840 phone ran a single serial OpenCL
worker with four CPU preprocessing threads. Android reported thermal status 0
before and after every group. The app was stopped after verifying input was
inactive, so another model instance could not compete for GPU resources.

The order was Q4_0, Q5_K, then Q4_0 again. Each group loaded its model once,
warmed up on the identical first WAV, and retained three complete timed rounds.
The repeat after Q5_K checks that the smaller model's speed advantage was not
merely from being measured first. Times below are median inference times;
model loading, installation, and weight hashing are excluded.

| Input duration | Q5_K | Q4_0 | Q4_0 follow-up | Q5_K WER | Q4_0 WER |
| --- | --- | --- | --- | --- | --- |
| 8.9 s | 9.33 s | 6.53 s | 6.29 s | 7.69% | 7.69% |
| 11.0 s | 11.33 s | 7.97 s | 7.73 s | 0.00% | 0.00% |
| 37.7 s | 29.01 s | 21.44 s | 21.43 s | 0.00% | 4.92% |

The 8.9-second input is an archived app-private speech recording of the fixed
public Kokoro safety phrase. Its original acoustic setup was not rerun. Both
models made the same one-word error in that isolated recording. The 11-second
input is the public whisper.cpp reference used in the earlier qualification.
The 37.7-second fixture synthetically repeats the archived recording three
times and appends the public reference as a distinct final tail. It is not a
natural long conversation or a newly validated long G2 capture. Q4_0 repeated
the short recording's error three times; Q5_K resolved those words with the
longer context. The complete final tail was retained by both models in every
trial. All trials also satisfied the application's timestamp/speaker framing
and bounds contract.

These are small diagnostic fixtures, not a broad model-quality ranking.
Byte-identical inputs, expected text, SHA-256 manifests, all outputs, all trial
timings, native profiles, memory samples, thermal snapshots, and Android
low-memory/process-exit logs are retained as private evidence outside the
repository. No source audio, private transcript, or device identifier is
included here. The archive's original acoustic provenance and fresh transport,
VAD, capture-safety, and recovery behavior are not established by this decode
comparison.

## Provider qualification and memory

Both models used the same pinned native runtime and strict provider adapter
from [the original qualification](moss_gpu_qualification.md). Q4_0 independently
completed with positive GPU kernel-event timings and zero CPU graph nodes.
Ready/completed markers identify the actual model and provider. The archived,
public, and long cases assigned 36,870, 56,570, and 184,839 graph nodes to the
GPU respectively. No probe process died during the comparison. No CPU fallback
was enabled or inferred from the presence of GPU hardware.

Sampled peak PSS was about 779 MiB for Q4_0 and 798 MiB for Q5_K, with zero
sampled process swap. Q4_0 had transient sampled RSS peaks of 1,311–1,361 MiB,
versus 807 MiB for Q5_K in this run. Sampling was not simultaneous between
status and memory-map reads; these are observations, not a guarantee of lower
peak memory. The smaller download does not eliminate the F32 embedding table,
KV cache, or encoder activation allocations, and process RSS/PSS do not fully
account for vendor GPU memory. This is not a continuous-operation memory soak.

Q4_0 contains 535,272,448 bytes, SHA-256
`571dc83e4dd4567bcf2070151d209454be4f6396d98b590ab92dfb49cddde178`.
Q5_K contains 648,174,592 bytes, SHA-256
`6fe985fd9a9cd043728f7be49659d10de6901872dad73b49e3c30e1340582e79`.
Both are pinned to publisher revision
`54e4bbd17da3f84adf1c1bcf7791b9b9266f741e`, checked on the host and phone.

## Try the smaller weights

Install the optional Q4_0 file into its own app-private directory:

```sh
python3 tool/stage_android_moss_model.py --device <android-serial> --quantization q4_0
```

Then disconnect input and choose Tools → Audio processing → MOSS weights →
Q4_0. Q5_K remains installed and selectable. Each pipeline, result, and private
metadata record uses the selected model ID and SHA-256 rather than a shared
hardcoded Q5_K label. A failed integrity check or load preserves the previous
selection. Restored jobs can finish locally but never route commands.

## Installed build validation

Build 169 includes both weight choices and preserves Q5_K as the default. The
optional Q4_0 file was staged through the app identity and checked against its
pinned SHA-256. The exact arm64 library extracted from the APK completed a
separate warm-up plus three timed Q4_0 reference decodes: median 7.80 seconds,
zero word errors, 56,570 GPU nodes, zero CPU nodes, and positive hardware kernel
events on every decode. Its SHA-256 is
`908db68ba1d19780edb845a4d74a0d3389b6e6d5043048001fc8ac73a0c71b17`,
identical to the previously qualified packaged runtime.

The phone-sized settings layout was inspected. The on-device weights selector
successfully loaded Q4_0 on OpenCL GPU and was then returned to Q5_K on OpenCL
GPU. Both models remain installed. Analysis is clean and all 431 Flutter tests
pass, including default-preference migration, weight selection, model/hash
attribution, queue recovery, and the existing primary audio isolation checks.
No fresh acoustic G2 pass is claimed by this saved-file comparison.
