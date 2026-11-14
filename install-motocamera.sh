#!/usr/bin/env bash
#
# install-motocamera.sh -- set up the Motorola camera port in one command.
#
#   curl -LSs https://raw.githubusercontent.com/tiraq-official/vendor_motorola_motocam/test/install-motocamera.sh | bash
#
# or, with options:
#   curl -LSs <url> | bash -s -- --branch fogos --device fogos
#
# What it does, in order:
#   1. sanity-checks that you are in a ROM source root
#   2. checks git-lfs (exits with install instructions if missing)
#   3. clones the camera repo into vendor/motorola/motocamera
#   4. pulls the Git LFS objects and verifies MotCamera4.apk is the real ~238 MB file
#   5. adds the inherit-product line to device/motorola/<device>/device.mk
#   6. installs the cameraserver shutter-order patch and wires it into the build
#   7. prints what it changed and what to do next
#
# Re-running is safe: every step is idempotent.
#
set -uo pipefail

REPO_URL="${MOTOCAM_URL:-https://github.com/fogos-5-4/vendor_motorola_motocam.git}"
BRANCH="${MOTOCAM_BRANCH:-fogos}"
DEVICE="${MOTOCAM_DEVICE:-fogos}"
ROM_ROOT="${ANDROID_BUILD_TOP:-}"
SKIP_LFS=0
DO_PATCH=1

CAM_DIR="vendor/motorola/motocamera"
APK_REL="proprietary/product/priv-app/MotCamera4/MotCamera4.apk"
APK_MIN_BYTES=100000000
PATCHER="patch_cameraserver_shutter.py"

# ---------------------------------------------------------------------------
# presentation
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
    CY=$'\033[36m'; MG=$'\033[35m'; GR=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'
    TTY=1
else
    RST=; BOLD=; DIM=; CY=; MG=; GR=; YL=; RD=; TTY=0
fi

# box drawing and spinner glyphs only when the locale can render them
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
        FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        G_OK="✓"; G_NO="✗"; G_WARN="!"; G_DOT="·"; G_STEP="▸"
        RULE="────────────────────────────────────────────────────────────" ;;
    *)
        FRAMES=( '|' '/' '-' '\' )
        G_OK="+"; G_NO="x"; G_WARN="!"; G_DOT="-"; G_STEP=">"
        RULE="------------------------------------------------------------" ;;
esac

banner() {
    printf '\n'
    printf '%s' "$MG"
    printf '%s\n' ' __  __    ___    _____    ___     ___     _     __  __ '
    printf '%s\n' '|  \/  |  / _ \  |_   _|  / _ \   / __|   /_\   |  \/  |'
    printf '%s' "$CY"
    printf '%s\n' '| |\/| | | (_) |   | |   | (_) | | (__   / _ \  | |\/| |'
    printf '%s\n' '|_|  |_|  \___/    |_|    \___/   \___| /_/ \_\_|  |_|'
    printf '%s' "$RST"
    printf '   %sMotorola Camera 4 — drop-in installer%s\n' "$DIM" "$RST"
    printf '   %sdevice %s · branch %s%s\n' "$DIM" "$DEVICE" "$BRANCH" "$RST"
    printf '   %s%s%s\n' "$DIM" "$RULE" "$RST"
}

c_ok()   { printf '   %s%s%s %s\n' "$GR" "$G_OK" "$RST" "$*"; }
c_info() { printf '   %s%s%s %s\n' "$DIM" "$G_DOT" "$RST" "$*"; }
c_warn() { printf '   %s%s%s %s\n' "$YL" "$G_WARN" "$RST" "$*"; }
c_err()  { printf '   %s%s%s %s\n' "$RD" "$G_NO" "$RST" "$*" >&2; }
die()    { printf '\n' >&2; c_err "$*"; printf '\n' >&2; exit 1; }

step() {
    local raw="$*" n t
    if [ "$raw" != "${raw%% *}" ]; then
        n="${raw%% *}"
        t="${raw#* }"
        t="${t#"${t%%[![:space:]]*}"}"
        printf '\n%s%s%s %s[%s]%s %s%s%s\n' "$MG" "$G_STEP" "$RST" "$DIM" "$n" "$RST" "$BOLD" "$t" "$RST"
    else
        printf '\n%s%s%s %s%s%s\n' "$MG" "$G_STEP" "$RST" "$BOLD" "$raw" "$RST"
    fi
}

# spin "label" cmd...   -- quiet command with a live spinner
spin() {
    local msg="$1"; shift
    local out rc pid i=0
    out=$(mktemp 2>/dev/null) || out="/tmp/motocam.$$"
    "$@" >"$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$TTY" -eq 1 ]; then
            printf '\r   %s%s%s %s' "$CY" "${FRAMES[$((i % ${#FRAMES[@]}))]}" "$RST" "$msg"
            i=$((i + 1))
        fi
        sleep 0.1
    done
    wait "$pid"; rc=$?
    [ "$TTY" -eq 1 ] && printf '\r\033[K'
    if [ $rc -ne 0 ]; then
        c_err "$msg — failed"
        sed 's/^/     /' "$out" | tail -15 >&2
    fi
    rm -f "$out"
    return $rc
}

