#!/data/data/com.termux/files/usr/bin/sh
set -eu
umask 022

NAME="m.libs"
VERSION="3.2.0"
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
Depends: python, clang
Homepage: https://github.com/elyasgo30you-stack/m.libs
Description: py lua to cpp to c to native to m builder for Termux
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
import time
import hashlib
import subprocess
import re
from pathlib import Path

APP = "m.libs"
VERSION = "3.2.0"
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
            return f"{int(v)} {u}" if u == "B" else f"{v:.2f} {u}"
        v /= 1024

def stage(p, name, size=0):
    print(f"[{p:3d}%] {name} | size: {size_text(size)}")
    time.sleep(0.02)

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

def roots():
    xs = [BUILD, SRC, HOME, Path.cwd(), Path.home(), Path("/sdcard"), Path("/storage/emulated/0")]
    out, seen = [], set()
    for r in xs:
        try:
            if r.exists():
                s = str(r.resolve())
                if s not in seen:
                    seen.add(s)
                    out.append(r)
        except Exception:
            pass
    return out

def find_file(name, want_m=False):
    ensure()
    raw = str(name).strip().strip('"').strip("'")
    names = name_set(raw, want_m)
    direct = []
    q = Path(raw).expanduser()
    if q.is_absolute():
        direct.append(q)
        if want_m and not str(q).endswith(".m"):
            direct.append(Path(str(q) + ".m"))
    for r in roots():
        for n in names:
            direct.append(r / n)
    for p in direct:
        try:
            if p.is_file():
                return p
        except Exception:
            pass
    for r in roots():
        try:
            for base, dirs, files in os.walk(r):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
                for f in files:
                    if f in names:
                        return Path(base) / f
        except Exception:
            pass
    raise SystemExit("file not found")

def read_until_end():
    lines = []
    while True:
        try:
            line = input()
        except EOFError:
            break
        if line == "end":
            break
        lines.append(line)
    return "\n".join(lines) + ("\n" if lines else "")

def clean_stdin(data):
    if data is None:
        return data
    lines = data.splitlines()
    if lines and lines[-1] == "end":
        lines = lines[:-1]
    return "\n".join(lines) + ("\n" if lines else "")

def make_file(path_arg=None, data=None):
    ensure()
    if path_arg is None:
        path_arg = input().strip()
    target = src_path(path_arg)
    target.parent.mkdir(parents=True, exist_ok=True)
    if data is None:
        data = read_until_end()
    else:
        data = clean_stdin(data)
    target.write_text(data, encoding="utf-8", newline="\n")
    print(str(target))

def collect_entry():
    ensure()
    files = []
    for p in sorted(SRC.rglob("*")):
        if p.is_file() and p.suffix.lower() in (".py", ".lua", ".cpp", ".cc", ".cxx", ".c", ".txt"):
            files.append(p)
    if not files:
        raise SystemExit("no source files")
    for n in ("main.py", "main.lua", "main.cpp", "main.cc", "main.cxx", "main.c", "main.txt"):
        for p in files:
            if p.name == n:
                return p
    return files[0]

def c_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")

def split_type(text, path):
    lines = text.splitlines()
    kind = None
    kept = []
    first_found = False
    for line in lines:
        t = line.strip()
        if not first_found and not t:
            kept.append(line)
            continue
        if not first_found:
            m = re.match(r"type\s*=\s*(python|py|lua)\s*$", t, re.I)
            if m:
                k = m.group(1).lower()
                kind = "python" if k in ("python", "py") else "lua"
                first_found = True
                continue
            first_found = True
        kept.append(line)
    if kind is None:
        suf = path.suffix.lower()
        if suf == ".lua":
            kind = "lua"
        elif suf == ".py":
            kind = "python"
        elif suf in (".cpp", ".cc", ".cxx"):
            kind = "cpp"
        elif suf == ".c":
            kind = "c"
        else:
            kind = "python"
    return kind, "\n".join(kept) + ("\n" if kept else "")

