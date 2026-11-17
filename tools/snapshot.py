#!/usr/bin/env python3
"""Toolchain snapshots: an inventory of `nomu` toolchains built from this checkout (task 257).

A toolchain is one opt `nomu` binary: the compiler, the build driver, the runtime and the prelude. Each is kept
under the host cache's `toolchains/` directory by its compiler identity (`tools/workspace_status.sh`: the commit, plus a hash of
uncommitted changes), with a memo, an optional label, and the uncommitted diff as a patch. Callers use a
snapshot by its path; nothing here selects a default toolchain.

Usage:
  tools/snapshot.py publish [--memo TEXT] [--label NAME]   build the tree as it stands and keep the toolchain
  tools/snapshot.py edit REF [--memo TEXT] [--label NAME]  change a snapshot's memo or label
  tools/snapshot.py list                                   every snapshot, newest first (* = the tree's identity)
  tools/snapshot.py show REF                               a snapshot's metadata and patch
  tools/snapshot.py path REF                               the snapshot's `nomu` binary
  tools/snapshot.py rm REF                                 delete one snapshot
  tools/snapshot.py clear                                  delete every snapshot

REF is a label, an identity, or a unique prefix of one. Publishing an identity already kept changes only its
memo and label. To snapshot an older commit, check it out in this tree and publish: a copy of the tree at
another path has its own Bazel output directory and rebuilds LLVM. The script works on the checkout it runs in,
so for a commit older than the script, run a copy kept outside the tree.

The cache root is `NOMU_CACHE_DIR` when set, else `~/Library/Caches/nomu` on macOS (`$XDG_CACHE_HOME/nomu`, or
`~/.cache/nomu`, elsewhere), as `nomu` chooses it (HostCache.swift).
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys

# The checkout is the one the command runs in, so a copy of this script kept outside the tree can snapshot a
# commit older than the script.
ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
if not ROOT:
    sys.exit("snapshot: run inside a nomu-lang checkout")
TARGET = "//src/nomu-cli:nomu"
# The paths whose uncommitted changes enter the identity (tools/workspace_status.sh).
IDENTITY_PATHS = ["src", "MODULE.bazel", "MODULE.bazel.lock", ".bazelrc", "BUILD.bazel"]


def cache_root():
    env = os.environ
    if env.get("NOMU_CACHE_DIR"):
        return env["NOMU_CACHE_DIR"]
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library", "Caches", "nomu")
    if env.get("XDG_CACHE_HOME"):
        return os.path.join(env["XDG_CACHE_HOME"], "nomu")
    return os.path.join(home, ".cache", "nomu")


def toolchains_dir():
    return os.path.join(cache_root(), "toolchains")


def die(msg):
    sys.exit(f"snapshot: {msg}")


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def short(identity):
    commit, _, changes = identity.partition("-")
    return commit[:10] + ("-" + changes[:8] if changes else "")


def tree_identity():
    r = run([os.path.join(ROOT, "tools", "workspace_status.sh")])
    for line in r.stdout.splitlines():
        key, _, value = line.partition(" ")
        if key == "STABLE_NOMU_COMPILER_IDENTITY":
            return value
    return None


def stamped():
    status = {}
    with open(os.path.join(ROOT, "bazel-out", "stable-status.txt")) as f:
        for line in f:
            key, _, value = line.rstrip("\n").partition(" ")
            status[key] = value
    return status.get("STABLE_NOMU_COMPILER_IDENTITY"), status.get("STABLE_NOMU_GIT_COMMIT")


def uncommitted_patch():
    """Tracked edits and untracked files under the identity paths, as one binary patch."""
    parts = [run(["git", "diff", "HEAD", "--binary", "--"] + IDENTITY_PATHS).stdout]
    untracked = run(["git", "ls-files", "--others", "--exclude-standard", "-z", "--"] + IDENTITY_PATHS).stdout
    for path in filter(None, untracked.split("\0")):
        # `git diff --no-index` exits 1 when the files differ, which they always do here.
        parts.append(run(["git", "diff", "--no-index", "--binary", "--", "/dev/null", path]).stdout)
    return "".join(parts)


def entries():
    d = toolchains_dir()
    if not os.path.isdir(d):
        return []
    out = []
    for name in os.listdir(d):
        meta = os.path.join(d, name, "meta.json")
        if os.path.isfile(meta):
            with open(meta) as f:
                out.append(json.load(f))
    return sorted(out, key=lambda m: m["published"], reverse=True)


def entry_dir(meta):
    return os.path.join(toolchains_dir(), meta["identity"])


def save(meta):
    with open(os.path.join(entry_dir(meta), "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")


def resolve(ref):
    all_ = entries()
    for m in all_:
        if m.get("label") == ref or m["identity"] == ref:
            return m
    hits = [m for m in all_ if m["identity"].startswith(ref) or short(m["identity"]).startswith(ref)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        die(f"no snapshot matches '{ref}'")
    die(f"'{ref}' matches {len(hits)} snapshots: " + ", ".join(short(m["identity"]) for m in hits))


def set_label(meta, label):
    """Give `meta` the label, taking it from any other snapshot that has it."""
    if label is None:
        return
    for other in entries():
        if other["identity"] != meta["identity"] and other.get("label") == label:
            other["label"] = None
            save(other)
            print(f"label '{label}' moved from {short(other['identity'])}")
    meta["label"] = label or None


def cmd_publish(args):
    r = subprocess.run(["bazel", "build", "-c", "opt", TARGET], cwd=ROOT)
    if r.returncode != 0:
        die("the toolchain failed to build")
    q = run(["bazel", "cquery", "-c", "opt", "--output=files", TARGET])
    binary = os.path.join(ROOT, q.stdout.strip().splitlines()[-1]) if q.returncode == 0 and q.stdout.strip() else ""
    if not os.path.isfile(binary):
        die(f"could not find the built toolchain:\n{q.stderr}")
    identity, commit = stamped()
    if not identity or identity == "unstamped":
        die("the build is unstamped (not a git checkout?)")
    now_identity = tree_identity()
    if now_identity != identity:
        die(f"the tree changed during the build ({short(identity)} built, {short(now_identity)} now); publish again")
    with open(binary, "rb") as f:
        if identity.encode() not in f.read():
            die(f"{binary} does not carry the identity {identity}; is it the build just made?")

    d = os.path.join(toolchains_dir(), identity)
    meta_path = os.path.join(d, "meta.json")
    if os.path.isfile(meta_path):
        with open(meta_path) as f:
            meta = json.load(f)
        if args.memo is not None:
            meta["memo"] = args.memo
        set_label(meta, args.label)
        save(meta)
        print(f"kept already: {short(identity)}; memo and label updated")
        print(os.path.join(d, "nomu"))
        return

    os.makedirs(d, exist_ok=True)
    shutil.copyfile(binary, os.path.join(d, "nomu"))
    os.chmod(os.path.join(d, "nomu"), 0o755)
    patch = uncommitted_patch()
    if patch:
        with open(os.path.join(d, "changes.patch"), "w") as f:
            f.write(patch)
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    meta = {
        "identity": identity,
        "commit": commit,
        "branch": branch,
        "dirty": "-" in identity,
        "memo": args.memo or "",
        "label": None,
        "published": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    set_label(meta, args.label)
    save(meta)
    print(f"published {short(identity)}" + (f" ({meta['label']})" if meta["label"] else ""))
    print(os.path.join(d, "nomu"))


def cmd_edit(args):
    meta = resolve(args.ref)
    if args.memo is not None:
        meta["memo"] = args.memo
    set_label(meta, args.label)
    save(meta)


def age(published):
    then = datetime.datetime.fromisoformat(published)
    secs = (datetime.datetime.now().astimezone() - then).total_seconds()
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return f"{int(secs // n)}{unit}"
    return "now"


def cmd_list(args):
    all_ = entries()
    if not all_:
        print(f"no snapshots in {toolchains_dir()}")
        return
    current = tree_identity()
    rows = [("", "id", "label", "age", "memo")]
    for m in all_:
        rows.append(("*" if m["identity"] == current else "", short(m["identity"]), m.get("label") or "",
                      age(m["published"]), m.get("memo") or ""))
    widths = [max(len(r[i]) for r in rows) for i in range(4)]
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r[:4], widths)) + "  " + r[4])


def cmd_show(args):
    meta = resolve(args.ref)
    for key in ("identity", "commit", "branch", "label", "memo", "published"):
        print(f"{key:10} {meta.get(key) or ''}")
    print(f"{'path':10} {os.path.join(entry_dir(meta), 'nomu')}")
    patch = os.path.join(entry_dir(meta), "changes.patch")
    if os.path.isfile(patch):
        print()
        with open(patch) as f:
            sys.stdout.write(f.read())


def cmd_path(args):
    print(os.path.join(entry_dir(resolve(args.ref)), "nomu"))


def cmd_rm(args):
    meta = resolve(args.ref)
    shutil.rmtree(entry_dir(meta))
    print(f"removed {short(meta['identity'])}")


def cmd_clear(args):
    d = toolchains_dir()
    n = len(entries())
    if os.path.isdir(d):
        shutil.rmtree(d)
    print(f"removed {n} snapshot{'s' if n != 1 else ''} ({d})")


def main():
    p = argparse.ArgumentParser(prog="tools/snapshot.py", description="Toolchain snapshots (task 257).")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("publish", help="build the tree and keep the toolchain")
    s.add_argument("--memo")
    s.add_argument("--label")
    s.set_defaults(fn=cmd_publish)
    s = sub.add_parser("edit", help="change a snapshot's memo or label")
    s.add_argument("ref")
    s.add_argument("--memo")
    s.add_argument("--label", help="an empty string removes the label")
    s.set_defaults(fn=cmd_edit)
    sub.add_parser("list", help="every snapshot").set_defaults(fn=cmd_list)
    for name, fn, helptext in (("show", cmd_show, "a snapshot's metadata and patch"),
                               ("path", cmd_path, "a snapshot's binary"),
                               ("rm", cmd_rm, "delete one snapshot")):
        s = sub.add_parser(name, help=helptext)
        s.add_argument("ref")
        s.set_defaults(fn=fn)
    sub.add_parser("clear", help="delete every snapshot").set_defaults(fn=cmd_clear)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