# run_visible "label" cmd...  -- lets the command draw its own progress bar
run_visible() {
    local msg="$1"; shift
    local start rc
    start=$(date +%s)
    [ "$TTY" -eq 1 ] && printf '   %s%s%s %s\n' "$DIM" "$G_DOT" "$RST" "$msg"
    "$@"; rc=$?
    if [ $rc -eq 0 ]; then
        c_ok "$msg — done in $(( $(date +%s) - start ))s"
    else
        c_err "$msg — failed after $(( $(date +%s) - start ))s"
    fi
    return $rc
}

kv()   { printf '   %s%-14s%s %s\n' "$DIM" "$1" "$RST" "$2"; }
hdr()  { printf '\n%s%s%s\n' "$BOLD" "$*" "$RST"; }
cmd()  { printf '   %s$ %s%s\n' "$DIM" "$*" "$RST"; }
note() { printf '   %s%s%s\n' "$DIM" "$*" "$RST"; }

usage() {
    sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
    cat <<'EOF'
Options:
  -r, --root DIR      ROM source root (default: $ANDROID_BUILD_TOP, else cwd)
  -b, --branch NAME   camera repo branch (default: fogos)
  -d, --device NAME   device codename (default: fogos)
      --skip-lfs      do not check/pull git-lfs (use only if the APK is already real)
      --no-patch      skip the cameraserver shutter-order patch
  -h, --help          this text

Environment: MOTOCAM_URL, MOTOCAM_BRANCH, MOTOCAM_DEVICE, ANDROID_BUILD_TOP
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--root)     ROM_ROOT="${2:-}"; shift 2 ;;
        -b|--branch)   BRANCH="${2:-}"; shift 2 ;;
        -d|--device)   DEVICE="${2:-}"; shift 2 ;;
        --skip-lfs)    SKIP_LFS=1; shift ;;
        --no-patch)    DO_PATCH=0; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
banner
step "1/7  checking the ROM tree"
# ---------------------------------------------------------------------------
[ -n "$ROM_ROOT" ] || ROM_ROOT="$PWD"
ROM_ROOT="$(cd "$ROM_ROOT" 2>/dev/null && pwd)" || die "cannot enter ROM root: ${ROM_ROOT:-<empty>}"
cd "$ROM_ROOT" || die "cannot enter ROM root: $ROM_ROOT"

if [ ! -f build/make/core/main.mk ] && [ ! -d .repo ]; then
    c_err "this does not look like an Android source root: $ROM_ROOT"
    cat >&2 <<'EOF'

  Run it from the top of your ROM tree (where build/ and .repo/ live), or pass the path:

    curl -LSs <url> | bash -s -- --root /path/to/rom

EOF
    exit 1
fi
c_ok "ROM root: $ROM_ROOT"

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || die "$t is required but not installed"
done
c_ok "git and python3 present"

# ---------------------------------------------------------------------------
step "2/7  checking git-lfs"
# ---------------------------------------------------------------------------
if [ "$SKIP_LFS" -eq 1 ]; then
    c_warn "--skip-lfs given, not checking git-lfs"
