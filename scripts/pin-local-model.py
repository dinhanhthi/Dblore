#!/usr/bin/env python3

# Print the per-file pins of on-device models for LocalModelCatalog.swift: for each
# <repo> <revision> pair, a Swift `files:` literal with the name, size and SHA-256 of every
# file the app downloads: its *.safetensors, *.json, *.jinja and tokenizer* files. It never
# downloads weights: LFS files are pinned from the Hugging Face tree API (their oid is the
# SHA-256); only small non-LFS files are fetched, once per git blob, into a temp directory
# deleted at exit, and checked against their git blob SHA-1 before hashing. --trees-dir
# reads saved tree JSON instead (<repo> <revision> <tree-file> triples) and only prints
# what a real run would download, without any network access.

import fnmatch
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request

PATTERNS = ["*.safetensors", "*.json", "*.jinja", "tokenizer*"]
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
REVISION_RE = re.compile(r"[0-9a-f]{40}")
SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
# Plain names only: they are pasted into Swift source and become path components on download.
NAME_RE = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*")
MAX_BLOB = 16 * 1024 * 1024
MAX_TREE = 4 * 1024 * 1024
TIMEOUT = 60
HF = "https://huggingface.co"


def usage():
    sys.stderr.write(
        "Usage: scripts/pin-local-model.py <repo> <revision> [<repo> <revision> ...]\n"
        "       scripts/pin-local-model.py --trees-dir <dir> <repo> <revision> <tree-file> [...]\n"
        "\n"
        "Prints a Swift `files:` literal per model (name, size, SHA-256 of every file the app\n"
        "downloads at that revision). --trees-dir reads <dir>/<tree-file> instead of the tree\n"
        "API and only prints what a real run would download (no network).\n"
    )
    sys.exit(2)


def fail(message):
    sys.stderr.write(f"error: {message}\n")
    sys.exit(1)


def read_capped(stream, limit, what):
    data = stream.read(limit + 1)
    if len(data) > limit:
        fail(f"{what} is larger than {limit} bytes")
    return data


def fetch_tree(repo, revision):
    url = f"{HF}/api/models/{repo}/tree/{revision}?recursive=true"
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        if 'rel="next"' in (response.headers.get("Link") or ""):
            fail(f"{repo}: the tree is paginated, which this script does not support")
        return json.loads(read_capped(response, MAX_TREE, f"{repo} tree"))


def load_tree(trees_dir, tree_file):
    with open(os.path.join(trees_dir, tree_file), "rb") as stream:
        return json.loads(read_capped(stream, MAX_TREE, tree_file))


def is_int(value):
    return type(value) is int and value >= 0


def select(repo, tree):
    """Returns sorted (name, size, sha256 or None, git oid or None) of the files the app downloads."""
    if not isinstance(tree, list):
        fail(f"{repo}: the tree is not a list")
    files = []
    for entry in tree:
        if not isinstance(entry, dict) or entry.get("type") != "file":
            continue
        path = entry.get("path")
        if not isinstance(path, str):
            fail(f"{repo}: a file entry has no path")
        if not any(fnmatch.fnmatchcase(path, pattern) for pattern in PATTERNS):
            continue
        if "/" in path:
            fail(f"{repo}: {path!r} is in a subdirectory; the catalog pins plain names only")
        if not NAME_RE.fullmatch(path):
            fail(f"{repo}: {path!r} is not a plain file name")
        size = entry.get("size")
        if not is_int(size):
            fail(f"{repo}/{path}: invalid size")
        lfs = entry.get("lfs")
        if lfs is not None:
            oid = lfs.get("oid") if isinstance(lfs, dict) else None
            if not isinstance(oid, str) or not SHA256_RE.fullmatch(oid):
                fail(f"{repo}/{path}: LFS oid is not a lowercase SHA-256")
            if not is_int(lfs.get("size")) or lfs["size"] != size:
                fail(f"{repo}/{path}: LFS size does not match the entry size")
            files.append((path, size, oid, None))
        else:
            oid = entry.get("oid")
            if not isinstance(oid, str) or not SHA1_RE.fullmatch(oid):
                fail(f"{repo}/{path}: git oid is not a lowercase SHA-1")
            if size > MAX_BLOB:
                fail(f"{repo}/{path}: non-LFS file of {size} bytes is over {MAX_BLOB}")
            files.append((path, size, None, oid))
    names = [name for name, _, _, _ in files]
    if len(set(names)) != len(names):
        fail(f"{repo}: duplicate file names")
    return sorted(files)