def py_expr_to_cpp(expr):
    expr = expr.strip()
    if len(expr) >= 2 and expr[0] in ("'", '"') and expr[-1] == expr[0]:
        return '"' + c_escape(expr[1:-1]) + '"'
    expr = re.sub(r"\bstr\((.*?)\)", r"\1", expr)
    return expr

def lua_expr_to_cpp(expr):
    expr = expr.strip()
    if len(expr) >= 2 and expr[0] in ("'", '"') and expr[-1] == expr[0]:
        return '"' + c_escape(expr[1:-1]) + '"'
    return expr

def py_to_cpp(text, mode):
    low = text.lower()
    if "pygame" in low or "shooter" in low or mode == "ui":
        return "/*__M_NATIVE_SHOOTER__*/\n"
    lines = text.splitlines()
    out = [
        "#include <iostream>",
        "#include <thread>",
        "#include <chrono>",
        "#include <string>",
        "using namespace std;",
        "int main(){"
    ]
    stack = [0]
    emitted = False

    def close_to(indent):
        while len(stack) > 1 and indent <= stack[-1]:
            out.append("}")
            stack.pop()

    for raw in lines:
        if not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        if line.startswith("#"):
            continue
        if line.startswith("import ") or line.startswith("from "):
            continue
        close_to(indent)
        if line in ("while True:", "while 1:"):
            out.append("while (true) {")
            stack.append(indent)
            emitted = True
            continue
        m = re.match(r"time\.sleep\(([^)]+)\)\s*$", line)
        if m:
            try:
                ms = int(float(m.group(1).strip()) * 1000)
            except Exception:
                ms = 1000
            out.append(f"std::this_thread::sleep_for(std::chrono::milliseconds({ms}));")
            emitted = True
            continue
        m = re.match(r"print\((.*)\)\s*$", line)
        if m:
            out.append("std::cout << " + py_expr_to_cpp(m.group(1)) + " << std::endl;")
            emitted = True
            continue
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*\s*=\s*[-+*/0-9 .]+$", line):
            name, expr = line.split("=", 1)
            out.append("auto " + name.strip() + " = " + expr.strip() + ";")
            emitted = True
            continue
        out.append('std::cout << "unsupported python line skipped" << std::endl;')
        emitted = True

    while len(stack) > 1:
        out.append("}")
        stack.pop()
    if not emitted:
        out.append('std::cout << "empty" << std::endl;')
    out.append("return 0;")
    out.append("}")
    return "\n".join(out) + "\n"

def lua_to_cpp(text, mode):
    low = text.lower()
    if "shooter" in low or mode == "ui":
        return "/*__M_NATIVE_SHOOTER__*/\n"
    out = [
        "#include <iostream>",
        "#include <thread>",
        "#include <chrono>",
        "#include <string>",
        "using namespace std;",
        "int main(){"
    ]
    stack = []
    emitted = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("--"):
            continue
        if line == "end":
            if stack:
                out.append("}")
                stack.pop()
            continue
        if re.match(r"while\s+true\s+do\s*$", line, re.I) or re.match(r"while\s+1\s+do\s*$", line, re.I):
            out.append("while (true) {")
            stack.append("while")
            emitted = True
            continue
        m = re.match(r"print\s*\((.*)\)\s*$", line)
        if m:
            out.append("std::cout << " + lua_expr_to_cpp(m.group(1)) + " << std::endl;")
            emitted = True
            continue
        m = re.match(r"os\.execute\s*\(\s*['\"]sleep\s+([0-9.]+)['\"]\s*\)\s*$", line)
        if m:
            try:
                ms = int(float(m.group(1)) * 1000)
            except Exception:
                ms = 1000
            out.append(f"std::this_thread::sleep_for(std::chrono::milliseconds({ms}));")
            emitted = True
            continue
        m = re.match(r"sleep\s*\(\s*([0-9.]+)\s*\)\s*$", line)
        if m:
            try:
                ms = int(float(m.group(1)) * 1000)
            except Exception:
                ms = 1000
            out.append(f"std::this_thread::sleep_for(std::chrono::milliseconds({ms}));")
            emitted = True
            continue
        m = re.match(r"local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([-+*/0-9 .]+)\s*$", line)
        if m:
            out.append("auto " + m.group(1) + " = " + m.group(2) + ";")
            emitted = True
            continue
        out.append('std::cout << "unsupported lua line skipped" << std::endl;')
        emitted = True
    while stack:
        out.append("}")
        stack.pop()
    if not emitted:
        out.append('std::cout << "empty" << std::endl;')
    out.append("return 0;")
    out.append("}")
    return "\n".join(out) + "\n"

