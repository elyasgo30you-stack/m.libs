#!/data/data/com.termux/files/usr/bin/sh
set -eu
umask 022

NAME="m.libs"
VERSION="1.2.0"
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
Homepage: https://github.com/elyasgo30you-stack/m.libs
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
import subprocess
from pathlib import Path

APP = "m.libs"
VERSION = "1.2.0"
HOME = Path(os.environ.get("M_LIBS_HOME", str(Path.home() / "m.libs")))
SRC = HOME / "src"
BUILD = HOME / "build"
CACHE = HOME / "cache"
STATE = HOME / "state.json"

SKIP_DIRS = {".git", ".hg", ".svn", "node_modules", "__pycache__", ".cache", "cache", "tmp", "temp"}

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
    time.sleep(0.03)

def norm(p):
    p = str(p).strip().strip('"').strip("'")
    if not p:
        raise SystemExit("empty path")
    if p.startswith("/n."):
        p = p[3:]
    elif p.startswith("/n/"):
        p = p[3:]
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

def name_set(name, want_m=False):
    raw = str(name).strip().strip('"').strip("'")
    base = Path(raw).name
    items = {raw, base}
    if want_m:
        more = set()
        for x in items:
            if not x.endswith(".m"):
                more.add(x + ".m")
        items |= more
    return {x for x in items if x}

def direct_candidates(name, want_m=False):
    raw = str(name).strip().strip('"').strip("'")
    names = name_set(raw, want_m)
    roots = [Path.cwd(), BUILD, SRC, HOME, HOME / "build", HOME / "src", Path.home(), Path("/sdcard"), Path("/storage/emulated/0")]
    out = []
    q = Path(raw).expanduser()
    if q.is_absolute():
        out.append(q)
        if want_m and not str(q).endswith(".m"):
            out.append(Path(str(q) + ".m"))
    for r in roots:
        for n in names:
            out.append(r / n)
    seen = set()
    final = []
    for p in out:
        s = str(p)
        if s not in seen:
            seen.add(s)
            final.append(p)
    return final

def walk_roots():
    roots = [BUILD, SRC, HOME, Path.cwd(), Path.home(), Path("/sdcard"), Path("/storage/emulated/0")]
    seen = set()
    out = []
    for r in roots:
        try:
            rr = r.resolve()
        except Exception:
            rr = r
        s = str(rr)
        if s not in seen and r.exists():
            seen.add(s)
            out.append(r)
    return out

def find_file(name, want_m=False):
    ensure()
    for p in direct_candidates(name, want_m):
        try:
            if p.is_file():
                return p
        except Exception:
            pass
    names = name_set(name, want_m)
    for root in walk_roots():
        try:
            for base, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
                for f in files:
                    if f in names:
                        return Path(base) / f
        except Exception:
            continue
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
    target.write_text(data, encoding="utf-8", newline="\n")
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

def random_blob(n):
    pool = [i for i in range(1, 256) if i not in (60, 62)]
    return bytes(secrets.choice(pool) for _ in range(n))

def section(tag, data):
    head = f"<<{tag}:{len(data)}>>".encode()
    return head + data

def read_section(blob, tag):
    needle = f"<<{tag}:".encode()
    i = blob.find(needle)
    if i < 0:
        raise SystemExit("bad m structure")
    j = blob.find(b">>", i)
    if j < 0:
        raise SystemExit("bad m structure")
    raw_len = blob[i + len(needle):j]
    try:
        n = int(raw_len.decode())
    except Exception:
        raise SystemExit("bad m structure")
    start = j + 2
    end = start + n
    if end > len(blob):
        raise SystemExit("bad m structure")
    return blob[start:end]

def b64e(x):
    return base64.urlsafe_b64encode(x).decode().rstrip("=")

def b64d(x):
    pad = "=" * ((4 - len(x) % 4) % 4)
    return base64.urlsafe_b64decode((x + pad).encode())

def rotl(b, r):
    r &= 7
    return ((b << r) & 255) | (b >> (8 - r))

def rotr(b, r):
    r &= 7
    return (b >> r) | ((b << (8 - r)) & 255)

def stream_bytes(key, nonce, n):
    out = bytearray()
    c = 0
    while len(out) < n:
        out.extend(hashlib.sha256(key + nonce + c.to_bytes(8, "big")).digest())
        c += 1
    return bytes(out[:n])

