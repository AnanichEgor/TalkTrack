# Local inference

`Packages/TalkTrackInference` contains typed MLX adapters. The app should own one
`InferenceRuntime` and route installation preparation, model execution and removal
through it. AppKit views receive Sendable values; model objects and GPU arrays
remain inside their owning actors. Native capture and processing integration are
still tracked separately in OpenSpec.

| Role | Adapter | Bounded input / output |
| --- | --- | --- |
| Live / final ASR | `QwenSpeechAdapter.transcribe` | Mono finite 16 kHz PCM, 0.1–30 seconds; complete text or an error |
| Forced alignment | `QwenSpeechAdapter.align` | Same PCM bound; supplied language/text; word intervals |
| Segmentation | `SpeakerInferenceAdapter.segment` | 0.1–10 seconds; bounded window-local speaker slots |
| Voice embedding | `SpeakerInferenceAdapter.embed` | 1–10 seconds; 256 finite normalized values and model provenance |
| Summary / translation / correction | `QwenTextAdapter.generate` | Actual chat-formatted token budget including output reserve; complete text or an error |

The bundled `ModelCatalog` records six active immutable checkpoint revisions plus
the retained legacy text manifest, required runtime files, hashes, sizes and upstream licenses. Role settings select an
immutable `ModelSnapshot`; runtime resolution rejects a mismatch rather than
silently changing an active job's model. The three text roles reuse one physical
installation. New text jobs use `mlx-community/Qwen3.5-9B-OptiQ-4bit` at
`890b4c43f99ff392819d83605f7b1e59fa9688aa`; existing 35B jobs resolve their exact
legacy snapshots and keep their installed weights. The standard LM 3.31.4 dense
Qwen3.5 loader reads mixed affine 4/8-bit parameters from the two root shards.
Optional MTP and vision weights are excluded from the text installation.
Tokenizer chat formatting is supplied by the pinned checkpoint,
with thinking disabled and no tools. Tool-specific prompts and validation belong
to later processing stages.

All runtime assets, generated tokenizer data and download partials stay under
`~/Library/Application Support/TalkTrack/Models`. `ModelDownloadFiles` issues an
opaque `ModelLocalDirectory` capability after readiness/integrity verification.
Loading revalidates the capability; there is no public arbitrary-directory model
entry point. The explicit local/offline Hub parser has no shared cache. Leases
hold installation locks until GPU work and model cleanup finish. SHA/Git-blob
verification reads 1 MiB blocks and drains Foundation temporary buffers per block.

`InferenceRuntime` serializes heavy operations and unloads background models between roles.
During capture only the small live ASR/segmentation/embedding cohort stays
resident; `endCapture` joins unloading before background admission. Capture
requests cancel/join current work, defer background jobs and issue a live-inference
lease. Ending capture invalidates stale live work. Audio writing must remain
independent of waiting for this lease. Deletion waits behind the active operation
and cancels/joins any installation before removing owned files.

`SystemDiarizationSession` now processes committed system audio through this
runtime with bounded windows and clean-only embeddings. One session per meeting
job retains same-day clusters across recordings; IDs are independent of local
segmentation slots. Saved-name calibration retains its own task.

`makeLiveSession` now supplies capture-priority rolling ASR and provisional
speakers with bounded PCM/queues, incremental refinements, overlap deduplication
and durable-audio-independent failure states. Finish/cancel the live session
before calling `endCapture`. The paced EN/RU dual-AAC/ASR/speaker workload passed
task 5.3.
Hardware PCM integration remains separate from this synthetic capture worker.

`FinalTranscriptionPipeline` now stages stronger ASR, original-word alignment,
speaker candidates and indexed spelling correction through the same runtime.
SQLite checkpoints commit each stage atomically and retries retain immutable
settings and previous transcript heads. Exact ASR token surfaces survive the
aligner's punctuation normalization; correction keeps original timing. Task 5.4
passed the actual offline EN/RU correction and checkpoint/relaunch gate on
2026-10-09 with the selected 9B model. The earlier 35B memory refusal is retained
as historical evidence.

`runAndPublish` additionally commits the validated revision through SessionStore,
preserving confirmed names only when source intervals and compatible clean voice
evidence agree. Splits, merges and uncertain voices produce unknown labels and
durable review requests. Task 5.5 passed deterministic publication/reconciliation
fixtures; actual text-model staging/correction subsequently passed task 5.4.

Text requests are admitted by the Mac's RAM, not by currently free memory (see below).
Settings persist Auto, 4K, 8K, 16K, 32K and 64K (K = 1,024 tokens),
defaulting to 32K, with 64K as the maximum offered size. The user removed
the 128K option on 2026-10-08. The budget includes all chat-formatted input and reserved output.
Auto selects the smallest offered size that fits the tokenizer's exact input count
plus a task-specific response reserve. Summary reserves equal the input count,
from 1,024 to 8,192 tokens (at most half of a manual context); translation
estimates four times the input count and correction 2.5 times it. All reserves
were doubled at the user's request on 2026-10-14. These are heuristics, not
guaranteed language ratios. Responses estimated above the 16,384-token output
cap require partitioning. Callers can supply an explicit bounded output reserve.
Requests exceeding the selected budget, or 64K in Auto, require full-content
partitioning by the later text pipeline; this adapter never truncates the input.
`ProcessingPreferences.snapshot()` captures the preference for new jobs; changing
it does not mutate existing job settings. Legacy 129,024/131,072-token snapshots
remain exact, while either removed large application preference migrates to
65,536 tokens. Other valid preferences, including the user's 32K selection,
remain unchanged. Historical 32K/64K inference gates are retained; a new 128K
hardware gate is no longer required.
Since 2026-10-15 (user decision) admission does not look at currently free
memory: macOS compresses and swaps other apps to make room for the model, and the
model is chosen by RAM (4B below 32 GB). It estimates resident weights plus
4 GiB workspace (3 GiB for 4B) and the validated checkpoint's full-attention KV
state, refuses a request larger than half of RAM, and refuses or stops only at
critical memory pressure or when TalkTrack's footprint exceeds three fifths of RAM.
Pressure checks continue between 512-token prefill chunks and during generation. The MLX free-buffer cache is limited to
512 MiB. No refusal truncates source content; downstream text planners must split
and cover it explicitly. `generateTask` cancellation joins the producer before
lease release. Output reaching the generation cap is rejected as incomplete.

Transcript states, speaker confidence, publication failures and same-job retry
are described in [the transcription guide](transcription.md).

Short synthetic model probes establish compatibility, not meeting-quality
acceptance. Speaker calibration, complete transcript/text processing, real capture,
long recordings and native UI behavior have their own outstanding tasks.