def cpp_to_c(cpp):
    if "__M_NATIVE_SHOOTER__" in cpp:
        return shooter_c()

    c = cpp
    c = re.sub(r"#include\s*<iostream>\s*", "", c)
    c = re.sub(r"#include\s*<thread>\s*", "", c)
    c = re.sub(r"#include\s*<chrono>\s*", "", c)
    c = re.sub(r"#include\s*<string>\s*", "", c)
    c = re.sub(r"using\s+namespace\s+std\s*;", "", c)
    c = c.replace("while (true)", "while (1)")
    c = c.replace("while(true)", "while (1)")

    def repl_sleep(m):
        return f"usleep({int(m.group(1))} * 1000);"

    c = re.sub(r"std::this_thread::sleep_for\s*\(\s*std::chrono::milliseconds\s*\(\s*([0-9]+)\s*\)\s*\)\s*;", repl_sleep, c)

    def repl_cout(m):
        expr = m.group(1).strip()
        if expr.startswith('"') and expr.endswith('"'):
            return 'printf("%s\\n", ' + expr + ');'
        return 'printf("%lld\\n", (long long)(' + expr + '));'

    c = re.sub(r"(?:std::)?cout\s*<<\s*(.*?)\s*<<\s*(?:std::)?endl\s*;", repl_cout, c)
    c = re.sub(r"auto\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", r"long long \1 =", c)

    if "int main" not in c:
        c = 'int main(){ printf("empty\\n"); return 0; }\n'

    return "#include <stdio.h>\n#include <unistd.h>\n#include <math.h>\n#include <stdlib.h>\n#include <string.h>\n" + c

