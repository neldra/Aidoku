#!/usr/bin/env python3
"""Register a Swift source file into Aidoku.xcodeproj/project.pbxproj.

Bounded-memory replacement for ``pbxproj.XcodeProject.add_file``.

The ``pbxproj`` (mod-pbxproj) PyPI library allocates tens of GB on this
project -- ``objectVersion = 70`` with SwiftPM ``productRef`` build files --
and has hard-crashed the machine via the macOS jetsam OOM killer. Its CLI
crashes outright on the same input; the library API just fails slower and
worse. Do NOT run mod-pbxproj against this project.

This tool NEVER builds the pbxproj object graph. It reads the file as text
once, mirrors -- byte for byte -- the exact entries that files already
registered under the same source directory use, appends one new line in
each of the four required places, and writes once. Peak memory ~= the
size of project.pbxproj (a few hundred KB), independent of project size.

Each Swift source needs exactly four pbxproj entries (the same set Xcode
writes when you add a file in the GUI):
  1. PBXFileReference        -- declares the file
  2. PBXBuildFile            -- links the fileRef into a build phase
  3. PBXGroup children entry -- shows it in the navigator
  4. PBXSourcesBuildPhase    -- compiles it for the iOS target

Usage (run from the Aidoku/ directory, after creating the .swift file):
    python3 scripts/pbxproj_add_source.py iOS/UI/Reader/TTS/Foo.swift

Idempotent: if the file is already registered it changes nothing and
exits 3, preserving the "exactly 4 occurrences" invariant. On any
inconsistency it refuses rather than guess. Roll back a bad run with:
    git checkout -- Aidoku.xcodeproj/project.pbxproj
"""

import os
import re
import secrets
import sys

PBXPROJ = "Aidoku.xcodeproj/project.pbxproj"

# A pbxproj object id is 24 uppercase hex characters.
ID = r"[0-9A-F]{24}"


def die(msg, code=1):
    print(f"pbxproj_add_source: {msg}", file=sys.stderr)
    sys.exit(code)


def new_id(text, taken):
    """A 24-hex id that appears nowhere in the file and isn't already minted."""
    while True:
        oid = secrets.token_hex(12).upper()
        if oid not in text and oid not in taken:
            return oid


def indent_of(line):
    return re.match(r"[\t ]*", line).group(0)


def main():
    if len(sys.argv) != 2:
        die("usage: pbxproj_add_source.py <path-under-SOURCE_ROOT>", 2)

    rel = sys.argv[1].lstrip("./")
    base = os.path.basename(rel)
    src_dir = os.path.dirname(rel)  # e.g. iOS/UI/Reader/TTS
    if not src_dir:
        die("path must include a directory under SOURCE_ROOT", 2)
    if not os.path.isfile(PBXPROJ):
        die(f"{PBXPROJ} not found -- run from the Aidoku/ directory", 2)
    if not os.path.isfile(rel):
        die(f"source file {rel!r} does not exist on disk -- create it first", 2)

    text = open(PBXPROJ, encoding="utf-8").read()
    lines = text.split("\n")

    # ---- idempotency: refuse if already registered --------------------
    if re.search(r"/\* " + re.escape(base) + r" \*/", text):
        print(f"{base} already registered; nothing to do.")
        sys.exit(3)

    # ---- 1. sibling PBXFileReference ids already under src_dir --------
    fr_line = re.compile(
        r"^[\t ]*(" + ID + r") /\* .+? \*/ = \{isa = PBXFileReference;"
        r".* path = " + re.escape(src_dir) + r"/[^;]+;"
    )
    sib_fileref_ids = set()
    last_fr_i = None
    for i, ln in enumerate(lines):
        m = fr_line.match(ln)
        if m:
            sib_fileref_ids.add(m.group(1))
            last_fr_i = i
    if not sib_fileref_ids:
        die(
            f"no file is registered under {src_dir!r} yet, so there is no "
            f"proven entry to mirror. Add the first file via the Xcode GUI; "
            f"this tool can then mirror it safely for the rest.",
            4,
        )

    # ---- 2. PBXBuildFile entries pointing at those fileRefs -----------
    bf_line = re.compile(
        r"^[\t ]*(" + ID + r") /\* .+? \*/ = \{isa = PBXBuildFile; "
        r"fileRef = (" + ID + r") "
    )
    sib_build_ids = set()
    last_bf_i = None
    for i, ln in enumerate(lines):
        m = bf_line.match(ln)
        if m and m.group(2) in sib_fileref_ids:
            sib_build_ids.add(m.group(1))
            last_bf_i = i
    if last_bf_i is None:
        die("sibling fileRefs have no PBXBuildFile entries (inconsistent)", 4)

    # ---- 3. last PBXGroup child line referencing a sibling fileRef ----
    child_line = re.compile(r"^([\t ]*)(" + ID + r") /\* .+? \*/,[\t ]*$")
    last_grp_i = None
    grp_indent = ""
    for i, ln in enumerate(lines):
        m = child_line.match(ln)
        if m and m.group(2) in sib_fileref_ids:
            last_grp_i = i
            grp_indent = m.group(1)
    if last_grp_i is None:
        die("sibling fileRefs not found in any PBXGroup children list", 4)

    # ---- 4. last Sources-phase line referencing a sibling buildFile ---
    src_phase_line = re.compile(
        r"^([\t ]*)(" + ID + r") /\* .+? in Sources \*/,[\t ]*$"
    )
    last_src_i = None
    src_indent = ""
    for i, ln in enumerate(lines):
        m = src_phase_line.match(ln)
        if m and m.group(2) in sib_build_ids:
            last_src_i = i
            src_indent = m.group(1)
    if last_src_i is None:
        die("sibling buildFiles not found in any PBXSourcesBuildPhase", 4)

    # ---- mint ids and build the four lines, copying sibling layout ---
    taken = set()
    file_ref = new_id(text, taken)
    taken.add(file_ref)
    build_id = new_id(text, taken)
    taken.add(build_id)

    fr_indent = indent_of(lines[last_fr_i])
    bf_indent = indent_of(lines[last_bf_i])

    new_fr = (
        f"{fr_indent}{file_ref} /* {base} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; name = {base}; "
        f"path = {rel}; sourceTree = SOURCE_ROOT; }};"
    )
    new_bf = (
        f"{bf_indent}{build_id} /* {base} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref} /* {base} */; }};"
    )
    new_child = f"{grp_indent}{file_ref} /* {base} */,"
    new_src = f"{src_indent}{build_id} /* {base} in Sources */,"

    # Insert AFTER each anchor; descending order keeps earlier indices valid.
    for idx, payload in sorted(
        [
            (last_fr_i, new_fr),
            (last_bf_i, new_bf),
            (last_grp_i, new_child),
            (last_src_i, new_src),
        ],
        key=lambda t: t[0],
        reverse=True,
    ):
        lines.insert(idx + 1, payload)

    open(PBXPROJ, "w", encoding="utf-8").write("\n".join(lines))
    print(
        f"registered {base}: fileRef={file_ref} buildFile={build_id} "
        f"(mirrored {len(sib_fileref_ids)} sibling(s) under {src_dir})"
    )


if __name__ == "__main__":
    main()