def seal(raw):
    comp = zlib.compress(raw, 9)
    pad = secrets.token_bytes(64 + secrets.randbelow(512))
    body = len(comp).to_bytes(8, "big") + comp + pad
    key = secrets.token_bytes(32)
    nonce = secrets.token_bytes(16)
    ks = stream_bytes(key, nonce, len(body))
    data = bytearray()
    for i, b in enumerate(body):
        x = b ^ ks[i]
        x = rotl(x, (i % 7) + 1)
        x ^= (i * 131 + key[i % len(key)] + nonce[i % len(nonce)]) & 255
        data.append(x)
    data.reverse()
    return bytes(data), key, nonce

def open_seal(enc, key, nonce):
    data = bytearray(enc)
    data.reverse()
    ks = stream_bytes(key, nonce, len(data))
    out = bytearray()
    for i, b in enumerate(data):
        x = b ^ ((i * 131 + key[i % len(key)] + nonce[i % len(nonce)]) & 255)
        x = rotr(x, (i % 7) + 1)
        x ^= ks[i]
        out.append(x)
    if len(out) < 8:
        raise SystemExit("bad payload")
    n = int.from_bytes(out[:8], "big")
    comp = bytes(out[8:8 + n])
    return zlib.decompress(comp)

def build_file(target_arg=None):
    ensure()
    if target_arg is None:
        target_arg = input().strip()
    stage(8, "scan")
    entry, files = collect_files()
    raw = json.dumps({"app": APP, "version": VERSION, "entry": entry, "files": files}, separators=(",", ":")).encode()
    stage(22, "pack", len(raw))
    for name, code in files.items():
        compile(code, name, "exec")
    stage(40, "check", len(raw))
    enc, key, nonce = seal(raw)
    stage(60, "bytes", len(enc))
    out = out_path(target_arg)
    header = json.dumps({
        "app": APP,
        "version": VERSION,
        "entry": entry,
        "key": b64e(key),
        "nonce": b64e(nonce),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size": len(raw),
        "name": out.name
    }, separators=(",", ":")).encode()
    blob = bytearray()
    blob += b"M!\n"
    blob += random_blob(128 + secrets.randbelow(384))
    blob += b"\n<<G!>>\n"
    blob += random_blob(32 + secrets.randbelow(160))
    blob += b"\n"
    blob += section("H", header)
    blob += b"\n<<N!>>\n"
    blob += out.name.encode(errors="ignore")
    blob += b"\n<<1!>>\n"
    for i in range(5 + secrets.randbelow(6)):
        blob += section("R" + str(i), random_blob(64 + secrets.randbelow(512)))
    blob += b"\n"
    blob += section("P", enc)
    blob += b"\n<<END!>>\n"
    blob += random_blob(128 + secrets.randbelow(512))
    out.write_bytes(bytes(blob))
    stage(86, "write", out.stat().st_size)
    stage(100, "done", out.stat().st_size)
    print(str(out))

def parse_m(path):
    blob = Path(path).read_bytes()
    if not blob.startswith(b"M!"):
        raise SystemExit("bad m file")
    header = json.loads(read_section(blob, "H").decode())
    enc = read_section(blob, "P")
    raw = open_seal(enc, b64d(header["key"]), b64d(header["nonce"]))
    if hashlib.sha256(raw).hexdigest() != header["sha256"]:
        raise SystemExit("hash mismatch")
    return json.loads(raw.decode())

def run_payload(path, mode="prints"):
    ensure()
    target = find_file(path, want_m=True)
    data = parse_m(target)
    tmp = Path(tempfile.mkdtemp(prefix="m_", dir=str(CACHE)))
    old_path = list(sys.path)
    old_argv = list(sys.argv)
    try:
        for rel, code in data["files"].items():
            dst = tmp / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(code, encoding="utf-8", newline="\n")
        sys.path.insert(0, str(tmp))
        sys.argv = [str(tmp / data["entry"])]
        if mode == "ui":
            os.environ.setdefault("DISPLAY", ":0")
            os.environ.setdefault("SDL_VIDEODRIVER", "x11")
            os.environ.setdefault("PULSE_SERVER", "127.0.0.1")
        runpy.run_path(str(tmp / data["entry"]), run_name="__main__")
    finally:
        sys.path[:] = old_path
        sys.argv = old_argv
        shutil.rmtree(tmp, ignore_errors=True)

def load_state():
    ensure()
    if STATE.exists():
        try:
            return json.loads(STATE.read_text())
        except Exception:
            return {}
    return {}

def save_state(data):
    ensure()
    STATE.write_text(json.dumps(data, separators=(",", ":")))

def set_ui_pending(path):
    target = find_file(path, want_m=True)
    data = load_state()
    data["pending_ui"] = str(target)
    save_state(data)
    print("open termux-x11 and connect")
    print("then type: ui.run")

