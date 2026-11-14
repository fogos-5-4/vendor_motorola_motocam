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

REPO_URL="${MOTOCAM_URL:-https://github.com/tiraq-official/vendor_motorola_motocam.git}"
BRANCH="${MOTOCAM_BRANCH:-test}"
DEVICE="${MOTOCAM_DEVICE:-fogos}"
ROM_ROOT="${ANDROID_BUILD_TOP:-}"
SKIP_LFS=0
DO_PATCH=1

CAM_DIR="vendor/motorola/motocamera"
APK_REL="proprietary/product/priv-app/MotCamera4/MotCamera4.apk"
APK_MIN_BYTES=100000000
PATCHER="patch_cameraserver_shutter.py"

c_ok()   { printf '\033[1;32m  ok  \033[0m%s\n' "$*"; }
c_info() { printf '\033[1;34m  ..  \033[0m%s\n' "$*"; }
c_warn() { printf '\033[1;33m warn \033[0m%s\n' "$*"; }
c_err()  { printf '\033[1;31m fail \033[0m%s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

usage() {
    sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
    cat <<'EOF'
Options:
  -r, --root DIR      ROM source root (default: $ANDROID_BUILD_TOP, else cwd)
  -b, --branch NAME   camera repo branch (default: test)
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
step "1/6  checking the ROM tree"
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
step "2/6  checking git-lfs"
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
step "3/6  camera repo -> $CAM_DIR (branch $BRANCH)"
# ---------------------------------------------------------------------------
if [ -d "$CAM_DIR/.git" ]; then
    c_info "already cloned, updating"
    git -C "$CAM_DIR" fetch --all --prune >/dev/null 2>&1 || c_warn "git fetch failed (offline?)"
    if [ -n "$(git -C "$CAM_DIR" status --porcelain 2>/dev/null)" ]; then
        c_warn "working tree has local changes -- leaving it alone"
    else
        git -C "$CAM_DIR" checkout "$BRANCH" >/dev/null 2>&1 || c_warn "branch $BRANCH not found, staying on current"
        git -C "$CAM_DIR" pull --ff-only >/dev/null 2>&1 || c_warn "could not fast-forward"
    fi
else
    mkdir -p "$(dirname "$CAM_DIR")"
    git clone --branch "$BRANCH" "$REPO_URL" "$CAM_DIR" || die "clone failed"
fi
c_ok "repo at $(git -C "$CAM_DIR" rev-parse --short HEAD) ($(git -C "$CAM_DIR" rev-parse --abbrev-ref HEAD))"

# ---------------------------------------------------------------------------
step "4/6  pulling the LFS objects"
# ---------------------------------------------------------------------------
if [ "$SKIP_LFS" -eq 0 ]; then
    git -C "$CAM_DIR" lfs install --local >/dev/null 2>&1 || c_warn "git lfs install --local failed"
    c_info "downloading LFS objects (the APK is ~238 MB, this takes a while)"
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
step "5/6  wiring the camera into device/motorola/$DEVICE"
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
step "6/6  cameraserver shutter-order patch"
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
    if python3 "$CAM_DIR/$PATCHER" "$ROM_ROOT"; then
        c_ok "cameraserver patched"
    else
        die "could not patch cameraserver -- see the message above"
    fi
fi

# ---------------------------------------------------------------------------
step "summary"
# ---------------------------------------------------------------------------
printf '  camera repo : %s (%s @ %s)\n' "$CAM_DIR" \
    "$(git -C "$CAM_DIR" rev-parse --abbrev-ref HEAD)" "$(git -C "$CAM_DIR" rev-parse --short HEAD)"
printf '  APK         : %s MB\n' "$((APK_SIZE / 1024 / 1024))"
printf '  device.mk   : %s\n' "$DEV_MK"
[ "$DO_PATCH" -eq 1 ] && printf '  cameraserver: patched at build time via motocamera.mk\n'

if [ -f "vendor/motorola/fogos/proprietary/vendor/lib64/libgui_vendor.so" ]; then
    c_ok "libgui_vendor.so present in the vendor repo"
else
    c_warn "libgui_vendor.so NOT found in vendor/motorola/fogos"
    printf '        the V1UGS35M camera HAL needs it or camera.qcom.so fails to load\n'
    printf '        (missing library = black preview). Add it from your stock dump:\n'
    printf '          vendor/lib64/libgui_vendor.so\n'
fi

cat <<EOF

Next:
  source build/envsetup.sh && lunch <device>-userdebug
  mka bacon            # or brunch $DEVICE

Watch the build log for:
  [PASS] .../Camera3OutputUtils.cpp: <n> shutter check(s), patched

Then on device, after flashing:
  adb shell sha1sum /vendor/lib64/hw/camera.qcom.so      # must match your dump
  adb shell getprop | grep -iE "camera\\.(cfa|aux|expose)"
  adb logcat -b all -d | grep -iE "out-of-order|ERROR_BUFFER|CameraFsm"

Commit what this changed (both trees are dirty now):
  ( cd device/motorola/$DEVICE && git add -A && git commit -m "fogos: inherit the Motorola camera tree" )
  ( cd $CAM_DIR && git add -A && git commit -m "motocamera: apply the cameraserver shutter-order workaround" )

EOF
