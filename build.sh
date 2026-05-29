#!/data/data/com.termux/files/usr/bin/sh
set -eu

NAME="m.libs"
VERSION="1.0.0"
ARCH="all"
ROOT="$(pwd)"
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
WORK="$ROOT/.build"
PKG="$WORK/pkg"
OUT="$ROOT/dist"
REPO="$ROOT/repo"
DEB="$OUT/${NAME}_${VERSION}_${ARCH}.deb"

rm -rf "$WORK" "$OUT" "$REPO"
mkdir -p "$PKG/DEBIAN"
mkdir -p "$PKG$PREFIX_DIR/bin"
mkdir -p "$OUT" "$REPO"

cat > "$PKG/DEBIAN/control" <<EOF
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: m.libs <m.libs@local.invalid>
Depends: python
Homepage: https://github.com/YOUR_USER/m.libs
Description: m runtime and builder for Termux
EOF

cat > "$PKG$PREFIX_DIR/bin/m.enter" <<'PY'
#!/usr/bin/env python3
import os
import sys
import json
import zlib
import base64
import secrets
import tempfile
import shutil
import runpy
import time
import hashlib
from pathlib import Path

APP = "m.libs"
VERSION = "1.0.0"
HOME = Path(os.environ.get("M_LIBS_HOME", str(Path.home() / "m.libs")))
SRC = HOME / "src"
BUILD = HOME / "build"
CACHE = HOME / "cache"
MAGIC = "M!"

def ensure():
    SRC.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)

def size_text(n):
    units = ["B", "KB", "MB", "GB"]
    v = float(n)
    for u in units:
        if v < 1024 or u == units[-1]:
            if u == "B":
                return f"{int(v)} {u}"
            return f"{v:.2f} {u}"
        v /= 1024

def stage(p, name, size=0):
    print(f"[{p:3d}%] {name} | size: {size_text(size)}")
    time.sleep(0.04)

def norm(p):
    p = p.strip()
    if not p:
        raise SystemExit("empty path")
    if p.startswith("/n."):
        p = p[3:]
    elif p.startswith("/n/"):
        p = p[3:]
    elif p.startswith("/"):
        p = p[1:]
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    if ".." in Path(p).parts:
        raise SystemExit("bad path")
    return p

def src_path(p):
    return SRC / norm(p)

def out_path(p):
    q = norm(p)
    if not q.endswith(".m"):
        q += ".m"
    return BUILD / Path(q).name

def find_m(p):
    q = Path(p)
    if q.exists():
        return q
    q = BUILD / p
    if q.exists():
        return q
    q = BUILD / Path(p).name
    if q.exists():
        return q
    raise SystemExit("file not found")

def read_block():
    lines = []
    first = input()
    if first == '"':
        while True:
            line = input()
            if line == '"':
                break
            lines.append(line)
        return "\n".join(lines) + "\n"
    if first.startswith('"'):
        first = first[1:]
        if first.endswith('"') and len(first) > 0:
            return first[:-1] + "\n"
        lines.append(first)
        while True:
            line = input()
            if line == '"':
                break
            lines.append(line)
        return "\n".join(lines) + "\n"
    lines.append(first)
    while True:
        try:
            line = input()
        except EOFError:
            break
        if line == ".":
            break
        lines.append(line)
    return "\n".join(lines) + "\n"

def make_file(path_arg=None, data=None):
    ensure()
    if path_arg is None:
        path_arg = input().strip()
    target = src_path(path_arg)
    target.parent.mkdir(parents=True, exist_ok=True)
    if data is None:
        data = read_block()
    target.write_text(data, encoding="utf-8")
    print(str(target))

def collect_files():
    ensure()
    files = {}
    for p in sorted(SRC.rglob("*.py")):
        rel = p.relative_to(SRC).as_posix()
        files[rel] = p.read_text(encoding="utf-8")
    if not files:
        raise SystemExit("no python files")
    entry = "main.py" if "main.py" in files else sorted(files.keys())[0]
    return entry, files

def noise(n):
    return "".join(secrets.choice("mM") for _ in range(n))

def xor_bytes(data, key):
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))

def build_file(target_arg=None):
    ensure()
    if target_arg is None:
        target_arg = input().strip()
    stage(10, "scan")
    entry, files = collect_files()
    raw = json.dumps({
        "app": APP,
        "version": VERSION,
        "entry": entry,
        "files": files
    }, separators=(",", ":")).encode()
    stage(25, "pack", len(raw))
    for name, code in files.items():
        compile(code, name, "exec")
    stage(45, "check", len(raw))
    compressed = zlib.compress(raw, 9)
    key = secrets.token_bytes(32)
    enc = xor_bytes(compressed, key)
    payload = base64.b85encode(enc).decode()
    header = {
        "app": APP,
        "version": VERSION,
        "entry": entry,
        "key": base64.b85encode(key).decode(),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size": len(raw)
    }
    header_data = base64.b85encode(json.dumps(header, separators=(",", ":")).encode()).decode()
    out = out_path(target_arg)
    text = "\n".join([
        "M!",
        noise(64),
        "<<H!>>",
        header_data,
        "<<G!>>",
        f"\"{out.name}>",
        "<<1!>>",
        "1" * secrets.randbelow(64) + "1" * 64,
        "<<P!>>",
        payload,
        "<<END!>>",
        ""
    ])
    out.write_text(text, encoding="utf-8")
    stage(80, "encode", len(text.encode()))
    stage(100, "done", out.stat().st_size)
    print(str(out))

