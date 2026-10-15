# Third-party attribution

TalkTrack includes modified source from:

- **MLX Audio Swift**, Copyright (c) 2025 Prince Canuma, MIT.
  Revision `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` from
  https://github.com/Blaizzy/mlx-audio-swift. The local MLXAudioSTT module
  retains Qwen ASR, forced alignment, generation types, and the DSP dependency.
  Repository/cache download entry points were removed. Its dependency uses
  the Tokenizers product instead of the CoreML-containing Transformers product.
- **speech-swift**, Apache-2.0, revision
  `1e6e0e527be00e9c0ac79ebb255ea54cd6e9dd80` from
  https://github.com/soniqo/speech-swift. The local TalkTrackSpeakerMLX module
  retains PyanNet/SincNet/BiLSTM, WeSpeaker, mel preprocessing, powerset decoding,
  and weight loading. Multi-engine wrappers/downloaders are not included.
  Configuration is narrowed to segmentation; shared error imports are replaced
  with a local error type. Mel mean subtraction uses safe indexed operations.
- **Muesli**, Copyright (c) 2026 Pranav Hari, MIT, revision
  `d457aaf94691a73afd2867f5a6ca7fdd203044db` from
  https://github.com/Muesli-HQ/muesli. Service ownership and lifecycle were
  studied as the reference architecture. Its MIT notice is retained for
  subsequent adaptations; its application and alternate backends are not linked.

Full licenses are adjacent. `source-provenance.json` maps copied files to
immutable source revisions, original SHA-256 hashes, and modifications.
`dependency-provenance.json` records resolved Swift package sources and their
license/notice files under `Dependencies/`. MLX's embedded C/C++ components
have separate notices under `Dependencies/mlx-swift/Embedded/`.

`model-provenance.json` records six active model repositories and the retained
legacy text checkpoint, with license metadata at pinned revisions. These records attribute the original
Qwen/pyannote/WeSpeaker models and MLX conversions; they do not claim quality or
checkpoint compatibility. No model weights are bundled with the application.
`model-file-inventories.json` preserves reviewed file metadata used to generate
the bundled catalog (47 active files and 16 legacy files). The Qwen3.5-9B OptiQ
text installation contains both root weight shards; optional MTP/vision sidecars
are excluded from this text-only runtime. Full upstream inventories remain in
the evidence. Derived-file provenance is recorded during model
preparation; actual checkpoint compatibility remains a separate validation gate.

The WeSpeaker conversion card declares MIT, but the original
[pyannote WeSpeaker checkpoint](https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM/blob/837717ddb9ff5507820346191109dc79c958d614/README.md)
identifies its VoxCeleb-trained weights as
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Retain this attribution
as well as the conversion's notice; the toolkit's code license is not a
replacement for the weights' license. Credit: WeSpeaker by Hongji Wang,
Chengdong Liang, Shuai Wang, Zhengyang Chen, Binbin Zhang, Xu Xiang, Yanlei Deng,
and Yanmin Qian (ICASSP 2023); the pyannote.audio wrapper by Hervé Bredin;
and the MLX conversion by aufklarer/soniqo. The conversion fuses BatchNorm,
transposes convolution weights, and renames parameters; TalkTrack does not
modify or bundle checkpoint weights at this stage.

This directory is copied into the application's resources. Source licenses and
model licenses are distinct; retain both when updating or distributing assets.
# Download orchestration

`ModelDownloadCoordinator.swift` adapts patterns from Muesli's coordinator at
`d457aaf94691a73afd2867f5a6ca7fdd203044db`: manifest identity, shared requests,
bounded batches, partial/ETag resume and cancellation completion. Copyright
(c) 2026 Pranav Hari, MIT (`Muesli-LICENSE`). TalkTrack replaces path handling,
transport buffering, digest validation and readiness publication with its own
file actor, streaming transport and required preparation hook.
