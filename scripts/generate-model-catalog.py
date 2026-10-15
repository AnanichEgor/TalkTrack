#!/usr/bin/env python3
"""Generate the bundled catalog from reviewed, immutable upstream evidence.

No network or model downloads. --check detects resource/evidence drift.
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "Packages/TalkTrackKit/Sources/TalkTrackServices/Resources/ModelCatalog.json"
SELECTIONS = {
    "mlx-community/Qwen3-ASR-0.6B-4bit": ("live-asr", ["liveASR"], "qwen3ASR", "mlx-audio-01dec7c9-qwen3-tokenizer-v1"),
    "mlx-community/Qwen3-ASR-1.7B-8bit": ("final-asr", ["finalASR"], "qwen3ASR", "mlx-audio-01dec7c9-qwen3-tokenizer-v1"),
    "mlx-community/Qwen3-ForcedAligner-0.6B-8bit": ("alignment", ["alignment"], "qwen3Aligner", "mlx-audio-01dec7c9-qwen3-tokenizer-v1"),
    "aufklarer/Pyannote-Segmentation-MLX": ("segmentation", ["segmentation"], "pyannoteSegmentation", "speech-swift-1e6e0e52-segmentation-v1"),
    "aufklarer/WeSpeaker-ResNet34-LM-MLX": ("embedding", ["embedding"], "weSpeaker", "speech-swift-1e6e0e52-mel-v1"),
    "mlx-community/Qwen3.6-35B-A3B-4bit": ("text", ["summary", "translation", "spelling"], "qwen3Text", "mlx-swift-lm-3.31.4-chat-v1"),
    "mlx-community/Qwen3.5-9B-OptiQ-4bit": ("text-qwen35-9b", ["summary", "translation", "spelling"], "qwen3Text", "mlx-swift-lm-3.31.4-qwen35-optiq-chat-v1"),
    # Text alternatives share the three text roles; one is selected (by RAM or in Settings).
    "mlx-community/Qwen3.5-4B-OptiQ-4bit": ("text-qwen35-4b", ["summary", "translation", "spelling"], "qwen3Text", "mlx-swift-lm-3.31.4-qwen35-optiq-chat-v1"),
}
LEGACY = {"mlx-community/Qwen3.6-35B-A3B-4bit"}


def generate():
    inventories = json.loads((ROOT / "ThirdParty/model-file-inventories.json").read_text())
    provenance = {item["repository"]: item for item in json.loads((ROOT / "ThirdParty/model-provenance.json").read_text())}
    assert len(inventories) == len(SELECTIONS) == len(provenance) == 8
    assert {item["repository"] for item in inventories} == set(SELECTIONS) == set(provenance)
    models = []
    for inventory in inventories:
        repository = inventory["repository"]
        license_record = provenance[repository]
        revision = inventory["revision"]
        assert revision == license_record["revision"] and re.fullmatch(r"[a-f0-9]{40}", revision)
        identifier, roles, adapter, preprocessing = SELECTIONS[repository]
        artifacts = []
        for file in inventory["files"]:
            name = file["rfilename"]
            if name == ".gitattributes" or name in inventory.get("excludedRuntimeFiles", []):
                continue  # Git transport settings are not runtime model data.
            assert "\\" not in name and "\0" not in name and ":" not in name
            assert all(part not in ("", ".", "..") for part in name.split("/"))
            size = file["size"]
            assert isinstance(size, int) and not isinstance(size, bool) and 0 <= size < 2**63
            assert re.fullmatch(r"[a-f0-9]{40}", file["blobId"])
            if "lfs" in file:
                assert file["lfs"]["size"] == size
                algorithm, digest = "sha256", file["lfs"]["sha256"]
                assert re.fullmatch(r"[a-f0-9]{64}", digest)
            else:
                algorithm, digest = "gitBlobSHA1", file["blobId"]
            artifacts.append({"path": name, "byteCount": size, "digest": {"algorithm": algorithm, "value": digest}})
        names = {file["path"] for file in artifacts}
        assert len(names) == len(artifacts)
        required = {"config.json", "README.md"}
        generated = []
        if adapter in ("qwen3ASR", "qwen3Aligner"):
            sources = ["vocab.json", "merges.txt", "tokenizer_config.json"]
            required |= set(sources) | {"model.safetensors", "model.safetensors.index.json", "preprocessor_config.json", "chat_template.json", "generation_config.json"}
            generated = [{"path": "tokenizer.json", "generatorVersion": preprocessing, "sourcePaths": sources}]
        elif adapter == "qwen3Text":
            required |= {"tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "model.safetensors.index.json", "generation_config.json"}
            required |= set(inventory.get("runtimeWeightShards", [f"model-{i:05d}-of-00004.safetensors" for i in range(1, 5)]))
        else:
            required.add("model.safetensors")
        assert required <= names, (repository, required - names)
        bits = inventory["declaredQuantizationBits"]
        models.append({
            "id": identifier, "repository": repository, "revision": revision, "roles": roles,
            "adapter": adapter, "preprocessingVersion": preprocessing,
            "quantization": f"{bits}-bit mixed" if bits else "/".join(inventory["tensorDTypes"]),
            "files": sorted(artifacts, key=lambda item: item["path"]), "generatedArtifacts": generated,
            "license": {"checkpointLicense": license_record["licenseMetadata"],
                        "baseRepository": license_record["baseModel"], "baseRevision": license_record["baseRevisionObserved"],
                        "baseLicense": license_record["baseLicenseMetadata"],
                        "baseAccess": "gated" if license_record["baseGated"] else "public",
                        "modelCardURL": license_record["modelCardURL"]},
            "evidenceURL": inventory["sourceURL"], "evidenceSHA256": inventory["metadataSHA256"],
            "downloadByteCount": sum(file["byteCount"] for file in artifacts),
            "weightByteCount": sum(file["byteCount"] for file in artifacts if file["path"].endswith(".safetensors")),
            "runtimeValidation": "pending",
        })
    return json.dumps({"schemaVersion": 1,
        "models": [m for m in models if m["repository"] not in LEGACY],
        "legacyModels": [m for m in models if m["repository"] in LEGACY]}, indent=2, sort_keys=True) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = generate()
    if args.check:
        if not DESTINATION.exists() or DESTINATION.read_text() != expected:
            parser.exit(1, "Catalog differs from reviewed evidence. Run scripts/generate-model-catalog.py.\n")
    else:
        DESTINATION.parent.mkdir(parents=True, exist_ok=True)
        DESTINATION.write_text(expected)
    result = json.loads(expected)
    print(f"PASS: {len(result['models'])} active models, {sum(len(m['files']) for m in result['models'])} required files, {len(result['legacyModels'])} legacy manifest; text models are alternatives for the shared text roles.")