def parse_m(path):
    text = Path(path).read_text(encoding="utf-8")
    if not text.startswith("M!"):
        raise SystemExit("bad m file")
    def part(a, b):
        if a not in text or b not in text:
            raise SystemExit("bad m structure")
        return text.split(a, 1)[1].split(b, 1)[0].strip()
    header_raw = part("<<H!>>", "<<G!>>")
    payload_raw = part("<<P!>>", "<<END!>>")
    header = json.loads(base64.b85decode(header_raw.encode()).decode())
    key = base64.b85decode(header["key"].encode())
    enc = base64.b85decode(payload_raw.encode())
    raw = zlib.decompress(xor_bytes(enc, key))
    if hashlib.sha256(raw).hexdigest() != header["sha256"]:
        raise SystemExit("hash mismatch")
    return json.loads(raw.decode())

def run_m(path_arg=None):
    ensure()
    if path_arg is None:
        path_arg = input().strip()
    path = find_m(path_arg)
    data = parse_m(path)
    tmp = Path(tempfile.mkdtemp(prefix="m_", dir=str(CACHE)))
    try:
        for rel, code in data["files"].items():
            target = tmp / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(code, encoding="utf-8")
        sys.path.insert(0, str(tmp))
        runpy.run_path(str(tmp / data["entry"]), run_name="__main__")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def list_files():
    ensure()
    print("src:")
    for p in sorted(SRC.rglob("*")):
        if p.is_file():
            print(" " + p.relative_to(SRC).as_posix())
    print("build:")
    for p in sorted(BUILD.glob("*.m")):
        print(" " + p.name)

def tp_cmd(args):
    ensure()
    if len(args) >= 3 and args[-2] == "to":
        src = find_m(args[0])
        dst = Path(args[-1]).expanduser()
        dst.mkdir(parents=True, exist_ok=True)
        out = dst / src.name
        shutil.copy2(src, out)
        print(str(out))
        return
    raise SystemExit("usage: tp file.m to /path")

def shell():
    ensure()
    print("m")
    while True:
        try:
            cmd = input("m> ").strip()
        except EOFError:
            print()
            return
        if not cmd:
            continue
        if cmd in ("exit", "quit"):
            return
        if cmd == "clear":
            os.system("clear")
            continue
        parts = cmd.split()
        name = parts[0]
        args = parts[1:]
        try:
            if name == "m.make":
                make_file(args[0] if args else None)
            elif name == "m.build":
                build_file(args[0] if args else None)
            elif name == "m.run":
                run_m(args[0] if args else None)
            elif name == "m.list":
                list_files()
            elif name == "tp":
                tp_cmd(args)
            else:
                print("unknown")
        except Exception as e:
            print(str(e))

def main():
    prog = Path(sys.argv[0]).name
    args = sys.argv[1:]
    try:
        if prog == "m.make":
            data = sys.stdin.read()
            if not args:
                make_file()
            else:
                make_file(args[0], data)
        elif prog == "m.build":
            build_file(args[0] if args else None)
        elif prog == "m.run":
            run_m(args[0] if args else None)
        elif prog == "tp":
            tp_cmd(args)
        else:
            if args:
                if args[0] == "make":
                    make_file(args[1] if len(args) > 1 else None)
                elif args[0] == "build":
                    build_file(args[1] if len(args) > 1 else None)
                elif args[0] == "run":
                    run_m(args[1] if len(args) > 1 else None)
                elif args[0] == "list":
                    list_files()
                else:
                    shell()
            else:
                shell()
    except KeyboardInterrupt:
        print()
        raise SystemExit(130)

if __name__ == "__main__":
    main()
PY

chmod 755 "$PKG$PREFIX_DIR/bin/m.enter"

ln -s m.enter "$PKG$PREFIX_DIR/bin/m.make"
ln -s m.enter "$PKG$PREFIX_DIR/bin/m.build"
ln -s m.enter "$PKG$PREFIX_DIR/bin/m.run"
ln -s m.enter "$PKG$PREFIX_DIR/bin/tp"

dpkg-deb --build "$PKG" "$DEB" >/dev/null

cp "$DEB" "$REPO/"
SIZE="$(wc -c < "$DEB" | tr -d ' ')"
SHA="$(sha256sum "$DEB" | awk '{print $1}')"

cat > "$REPO/Packages" <<EOF
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: m.libs <m.libs@local.invalid>
Depends: python
Filename: ./${NAME}_${VERSION}_${ARCH}.deb
Size: $SIZE
SHA256: $SHA
Description: m runtime and builder for Termux
EOF

gzip -kf "$REPO/Packages"

echo "$DEB"
echo "$REPO"