def fetch_blob(repo, revision, name, size, oid, tmp):
    """Downloads one non-LFS file, checks its size and git blob SHA-1, returns its SHA-256."""
    dest = os.path.join(tmp, oid)
    url = f"{HF}/{repo}/resolve/{revision}/{name}"
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response, open(dest, "xb") as out:
        received = 0
        while True:
            chunk = response.read(1 << 16)
            if not chunk:
                break
            received += len(chunk)
            if received > size:
                fail(f"{repo}/{name}: more than the {size} bytes the tree lists")
            out.write(chunk)
    with open(dest, "rb") as stream:
        data = stream.read()
    if len(data) != size:
        fail(f"{repo}/{name}: got {len(data)} bytes, the tree lists {size}")
    if hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest() != oid:
        fail(f"{repo}/{name}: content does not match its git blob SHA-1")
    return hashlib.sha256(data).hexdigest()


def parse_args(args):
    trees_dir = None
    if args[:1] == ["--trees-dir"]:
        if len(args) < 2:
            usage()
        trees_dir, args = args[1], args[2:]
    step = 3 if trees_dir else 2
    if not args or len(args) % step or any(arg.startswith("-") for arg in args):
        usage()
    jobs = [args[i : i + step] for i in range(0, len(args), step)]
    for job in jobs:
        repo, revision = job[0], job[1]
        if not REPO_RE.fullmatch(repo) or any(part in (".", "..") for part in repo.split("/")):
            fail(f"invalid repo {repo!r} (expected <owner>/<name>)")
        if not REVISION_RE.fullmatch(revision):
            fail(f"invalid revision {revision!r} (expected a full 40-hex commit SHA)")
    return trees_dir, jobs


def main():
    trees_dir, jobs = parse_args(sys.argv[1:])
    models = []
    blobs = {}  # git oid -> size of each unique non-LFS file, fetched once across all repos
    for job in jobs:
        repo, revision = job[0], job[1]
        tree = load_tree(trees_dir, job[2]) if trees_dir else fetch_tree(repo, revision)
        files = select(repo, tree)
        for name, size, _, oid in files:
            if oid is not None and blobs.setdefault(oid, size) != size:
                fail(f"{repo}/{name}: git oid {oid} listed with two sizes")
        models.append((repo, revision, files))

    if trees_dir:
        for repo, revision, files in models:
            print(f"// {repo} @ {revision}")
            for name, size, sha256, oid in files:
                print(f"  {name} {size} " + (f"lfs {sha256}" if sha256 else f"blob {oid}"))
        total = sum(blobs.values())
        sys.stderr.write(f"dry run: {len(blobs)} unique non-LFS blobs, {total:,} bytes to download\n")
        return

    hashes = {}
    downloaded = 0
    with tempfile.TemporaryDirectory(prefix="pin-local-model-") as tmp:
        for repo, revision, files in models:
            for name, size, sha256, oid in files:
                if oid is not None and oid not in hashes:
                    hashes[oid] = fetch_blob(repo, revision, name, size, oid, tmp)
                    downloaded += size

    for index, (repo, revision, files) in enumerate(models):
        if index:
            print()
        print(f"// {repo} @ {revision}")
        print("files: [")
        for name, size, sha256, oid in files:
            print(f'  .init(name: "{name}", size: {size:_}, sha256: "{sha256 or hashes[oid]}"),')
        print("],")
    sys.stderr.write(f"downloaded {downloaded:,} bytes ({len(hashes)} non-LFS files)\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:  # URLError is an OSError, JSON errors are ValueErrors
        fail(str(error))