elif ! command -v git-lfs >/dev/null 2>&1; then
    c_err "git-lfs is NOT installed -- the camera APK would arrive as a 134-byte text pointer."
    cat >&2 <<'EOF'

  Install it first, then re-run this script:

    Debian / Ubuntu / Mint :  sudo apt-get install -y git-lfs
    Fedora                 :  sudo dnf install -y git-lfs
    Arch                   :  sudo pacman -S --noconfirm git-lfs
    openSUSE               :  sudo zypper install -y git-lfs
    macOS (brew)           :  brew install git-lfs

  Then once, for your user:

    git lfs install

EOF
    exit 1
else
    c_ok "git-lfs $(git lfs version 2>/dev/null | awk '{print $1}' | sed 's|git-lfs/||')"
fi

# ---------------------------------------------------------------------------
step "3/7  camera repo -> $CAM_DIR (branch $BRANCH)"
# ---------------------------------------------------------------------------
if [ -e "$CAM_DIR" ]; then
    c_warn "$CAM_DIR already exists -- stopping, nothing was changed."
    cat <<EOF

  If you really want a fresh install, remove it first and re-run:

    rm -rf $CAM_DIR
    curl -LSs <url> | bash

  If it is already installed and working, you do not need this script.
EOF
    exit 0
fi
mkdir -p "$(dirname "$CAM_DIR")"
run_visible "Cloning camera repo ($BRANCH)" \
        git clone --branch "$BRANCH" "$REPO_URL" "$CAM_DIR" || die "clone failed"
c_ok "repo at $(git -C "$CAM_DIR" rev-parse --short HEAD) ($(git -C "$CAM_DIR" rev-parse --abbrev-ref HEAD))"

# ---------------------------------------------------------------------------
step "4/7  pulling the LFS objects"
# ---------------------------------------------------------------------------
if [ "$SKIP_LFS" -eq 0 ]; then
    git -C "$CAM_DIR" lfs install --local >/dev/null 2>&1 || c_warn "git lfs install --local failed"
    c_info "downloading LFS objects (the APK is ~238 MB, this takes a while)"
    run_visible "Downloading LFS objects (the APK is ~238 MB)" \
        git -C "$CAM_DIR" lfs pull || die "git lfs pull failed"
fi

APK="$CAM_DIR/$APK_REL"
if [ ! -f "$APK" ]; then
    die "expected APK missing: $APK"
fi
APK_SIZE=$(stat -c %s "$APK" 2>/dev/null || stat -f %z "$APK")
if [ "$APK_SIZE" -lt "$APK_MIN_BYTES" ]; then
    c_err "MotCamera4.apk is only $APK_SIZE bytes -- that is a Git LFS pointer, not the APK."
    printf '        fix: cd %s && git lfs install && git lfs pull\n' "$CAM_DIR" >&2
    exit 1
fi
c_ok "MotCamera4.apk is $((APK_SIZE / 1024 / 1024)) MB (real file)"

# ---------------------------------------------------------------------------
step "5/7  camera / Dolby overlap"
# ---------------------------------------------------------------------------
cat > "$CAM_DIR/resolve_dolby_overlap.py" <<'PYDOLBYEOF'
#!/usr/bin/env python3
"""
resolve_dolby_overlap.py -- stop the camera tree and the Dolby tree from
installing the same two things.

hardware/dolby now ships (commits d517904, 4b31e2e):
  * a MotorolaSettingsProvider android_app_import module + PRODUCT_PACKAGES entry
  * moto-settings.jar copied to /system/framework/moto-settings.jar
  * moto-settings.xml copied to /system/etc/permissions/moto-settings.xml

vendor/motorola/motocamera ships the same three things, so with both trees in
the build you get:
  * "module MotorolaSettingsProvider already defined"        (two Android.bp)
  * overriding commands for /system/framework/moto-settings.jar
  * duplicate PRODUCT_COPY_FILES destination for moto-settings.xml

Dolby is the always-present tree and the camera is optional, so the camera
defers: this removes its copies. The jar, the permission XML and the provider
still land on the device -- from Dolby.

Everything else the camera needs (moto-core_services, com.motorola.motosignature,
their XMLs) is untouched, because Dolby does not ship those.

Usage: resolve_dolby_overlap.py <camera_repo_dir> <rom_root>
Exit:  0 nothing to do / resolved,  1 could not resolve (build would break)
"""

