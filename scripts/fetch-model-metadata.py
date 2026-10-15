#!/usr/bin/env python3
"""Fetch inventories for seven active revisions and one legacy revision, without weights.

Run from any directory with Python 3. No third-party packages or HF login needed.
Output is development metadata in .build/model-metadata, not model installation.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".build" / "model-metadata"


def fetch(entry):
    repository = entry["repository"]
    revision = entry["revision"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository identifier")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("An immutable 40-character revision is required")
    url = f"https://huggingface.co/api/models/{repository}/revision/{revision}?blobs=true"
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "TalkTrack-manifest-verification/1"})
    with urlopen(request, timeout=30) as response:
        body = response.read(8 * 1024 * 1024 + 1)
    if len(body) > 8 * 1024 * 1024:
        raise ValueError("Unexpectedly large metadata response")
    document = json.loads(body)
    if document.get("sha") != revision:
        raise ValueError(f"Revision mismatch for {repository}")
    files = document.get("siblings")
    if not isinstance(files, list) or not files:
        raise ValueError(f"Missing file inventory for {repository}")
    seen = set()
    for file in files:
        name = file["rfilename"]
        if (not name or name in seen or "\\" in name or "\0" in name
                or any(part in ("", ".", "..") for part in name.split("/"))):
            raise ValueError(f"Unsafe or repeated file path in {repository}")
        seen.add(name)
        size = file.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise ValueError(f"Missing file size: {repository}/{name}")
        if not re.fullmatch(r"[0-9a-f]{40}", file.get("blobId", "")):
            raise ValueError(f"Missing Git blob identity: {repository}/{name}")
        if "lfs" in file:
            lfs = file["lfs"]
            if lfs.get("size") != size or not re.fullmatch(r"[0-9a-f]{64}", lfs.get("sha256", "")):
                raise ValueError(f"Invalid LFS integrity metadata: {repository}/{name}")
    destination = OUTPUT / (repository.replace("/", "--") + "--" + revision + ".json")
    temporary = destination.with_suffix(".json.part")
    temporary.write_bytes(body)
    temporary.replace(destination)
    return {
        "repository": repository,
        "revision": revision,
        "sourceURL": url,
        "metadataFile": destination.name,
        "metadataSHA256": hashlib.sha256(body).hexdigest(),
        "fileCount": len(files),
        "declaredBytes": sum(file["size"] for file in files),
    }


def main():
    entries = json.loads((ROOT / "ThirdParty" / "model-provenance.json").read_text())
    if len(entries) != 8 or len({entry["repository"] for entry in entries}) != 8:
        raise ValueError("Expected seven selected checkpoints and one retained legacy checkpoint")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    index = []
    for entry in entries:
        item = fetch(entry)
        index.append(item)
        print(f"OK: {item['repository']} @ {item['revision']} — {item['fileCount']} files", flush=True)
    destination = OUTPUT / "index.json"
    temporary = destination.with_suffix(".json.part")
    temporary.write_text(json.dumps(index, indent=2) + "\n")
    temporary.replace(destination)
    print(f"PASS: eight immutable inventories saved to {OUTPUT}; no model weights downloaded.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Metadata verification failed: {error}", file=sys.stderr)
        sys.exit(1)