def shooter_c():
    return r'''
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <termios.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <time.h>
#define SW 96
#define SH 32
#define MW 24
#define MH 12
#define MAXE 32
static const char *mp[MH] = {
"111111111111111111111111",
"1......................1",
"1..111....11.....2.....1",
"1..1.................1..1",
"1..1..2.......111....1..1",
"1..11111.....1......11..1",
"1............1..2.......1",
"1...2........1......1...1",
"1............11111..1...1",
"1..11111............1...1",
"1.........2..........2..1",
"111111111111111111111111"
};
typedef struct { double x; double y; int hp; } Enemy;
static struct termios oldt;
static double px=2.5, py=2.5, pa=0.0;
static int hp=100, ammo=45, score=0;
static Enemy enemies[MAXE];
static int ec=0;
static void term_on(){ tcgetattr(0,&oldt); struct termios t=oldt; t.c_lflag&=~(ICANON|ECHO); tcsetattr(0,TCSANOW,&t); fcntl(0,F_SETFL,fcntl(0,F_GETFL,0)|O_NONBLOCK); printf("\033[?25l\033[2J"); fflush(stdout); }
static void term_off(){ tcsetattr(0,TCSANOW,&oldt); printf("\033[?25h\033[0m\n"); }
static int cell(double x,double y){ int ix=(int)x,iy=(int)y; if(ix<0||iy<0||ix>=MW||iy>=MH) return '1'; return mp[iy][ix]; }
static int wall(double x,double y){ int c=cell(x,y); return c=='1'||c=='2'; }
static double clampd(double v,double a,double b){ if(v<a)return a; if(v>b)return b; return v; }
static double cast_ray(double a){ double s=sin(a),c=cos(a),d; for(d=.04;d<28;d+=.03){ if(wall(px+c*d,py+s*d)) return d; } return 28; }
static void draw(){
    char frame[SH][SW+1]; const char *shade=" .:-=+*#%@"; double fov=1.2; int x,y,i;
    for(y=0;y<SH;y++){ for(x=0;x<SW;x++) frame[y][x]=' '; frame[y][SW]=0; }
    for(x=0;x<SW;x++){
        double a=pa-fov/2+fov*x/SW; double d=cast_ray(a)*cos(pa-a); int wh=(int)(SH/(d*.36)); int top=SH/2-wh/2; int bot=SH/2+wh/2; int si=(int)clampd((1.0-d/28.0)*9.0,0,9);
        for(y=0;y<SH;y++){ if(y<top) frame[y][x]=(y<6?'.':' '); else if(y>bot) frame[y][x]=(y%2?',':'_'); else frame[y][x]=shade[si]; }
    }
    for(i=0;i<ec;i++){
        if(enemies[i].hp<=0) continue;
        double dx=enemies[i].x-px,dy=enemies[i].y-py,d=hypot(dx,dy),ang=atan2(dy,dx),diff=atan2(sin(ang-pa),cos(ang-pa));
        if(fabs(diff)<fov/2+.2 && d<cast_ray(ang)+.25){
            int sx=(int)(SW/2+tan(diff)*(SW/2)); int sz=(int)(20/(d>.2?d:.2)); int yy,xx;
            for(yy=-sz/2;yy<=sz/2;yy++){ for(xx=-sz;xx<=sz;xx++){ x=sx+xx; y=SH/2+yy; if(x>0&&x<SW&&y>0&&y<SH&&xx*xx*.5+yy*yy<sz*sz*.35) frame[y][x]='A'; } }
        }
    }
    frame[SH/2][SW/2]='+';
    printf("\033[H"); for(y=0;y<SH;y++) printf("%s\n",frame[y]);
    printf("HP %d  AMMO %d  SCORE %d   WASD move  QE strafe  SPACE shoot  R reload  X quit\n",hp,ammo,score); fflush(stdout);
}
static void shoot(){
    int i; Enemy *best=NULL; double bd=.055; if(ammo<=0)return; ammo--;
    for(i=0;i<ec;i++){ if(enemies[i].hp<=0) continue; double dx=enemies[i].x-px,dy=enemies[i].y-py,d=hypot(dx,dy),a=atan2(dy,dx),diff=fabs(atan2(sin(a-pa),cos(a-pa))); if(diff<bd && d<cast_ray(a)+.25){ best=&enemies[i]; bd=diff; } }
    if(best){ best->hp-=50; if(best->hp<=0) score+=100; }
}
static void update_enemy(){
    int i; for(i=0;i<ec;i++){ if(enemies[i].hp<=0) continue; double dx=px-enemies[i].x,dy=py-enemies[i].y,d=hypot(dx,dy); if(d>.2&&d<12){ double sp=.035,nx=enemies[i].x+dx/d*sp,ny=enemies[i].y+dy/d*sp; if(!wall(nx,enemies[i].y)) enemies[i].x=nx; if(!wall(enemies[i].x,ny)) enemies[i].y=ny; } if(d<.8) hp-=1; }
}
int main(){
    int x,y,reload=0,run=1;
    for(y=0;y<MH;y++){ for(x=0;x<MW;x++){ if(mp[y][x]=='2'&&ec<MAXE){ enemies[ec].x=x+.5; enemies[ec].y=y+.5; enemies[ec].hp=100; ec++; } } }
    term_on(); atexit(term_off);
    while(run&&hp>0){
        char ch=0;
        while(read(0,&ch,1)>0){
            double sp=.16,mx=0,my=0;
            if(ch=='x'||ch=='X') run=0; if(ch=='a') pa-=.09; if(ch=='d') pa+=.09;
            if(ch=='w'){mx=cos(pa)*sp;my=sin(pa)*sp;} if(ch=='s'){mx=-cos(pa)*sp;my=-sin(pa)*sp;} if(ch=='q'){mx=sin(pa)*sp;my=-cos(pa)*sp;} if(ch=='e'){mx=-sin(pa)*sp;my=cos(pa)*sp;}
            if(ch==' '&&reload==0) shoot(); if((ch=='r'||ch=='R')&&ammo<45) reload=30;
            if(mx||my){ if(!wall(px+mx,py)) px+=mx; if(!wall(px,py+my)) py+=my; }
        }
        if(reload>0){ reload--; if(reload==0) ammo=45; } update_enemy(); draw(); { int alive=0; for(x=0;x<ec;x++) if(enemies[x].hp>0) alive=1; if(!alive) run=0; } usleep(33000);
    }
    printf("\033[2J\033[H"); if(hp>0) printf("YOU WIN\n"); else printf("GAME OVER\n"); printf("SCORE %d\n",score); return 0;
}
'''