def try_start_x11():
    cmd = shutil.which("termux-x11")
    if cmd:
        try:
            subprocess.Popen([cmd, ":0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    try:
        subprocess.run(["am", "start", "--user", "0", "-n", "com.termux.x11/.MainActivity"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
    except Exception:
        pass

def run_ui(path=None):
    ensure()
    if path is None:
        data = load_state()
        path = data.get("pending_ui")
    if not path:
        raise SystemExit("file not found")
    target = find_file(path, want_m=True)
    try_start_x11()
    print("connect termux-x11 now")
    try:
        input("ready> ")
    except EOFError:
        pass
    run_payload(str(target), mode="ui")

def parse_type(args):
    if not args:
        return "prints"
    joined = "".join(args).replace(" ", "").lower()
    if "type=ui" in joined or joined == "ui":
        return "ui"
    if "type=print" in joined or "type=prints" in joined or joined in ("print", "prints"):
        return "prints"
    if args and args[0].lower() == "ui":
        return "ui"
    return "prints"

def run_m_command(args):
    if not args:
        path = input().strip()
        mode = "prints"
    else:
        path = args[0]
        mode = parse_type(args[1:])
    if mode == "ui":
        set_ui_pending(path)
    else:
        run_payload(path, mode="prints")

def list_files():
    ensure()
    print("src:")
    for p in sorted(SRC.rglob("*")):
        if p.is_file():
            print(" " + p.relative_to(SRC).as_posix())
    print("build:")
    for p in sorted(BUILD.glob("*.m")):
        print(" " + p.name)

def clean_all():
    ensure()
    shutil.rmtree(SRC, ignore_errors=True)
    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(CACHE, ignore_errors=True)
    ensure()
    print(str(HOME))

def tp_cmd(args):
    ensure()
    if len(args) >= 3 and args[-2] == "to":
        src = find_file(args[0], want_m=True)
        dst_raw = args[-1].replace("/ddcard", "/sdcard")
        dst = Path(dst_raw).expanduser()
        dst.mkdir(parents=True, exist_ok=True)
        out = dst / src.name
        shutil.copy2(src, out)
        print(str(out))
        return
    raise SystemExit("usage: tp file.m to /path")

def dot_run(name, args):
    path = name[:-4]
    mode = parse_type(args)
    if mode == "ui":
        set_ui_pending(path)
    else:
        run_payload(path, mode="prints")

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
                run_m_command(args)
            elif name == "ui.run":
                run_ui(args[0] if args else None)
            elif name == "m.list":
                list_files()
            elif name == "m.clean":
                clean_all()
            elif name == "tp":
                tp_cmd(args)
            elif name.endswith(".run"):
                dot_run(name, args)
            else:
                print("unknown")
        except SystemExit as e:
            if str(e):
                print(str(e))
        except Exception as e:
            print(str(e))

def main():
    prog = Path(sys.argv[0]).name
    args = sys.argv[1:]
    try:
        if prog == "m.make":
            data = None if sys.stdin.isatty() else sys.stdin.read()
            if data == "":
                data = None
            make_file(args[0] if args else None, data)
        elif prog == "m.build":
            build_file(args[0] if args else None)
        elif prog == "m.run":
            run_m_command(args)
        elif prog == "ui.run":
            run_ui(args[0] if args else None)
        elif prog == "tp":
            tp_cmd(args)
        elif prog == "m.clean":
            clean_all()
        else:
            if args:
                head = args[0]
                tail = args[1:]
                if head == "make":
                    data = None if sys.stdin.isatty() else sys.stdin.read()
                    if data == "":
                        data = None
                    make_file(tail[0] if tail else None, data)
                elif head == "build":
                    build_file(tail[0] if tail else None)
                elif head == "run":
                    run_m_command(tail)
                elif head == "ui.run":
                    run_ui(tail[0] if tail else None)
                elif head == "list":
                    list_files()
                elif head == "clean":
                    clean_all()
                elif head.endswith(".run"):
                    dot_run(head, tail)
                else:
                    shell()
            else:
                shell()
    except KeyboardInterrupt:
        print()
        raise SystemExit(130)
    except SystemExit as e:
        if str(e):
            print(str(e))
        raise SystemExit(1)

if __name__ == "__main__":
    main()
PY

chmod 755 "$PKG$PREFIX_DIR/bin/m.enter"
for x in m.make m.build m.run ui.run tp m.clean; do
    ln -s m.enter "$PKG$PREFIX_DIR/bin/$x"
done

find "$PKG" -type d -exec chmod 755 {} \;
find "$PKG" -type f -exec chmod 644 {} \;
chmod 755 "$PKG$PREFIX_DIR/bin/m.enter"
chmod 644 "$PKG/DEBIAN/control"

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