import os
import re
import sys

# module names the camera tree must drop when Dolby is present
DROP_MODULES = {"MotorolaSettingsProvider", "moto-settings"}
# PRODUCT_PACKAGES entries to drop
DROP_PACKAGES = {"MotorolaSettingsProvider", "moto-settings"}
# PRODUCT_COPY_FILES entries to drop (matched on the source path fragment)
DROP_COPY = ["system/etc/permissions/moto-settings.xml"]


def bp_blocks(text):
    """Yield (start, end, block_text) for every top-level {...} module block."""
    i = 0
    while i < len(text):
        brace = text.find("{", i)
        if brace < 0:
            return
        # walk back to the module type / name line
        line_start = text.rfind("\n", 0, brace) + 1
        start = line_start
        depth = 0
        j = brace
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        end = j
        # extend to end of line
        nl = text.find("\n", end)
        end = len(text) if nl < 0 else nl + 1
        yield start, end, text[start:end]
        i = end


def drop_modules(bp_path):
    text = open(bp_path, encoding="utf-8").read()
    removed = []
    out = []
    last = 0
    for start, end, block in bp_blocks(text):
        m = re.search(r'name:\s*"([^"]+)"', block)
        if m and m.group(1) in DROP_MODULES:
            out.append(text[last:start])
            last = end
            removed.append(m.group(1))
    if removed:
        out.append(text[last:])
        open(bp_path, "w", encoding="utf-8").write("".join(out))
    return removed


def drop_package_lines(mk_path):
    lines = open(mk_path, encoding="utf-8").read().splitlines(keepends=True)
    out = []
    removed = []
    for line in lines:
        stripped = line.strip().rstrip("\\").strip()
        if stripped in DROP_PACKAGES:
            removed.append(stripped)
            # if this was the last line of a continuation block, the previous
            # line must lose its trailing backslash
            if not line.rstrip("\n").rstrip().endswith("\\") and out:
                prev = out[-1]
                out[-1] = prev.rstrip("\n").rstrip()
                if out[-1].endswith("\\"):
                    out[-1] = out[-1][:-1].rstrip()
                out[-1] += "\n"
            continue
        out.append(line)
    if removed:
        open(mk_path, "w", encoding="utf-8").write("".join(out))
    return removed


def drop_copy_lines(mk_path):
    lines = open(mk_path, encoding="utf-8").read().splitlines(keepends=True)
    out = []
    removed = []
    for line in lines:
        if any(frag in line for frag in DROP_COPY):
            removed.append(line.strip())
            if not line.rstrip("\n").rstrip().endswith("\\") and out:
                prev = out[-1]
                out[-1] = prev.rstrip("\n").rstrip()
                if out[-1].endswith("\\"):
                    out[-1] = out[-1][:-1].rstrip()
                out[-1] += "\n"
            continue
        out.append(line)
    if removed:
        open(mk_path, "w", encoding="utf-8").write("".join(out))
    return removed


