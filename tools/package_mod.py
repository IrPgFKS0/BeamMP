#!/usr/bin/env python3
"""Package the LAN mod, preserving source bytes and BeamNG ZIP compatibility.

Run from either checkout layout: python tools/package_mod.py
Or: python BeamMP/tools/package_mod.py --output BeamMP.zip
Inspect an existing archive: python tools/package_mod.py --verify BeamMP.zip
Add --mod-dir BeamMP to verification to compare every member with current sources.

BeamNG 0.40 can return raw DEFLATE bytes when compressed and original sizes are
equal. Store entries that do not shrink; measure zipfile's actual output rather
than estimating compression. The previous archive remains in place until the
new archive passes full member/CRC/source checks and its backup succeeds.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile


# Same release content as CLAUDE.md's original recipe. mp_locales was retired in
# 4.22; this fork has LICENSE (upstream's release recipe names LICENSE.md).
DIRECTORIES = ("icons", "locales", "lua", "scripts", "settings", "ui", "vehicles")
DOCUMENTS = ("CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "LICENSE", "README.md", "NOTICES.md")


def source_files(mod_dir):
    missing = [name for name in DIRECTORIES if not (mod_dir / name).is_dir()]
    missing += [name for name in DOCUMENTS if not (mod_dir / name).is_file()]
    if missing:
        raise ValueError("missing required mod paths: " + ", ".join(missing))
    files = {name: mod_dir / name for name in DOCUMENTS}
    for directory in DIRECTORIES:
        for parent, dirs, names in os.walk(mod_dir / directory, onerror=raise_walk_error):
            # Match the shell packer's exclusions; development tools live outside
            # these seven release directories.
            dirs[:] = sorted(name for name in dirs if name not in (".git", ".idea"))
            for name in dirs:
                if (Path(parent) / name).is_symlink():
                    raise ValueError(f"symlink directory would be skipped by os.walk: {Path(parent) / name}")
            for name in sorted(names):
                path = Path(parent) / name
                files[path.relative_to(mod_dir).as_posix()] = path
    return dict(sorted(files.items()))


def raise_walk_error(error):
    raise error


def snapshot(mod_dir):
    return {name: (path, path.read_bytes()) for name, path in source_files(mod_dir).items()}


def verify_archive(archive, expected=None):
    """Read every member (including its CRC) and reject BeamNG's equal-size case."""
    problems = []
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        counts = Counter(info.filename for info in entries)
        problems += ["duplicate member: " + name for name, count in counts.items() if count > 1]
        if expected is not None:
            problems += ["missing member: " + name for name in sorted(expected.keys() - counts.keys())]
            problems += ["unexpected member: " + name for name in sorted(counts.keys() - expected.keys())]
        for info in entries:
            if info.compress_type == zipfile.ZIP_DEFLATED and info.compress_size == info.file_size:
                problems.append(f"BeamNG-unsafe equal-size DEFLATE: {info.filename} ({info.file_size} bytes)")
            try:
                data = z.read(info)  # ZipExtFile verifies CRC at EOF.
            except (zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
                problems.append(f"unreadable member {info.filename}: {error}")
                continue
            if expected is not None and info.filename in expected and data != expected[info.filename][1]:
                problems.append("source bytes differ: " + info.filename)
    if problems:
        raise ValueError("archive verification failed:\n  " + "\n  ".join(problems))
    return len(entries)


def write_archive(destination, entries, stored, compression_level):
    with zipfile.ZipFile(destination, "w") as z:
        for name, (path, data) in entries.items():
            info = zipfile.ZipInfo.from_file(path, arcname=name)
            # Do not import platform-specific extras into local ZIP headers:
            # BeamNG also rejects Unix entries carrying Windows NTFS extras.
            info.extra = b""
            method = zipfile.ZIP_STORED if name in stored else zipfile.ZIP_DEFLATED
            z.writestr(info, data, compress_type=method, compresslevel=compression_level)


def package(mod_dir, output, backup_dir, compression_level):
    entries = snapshot(mod_dir)  # Preflight before touching the previous output.
    output.parent.mkdir(parents=True, exist_ok=True)
    staged = []
    try:
        # Same-volume atomic rename; tempfile creates both names exclusively.
        for label in ("deflated", "ready"):
            with tempfile.NamedTemporaryFile(
                prefix=f".{output.name}.{label}-", suffix=".tmp", dir=output.parent, delete=False
            ) as temporary:
                staged.append(Path(temporary.name))
        trial, ready = staged
        write_archive(trial, entries, set(), compression_level)
        with zipfile.ZipFile(trial) as z:
            stored = {
                info.filename: (info.file_size, info.compress_size)
                for info in z.infolist() if info.compress_size >= info.file_size
            }
        write_archive(ready, entries, stored, compression_level)
        count = verify_archive(ready, entries)
        # Verify the complete population again, including added/deleted files,
        # so concurrent edits fail loudly before replacing the public artifact.
        current = snapshot(mod_dir)
        if current != entries:
            changed = sorted(set(current) ^ set(entries))
            changed += sorted(name for name in current.keys() & entries.keys() if current[name] != entries[name])
            raise ValueError("mod sources changed during packaging; retry:\n  " + "\n  ".join(changed))
        if output.exists():
            backup_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%fZ")
            backup = backup_dir / f"{output.stem}_backup-{timestamp}{output.suffix}"
            shutil.copy2(output, backup)
            print(f"BACKUP {backup}")
        os.replace(ready, output)
        for name, (size, compressed) in stored.items():
            print(f"STORED {name}: {size} source bytes; DEFLATE would use {compressed} bytes")
        print(f"VERIFIED {count} members ({len(stored)} stored): exact source bytes, CRCs, no equal-size DEFLATE")
        print(f"WROTE {output}")
        print(f"size {output.stat().st_size} bytes")
        print(f"sha256 {hashlib.sha256(output.read_bytes()).hexdigest().upper()}")
        return output
    finally:
        for path in staged:
            path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mod-dir", type=Path, help="mod source directory; inferred from script location when building")
    parser.add_argument("--output", type=Path, help="output ZIP; defaults to BeamMP.zip beside the mod checkout")
    parser.add_argument("--backup-dir", type=Path, help="previous archives; defaults to dist beside the output")
    parser.add_argument("--compression-level", type=int, choices=range(10), default=6)
    parser.add_argument("--verify", type=Path, metavar="ZIP", help="verify an existing archive without writing anything")
    args = parser.parse_args()
    if args.verify:
        expected = snapshot(args.mod_dir.resolve()) if args.mod_dir else None
        count = verify_archive(args.verify, expected)
        print(f"VERIFIED {count} members: CRCs, no equal-size DEFLATE" + (", exact source bytes" if expected else ""))
        return 0
    script_root = Path(__file__).resolve().parent.parent
    default_mod = script_root / "BeamMP" if (script_root / "BeamMP").is_dir() else script_root
    mod_dir = (args.mod_dir or default_mod).resolve()
    output = (args.output or mod_dir.parent / "BeamMP.zip").resolve()
    backup_dir = (args.backup_dir or output.parent / "dist").resolve()
    # An output inside a packaged directory becomes an input on the next run.
    for directory in DIRECTORIES:
        if output.is_relative_to(mod_dir / directory):
            parser.error("--output must be outside the packaged source directories")
        if backup_dir.is_relative_to(mod_dir / directory):
            parser.error("--backup-dir must be outside the packaged source directories")
    if output in (mod_dir / name for name in DOCUMENTS):
        parser.error("--output must not replace a packaged source document")
    package(mod_dir, output, backup_dir, args.compression_level)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        sys.exit(f"ABORT: {error}")