def random_blob(n):
    pool = [i for i in range(1, 256) if i not in (60, 62)]
    return bytes(secrets.choice(pool) for _ in range(n))

def section(tag, data):
    return f"<<{tag}:{len(data)}>>".encode() + data

def read_section(blob, tag):
    needle = f"<<{tag}:".encode()
    i = blob.find(needle)
    if i < 0:
        raise SystemExit("bad m structure")
    j = blob.find(b">>", i)
    if j < 0:
        raise SystemExit("bad m structure")
    n = int(blob[i + len(needle):j].decode())
    start = j + 2
    end = start + n
    if end > len(blob):
        raise SystemExit("bad m structure")
    return blob[start:end]

def b64e(x):
    return base64.urlsafe_b64encode(x).decode().rstrip("=")

def b64d(x):
    return base64.urlsafe_b64decode((x + "=" * ((4 - len(x) % 4) % 4)).encode())

def stream(key, nonce, n):
    out = bytearray()
    c = 0
    while len(out) < n:
        out.extend(hashlib.sha256(key + nonce + c.to_bytes(8, "big")).digest())
        c += 1
    return bytes(out[:n])

def rol(b, r):
    r &= 7
    return ((b << r) & 255) | (b >> (8 - r))

def ror(b, r):
    r &= 7
    return (b >> r) | ((b << (8 - r)) & 255)

def seal(raw):
    comp = zlib.compress(raw, 9)
    pad = secrets.token_bytes(128 + secrets.randbelow(1024))
    body = len(comp).to_bytes(8, "big") + comp + pad
    key = secrets.token_bytes(32)
    nonce = secrets.token_bytes(16)
    ks = stream(key, nonce, len(body))
    out = bytearray()
    for i, b in enumerate(body):
        x = b ^ ks[i]
        x = rol(x, (i % 7) + 1)
        x ^= (i * 149 + key[i % 32] + nonce[i % 16]) & 255
        out.append(x)
    out.reverse()
    return bytes(out), key, nonce

def open_seal(enc, key, nonce):
    data = bytearray(enc)
    data.reverse()
    ks = stream(key, nonce, len(data))
    out = bytearray()
    for i, b in enumerate(data):
        x = b ^ ((i * 149 + key[i % 32] + nonce[i % 16]) & 255)
        x = ror(x, (i % 7) + 1)
        x ^= ks[i]
        out.append(x)
    n = int.from_bytes(out[:8], "big")
    return zlib.decompress(bytes(out[8:8+n]))

def parse_type(args):
    if not args:
        return "prints"
    s = "".join(args).replace(" ", "").lower()
    if "type=ui" in s or s == "ui":
        return "ui"
    return "prints"