def dolby_ships_the_dupes(rom_root):
    """True if the Dolby tree in this ROM provides the provider + jar + xml."""
    for mk in ("hardware/dolby/dolby.mk",):
        path = os.path.join(rom_root, mk)
        if not os.path.isfile(path):
            continue
        txt = open(path, encoding="utf-8", errors="surrogateescape").read()
        has_provider = "MotorolaSettingsProvider" in txt
        has_jar = "moto-settings.jar" in txt
        if has_provider and has_jar:
            return True, path, (has_provider, has_jar)
        return False, path, (has_provider, has_jar)
    return False, None, (False, False)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cam = sys.argv[1]
    rom = sys.argv[2]

    bp = os.path.join(cam, "Android.bp")
    mk = os.path.join(cam, "motocamera.mk")
    for p in (bp, mk):
        if not os.path.isfile(p):
            print(f"[SKIP] {p} not found -- nothing to resolve", file=sys.stderr)
            return 0

    present, dolby_mk, flags = dolby_ships_the_dupes(rom)
    if dolby_mk is None:
        print("[SKIP] no hardware/dolby in this tree -- nothing to resolve", file=sys.stderr)
        return 0
    if not present:
        print(f"[SKIP] {os.path.relpath(dolby_mk, rom)} does not ship the overlapping files "
              f"(provider={flags[0]}, jar={flags[1]}) -- leaving the camera tree alone",
              file=sys.stderr)
        return 0

    mods = drop_modules(bp)
    pkgs = drop_package_lines(mk)
    copies = drop_copy_lines(mk)

    for m in mods:
        print(f"[PASS] removed Android.bp module {m}", file=sys.stderr)
    for p in pkgs:
        print(f"[PASS] removed {p} from PRODUCT_PACKAGES", file=sys.stderr)
    for c in copies:
        print(f"[PASS] removed copy of {c.split(':')[0]}", file=sys.stderr)

    # verify the overlap is actually gone
    txt_bp = open(bp, encoding="utf-8").read()
    txt_mk = open(mk, encoding="utf-8").read()
    problems = []
    for name in DROP_MODULES:
        if re.search(r'name:\s*"%s"' % re.escape(name), txt_bp):
            problems.append(f"Android.bp still defines {name}")
    for name in DROP_PACKAGES:
        if re.search(r"^\s*%s\s*\\?\s*$" % re.escape(name), txt_mk, re.M):
            problems.append(f"motocamera.mk still lists {name} in PRODUCT_PACKAGES")
    for frag in DROP_COPY:
        if frag in txt_mk:
            problems.append(f"motocamera.mk still copies {frag}")

    if problems:
        for p in problems:
            print(f"[FAIL] {p}", file=sys.stderr)
        return 1

    print("[PASS] camera tree now defers to hardware/dolby for "
          "MotorolaSettingsProvider + moto-settings", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYDOLBYEOF
chmod +x "$CAM_DIR/resolve_dolby_overlap.py"

# hardware/dolby now ships MotorolaSettingsProvider + moto-settings.jar itself,
# so the camera tree must not install them again (duplicate module name,
# duplicate /system/framework/moto-settings.jar, duplicate permission XML).
if python3 "$CAM_DIR/resolve_dolby_overlap.py" "$CAM_DIR" "$ROM_ROOT" 2>&1 | sed 's/^/     /'; then
    c_ok "overlap resolved"
else
    die "could not resolve the camera/Dolby overlap -- the build would fail on a duplicate module"
fi

# ---------------------------------------------------------------------------
step "6/7  wiring the camera into device/motorola/$DEVICE"
# ---------------------------------------------------------------------------
DEV_MK="device/motorola/$DEVICE/device.mk"
if [ ! -f "$DEV_MK" ]; then
    c_warn "$DEV_MK not found -- add this line to your product makefile yourself:"
    printf '        $(call inherit-product, %s/motocamera.mk)\n' "$CAM_DIR"
else
    if grep -q "inherit-product, *$CAM_DIR/motocamera.mk" "$DEV_MK"; then
        c_ok "already inherited in $DEV_MK"
    else
        {
            printf '\n# Motorola camera (added by install-motocamera.sh)\n'
            printf '$(call inherit-product, %s/motocamera.mk)\n' "$CAM_DIR"
        } >> "$DEV_MK"
        c_ok "added inherit-product to $DEV_MK"
    fi
fi

# ---------------------------------------------------------------------------
step "7/7  cameraserver shutter-order patch"
# ---------------------------------------------------------------------------
if [ "$DO_PATCH" -eq 0 ]; then
    c_warn "--no-patch given, skipping"
else
    cat > "$CAM_DIR/$PATCHER" <<'PYEOF'
#!/usr/bin/env python3
"""
Make AOSP cameraserver tolerate Motorola's out-of-order shutter notifications.

Motorola's CHI reports the *original* sensor frame number for queued captures,
so a shutter for frame 278 can arrive while CameraService waits on 284. AOSP
calls SET_ERR, which errors the whole camera device: buffers stop flowing
(black preview), the capture is cancelled, and the app tears down.

Rewrites those SET_ERR calls to ALOGW, keeping the `return;` after each one.

Exit: 0 patched / already patched / check absent / frameworks-av absent
      1 the check exists but could not be patched (fail the build, loudly)
"""
import os
import re
import sys

MARK = "MOTO_SHUTTER_ORDER_WORKAROUND"
REL = "frameworks/av/services/camera/libcameraservice"
CALL_RE = re.compile(r"\b(\w*SET_ERR\w*|[\w.>\-]*setErrorState)\s*\(")


def rom_root():
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    return os.environ.get("ANDROID_BUILD_TOP") or os.getcwd()


def find_call_end(src, open_paren):
    depth = 0
    i = open_paren
    in_str = in_chr = in_line = in_block = False
    while i < len(src):
        c = src[i]
        nxt = src[i + 1] if i + 1 < len(src) else ""
        if in_line:
            if c == "\n":
                in_line = False
        elif in_block:
            if c == "*" and nxt == "/":
                in_block = False
                i += 1
        elif in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif in_chr:
            if c == "\\":
                i += 1
            elif c == "'":
                in_chr = False
        else:
            if c == "/" and nxt == "/":
                in_line = True
                i += 1
            elif c == "/" and nxt == "*":
                in_block = True
                i += 1
            elif c == '"':
                in_str = True
            elif c == "'":
                in_chr = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    return -1


def patch_file(path):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    found = patched = 0
    out, pos = [], 0
    for m in CALL_RE.finditer(src):
        if m.start() < pos:
            continue
        end = find_call_end(src, m.end() - 1)
        if end < 0:
            continue
        call = src[m.start():end]
        if "out-of-order" not in call or "shutter" not in call.lower():
            continue
        found += 1
        if MARK in src[max(0, m.start() - 400):m.start()]:
            out.append(src[pos:end])
            pos = end
            continue
        line_start = src.rfind("\n", 0, m.start()) + 1
        indent = src[line_start:m.start()]
        new_call = m.group(1).replace("SET_ERR", "ALOGW").replace("setErrorState", "ALOGW") \
            + call[len(m.group(1)):]
        comment = (
            f"{indent}/* {MARK}: Moto's CHI reports the original sensor frame\n"
            f"{indent}   number for queued captures; AOSP would error the device\n"
            f"{indent}   instead of logging. The return below must stay. */\n"
        )
        out.append(src[pos:line_start])
        out.append(comment)
        out.append(indent + new_call)
        pos = end
        patched += 1
    if patched:
        out.append(src[pos:])
        open(path, "w", encoding="utf-8", errors="surrogateescape").write("".join(out))
    return found, patched


def main():
    root = rom_root()
    base = os.path.join(root, REL)
    if not os.path.isdir(base):
        print(f"[SKIP] {REL} not in this tree -- nothing to patch", file=sys.stderr)
        return 0

    files = []
    for dirpath, _d, names in os.walk(base):
        for n in names:
            if n.endswith((".cpp", ".cc", ".h")):
                files.append(os.path.join(dirpath, n))

    total_found = total_patched = 0
    for path in sorted(files):
        try:
            if "out-of-order" not in open(path, encoding="utf-8", errors="surrogateescape").read():
                continue
        except OSError:
            continue
        found, patched = patch_file(path)
        if found:
            total_found += found
            total_patched += patched
            state = "patched" if patched else "already patched"
            print(f"[PASS] {os.path.relpath(path, root)}: {found} shutter check(s), {state}",
                  file=sys.stderr)

    if total_found == 0:
        for path in files:
            try:
                if MARK in open(path, encoding="utf-8", errors="surrogateescape").read():
                    print("[PASS] cameraserver already patched -- nothing to do", file=sys.stderr)
                    return 0
            except OSError:
                pass
        print("[INFO] no out-of-order shutter check in this tree -- nothing to do", file=sys.stderr)
        return 0

    remaining = 0
    for path in files:
        try:
            txt = open(path, encoding="utf-8", errors="surrogateescape").read()
        except OSError:
            continue
        for m in CALL_RE.finditer(txt):
            end = find_call_end(txt, m.end() - 1)
            if end < 0:
                continue
            call = txt[m.start():end]
            if "out-of-order" in call and "shutter" in call.lower():
                remaining += 1
    if remaining:
        print(f"[FAIL] {remaining} shutter check(s) still call SET_ERR -- patch by hand",
              file=sys.stderr)
        return 1

    print(f"[PASS] cameraserver shutter-order workaround applied ({total_patched} site(s) now)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    chmod +x "$CAM_DIR/$PATCHER"
    c_ok "installed $CAM_DIR/$PATCHER"

    MK="$CAM_DIR/motocamera.mk"
    if [ ! -f "$MK" ]; then
        c_warn "$MK missing -- cannot wire the patch into the build"
    elif grep -q "$PATCHER" "$MK"; then
        c_ok "already wired into motocamera.mk"
    else
        {
            printf '\n# Moto CHI reports original frame numbers for queued captures; AOSP\n'
            printf '# cameraserver treats that as a protocol violation and errors the device.\n'
            printf '# Applied before frameworks/av is compiled.\n'
            printf '$(shell python3 $(MOTOCAMERA)/%s $(ANDROID_BUILD_TOP) >&2)\n' "$PATCHER"
        } >> "$MK"
        c_ok "wired into motocamera.mk"
    fi

    c_info "applying now"
    if python3 "$CAM_DIR/$PATCHER" "$ROM_ROOT" 2>&1 | sed 's/^/     /'; then
        c_ok "cameraserver patched"
    else
        die "could not patch cameraserver -- see the message above"
    fi
fi

# ---------------------------------------------------------------------------
step "done"
# ---------------------------------------------------------------------------
printf '   %s%s%s\n' "$DIM" "$RULE" "$RST"
kv "camera repo" "$CAM_DIR ($(git -C "$CAM_DIR" rev-parse --abbrev-ref HEAD) @ $(git -C "$CAM_DIR" rev-parse --short HEAD))"
kv "APK" "$((APK_SIZE / 1024 / 1024)) MB — real file, not an LFS pointer"
kv "device tree" "$DEV_MK"
[ "$DO_PATCH" -eq 1 ] && kv "cameraserver" "patched at build time via motocamera.mk"
[ -d hardware/dolby ] && kv "dolby" "camera defers to hardware/dolby"
printf '   %s%s%s\n' "$DIM" "$RULE" "$RST"

if [ -f "vendor/motorola/fogos/proprietary/vendor/lib64/libgui_vendor.so" ]; then
    c_ok "libgui_vendor.so present in the vendor repo"
else
    c_warn "libgui_vendor.so NOT found in vendor/motorola/fogos"
    note "the V1UGS35M camera HAL needs it or camera.qcom.so fails to load"
    note "(missing library = black preview). Add it from your stock dump:"
    note "  vendor/lib64/libgui_vendor.so"
fi

hdr "Next"
cmd "source build/envsetup.sh && lunch ${DEVICE}-userdebug"
cmd "mka bacon        # or: brunch $DEVICE"

hdr "Watch the build log for"
note "[PASS] .../Camera3OutputUtils.cpp: <n> shutter check(s), patched"

hdr "After flashing"
cmd "adb shell sha1sum /vendor/lib64/hw/camera.qcom.so"
note "must match the blob from your V1UGS35M dump"
cmd "adb logcat -b all -d | grep -iE \"out-of-order|ERROR_BUFFER|CameraFsm\""
note "no out-of-order lines while shooting in bright light = fixed"

hdr "Commit what changed"
cmd "( cd device/motorola/$DEVICE && git add -A && git commit -m \"fogos: inherit the Motorola camera tree\" )"
cmd "( cd $CAM_DIR && git add -A && git commit -m \"motocamera: apply the cameraserver shutter-order workaround\" )"
printf '\n'