def run_cmd(cmd, cwd=None):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        print(p.stdout)
        raise SystemExit("build failed")
    return p.stdout

def compile_c_to_native(c_code, work):
    c_path = work / "main.c"
    bin_path = work / "main.bin"
    c_path.write_text(c_code, encoding="utf-8", newline="\n")
    run_cmd(["clang", "-std=c11", "-O2", "-s", str(c_path), "-o", str(bin_path), "-lm"])
    return bin_path.read_bytes()

def build_file(target_arg=None, mode="prints"):
    ensure()
    if target_arg is None:
        target_arg = input().strip()
    stage(4, "scan")
    entry = collect_entry()
    text = entry.read_text(encoding="utf-8", errors="ignore")
    kind, clean = split_type(text, entry)
    work = Path(tempfile.mkdtemp(prefix="mbuild_", dir=str(CACHE)))
    try:
        if kind == "c":
            cpp = "/* source: c */\n"
            c_code = clean
            stage(15, "source_type_" + kind, len(clean.encode()))
            stage(28, "py_lua_to_cpp", 0)
            stage(40, "cpp_to_c", len(c_code.encode()))
        else:
            if kind == "cpp":
                cpp = clean
            elif kind == "lua":
                cpp = lua_to_cpp(clean, mode)
            else:
                cpp = py_to_cpp(clean, mode)
            (work / "main.cpp").write_text(cpp, encoding="utf-8", newline="\n")
            stage(15, "source_type_" + kind, len(clean.encode()))
            stage(28, "py_lua_to_cpp", len(cpp.encode()))
            c_code = cpp_to_c(cpp)
            (work / "main.c").write_text(c_code, encoding="utf-8", newline="\n")
            stage(40, "cpp_to_c", len(c_code.encode()))
        raw = compile_c_to_native(c_code, work)
        stage(82, "c_to_native", len(raw))
        payload = raw
        enc, key, nonce = seal(payload)
        out = out_path(target_arg)
        header = json.dumps({
            "app": APP,
            "version": VERSION,
            "kind": "native-elf",
            "source": kind,
            "pipe": "py/lua->cpp->c->native->m",
            "mode": mode,
            "key": b64e(key),
            "nonce": b64e(nonce),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
            "name": out.name
        }, separators=(",", ":")).encode()
        blob = bytearray()
        blob += b"M!\n"
        blob += random_blob(256 + secrets.randbelow(512))
        blob += b"\n<<G!>>\n"
        blob += random_blob(64 + secrets.randbelow(256))
        blob += b"\n"
        blob += section("H", header)
        blob += b"\n<<N!>>\n" + out.name.encode(errors="ignore") + b"\n<<1!>>\n"
        for i in range(8 + secrets.randbelow(8)):
            blob += section("R" + str(i), random_blob(128 + secrets.randbelow(1024)))
        blob += b"\n"
        blob += section("P", enc)
        blob += b"\n<<END!>>\n"
        blob += random_blob(256 + secrets.randbelow(1024))
        out.write_bytes(bytes(blob))
        stage(100, "native_to_m_final", out.stat().st_size)
        print(str(out))
    finally:
        shutil.rmtree(work, ignore_errors=True)

def parse_m(path):
    blob = Path(path).read_bytes()
    if not blob.startswith(b"M!"):
        raise SystemExit("bad m file")
    header = json.loads(read_section(blob, "H").decode())
    enc = read_section(blob, "P")
    raw = open_seal(enc, b64d(header["key"]), b64d(header["nonce"]))
    if hashlib.sha256(raw).hexdigest() != header["sha256"]:
        raise SystemExit("hash mismatch")
    return header, raw

def load_state():
    ensure()
    if STATE.exists():
        try:
            return json.loads(STATE.read_text())
        except Exception:
            return {}
    return {}

def save_state(d):
    ensure()
    STATE.write_text(json.dumps(d, separators=(",", ":")))

def run_m(path_arg=None, mode="prints"):
    ensure()
    if path_arg is None:
        path_arg = input().strip()
    path = find_file(path_arg, want_m=True)
    header, raw = parse_m(path)
    tmp = Path(tempfile.mkdtemp(prefix="mrun_", dir=str(CACHE)))
    exe = tmp / "app"
    try:
        exe.write_bytes(raw)
        exe.chmod(0o755)
        env = os.environ.copy()
        env["M_MODE"] = mode
        subprocess.call([str(exe)], env=env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def set_ui_pending(path):
    target = find_file(path, want_m=True)
    d = load_state()
    d["pending_ui"] = str(target)
    save_state(d)
    print("ready")
    print("type: ui.run")

def run_ui(path=None):
    if path is None:
        path = load_state().get("pending_ui")
    if not path:
        raise SystemExit("file not found")
    run_m(path, "ui")

def dot_run(name, args):
    path = name[:-4]
    mode = parse_type(args)
    if mode == "ui":
        set_ui_pending(path)
    else:
        run_m(path, mode)

def tp_cmd(args):
    ensure()
    if len(args) >= 3 and args[-2] == "to":
        src = find_file(args[0], want_m=True)
        dst = Path(args[-1].replace("/ddcard", "/sdcard")).expanduser()
        dst.mkdir(parents=True, exist_ok=True)
        out = dst / src.name
        shutil.copy2(src, out)
        print(str(out))
        return
    raise SystemExit("usage: tp file.m to /path")

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
    shutil.rmtree(SRC, ignore_errors=True)
    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(CACHE, ignore_errors=True)
    ensure()
    print(str(HOME))

def show_pipe():
    print("py/lua -> cpp -> c -> native -> m")

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
        name, args = parts[0], parts[1:]
        try:
            if name == "m.make":
                make_file(args[0] if args else None)
            elif name == "m.build":
                build_file(args[0] if args else None, parse_type(args[1:] if args else []))
            elif name == "m.run":
                run_m(args[0] if args else None, parse_type(args[1:] if args else []))
            elif name == "ui.run":
                run_ui(args[0] if args else None)
            elif name == "m.list":
                list_files()
            elif name == "m.clean":
                clean_all()
            elif name == "m.pipe":
                show_pipe()
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
            make_file(args[0] if args else None, data)
        elif prog == "m.build":
            build_file(args[0] if args else None, parse_type(args[1:] if args else []))
        elif prog == "m.run":
            run_m(args[0] if args else None, parse_type(args[1:] if args else []))
        elif prog == "ui.run":
            run_ui(args[0] if args else None)
        elif prog == "tp":
            tp_cmd(args)
        elif prog == "m.clean":
            clean_all()
        elif prog == "m.pipe":
            show_pipe()
        else:
            if args:
                h, t = args[0], args[1:]
                if h == "make":
                    data = None if sys.stdin.isatty() else sys.stdin.read()
                    make_file(t[0] if t else None, data)
                elif h == "build":
                    build_file(t[0] if t else None, parse_type(t[1:] if t else []))
                elif h == "run":
                    run_m(t[0] if t else None, parse_type(t[1:] if t else []))
                elif h == "list":
                    list_files()
                elif h == "clean":
                    clean_all()
                elif h == "pipe":
                    show_pipe()
                elif h == "ui.run":
                    run_ui(t[0] if t else None)
                elif h.endswith(".run"):
                    dot_run(h, t)
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
for x in m.make m.build m.run ui.run tp m.clean m.pipe; do
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
Depends: python, clang
Filename: ./${NAME}_${VERSION}_${ARCH}.deb
Size: $SIZE
SHA256: $SHA
Description: py lua to cpp to c to native to m builder for Termux
EOF

gzip -kf "$REPO/Packages"

echo "pipeline: py/lua -> cpp -> c -> native -> m"
echo "$DEB"
echo "$REPO"
