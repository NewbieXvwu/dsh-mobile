#!/bin/sh
# Kotlin/Native 没有 macCatalyst 目标：macosArm64 静态框架的成员对象带
# platform=macOS 的 LC_BUILD_VERSION，ld 会拒绝把它们链入 macCatalyst 可执行
# 文件（"built for 'macOS'"）。arm64 macOS 与 arm64 Catalyst 共享同一 ABI，
# 通行做法是把归档成员的平台标注等尺寸改写为 MACCATALYST（vtool 无法在
# cmdsize 24 的 load command 上原地扩写，故用 python 直接改字段）。
# 在 Build KMP Framework phase 内、gradle link 之后调用；若 Kotlin/Native
# 官方支持 Catalyst 目标后可整体移除本脚本。
set -eu

BIN="$1"
MINOS="${2:-16.1}"
SDKV="${3:-}"

case "$(file -b "$BIN")" in
  *"ar archive"*) ;;
  *) echo "[patch-kmp-maccatalyst] $BIN is not an ar archive; skip" >&2; exit 0 ;;
esac

if [ -z "$SDKV" ]; then
  SDKV="$(/usr/bin/xcrun -sdk macosx --show-sdk-version)"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$BIN" "$work/in.ar"
(cd "$work" && ar x in.ar)

patched=0
for obj in "$work"/*.o; do
  [ -f "$obj" ] || continue
  if python3 - "$obj" "$MINOS" "$SDKV" << 'PYEOF' | grep -q PATCHED; then
import struct, sys

def ver(s):
    parts = [int(x) for x in s.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]

path, minos_s, sdk_s = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    data = bytearray(f.read())
if len(data) < 40 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
    sys.exit(0)  # 非 64 位 Mach-O，保持原样
ncmds = struct.unpack_from("<I", data, 16)[0]
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == 0x32:  # LC_BUILD_VERSION
        platform = struct.unpack_from("<I", data, off + 8)[0]
        if platform == 1:  # PLATFORM_MACOS -> PLATFORM_MACCATALYST
            struct.pack_into("<I", data, off + 8, 6)  # PLATFORM_MACCATALYST
            struct.pack_into("<I", data, off + 12, ver(minos_s))
            struct.pack_into("<I", data, off + 16, ver(sdk_s))
            with open(path, "wb") as f:
                f.write(data)
            print("PATCHED")
            sys.exit(0)
        break  # 已是其他平台（如 maccatalyst），保持幂等
    off += cmdsize
sys.exit(0)
PYEOF
    patched=$((patched + 1))
  fi
done

# macOS 的 libsqlite3 导出表缺失一批弃用 API（iOS 仍在），而 K/N 的
# sqlite-framework cinterop 成员被拉入链接时会全量引用它们。注入一个
# stub 对象补齐符号（Room 实际使用 bundled sqlite，这些函数运行期不会被调）。
cat > "$work/dsh_sqlite3_legacy_stubs.c" << 'CEOF'
/* macOS libsqlite3 缺失的弃用/可选 API 桩。仅用于满足静态链接的符号解析；
   运行期 Room 走 androidx sqlite bundled，不应调用到它们。 */
int sqlite3_aggregate_count(void) { return 0; }
int sqlite3_enable_shared_cache(void) { return 0; }
int sqlite3_expired(void) { return 0; }
int sqlite3_global_recover(void) { return 0; }
int sqlite3_memory_alarm(void) { return 0; }
int sqlite3_mutex_held(void) { return 0; }
int sqlite3_mutex_notheld(void) { return 0; }
void sqlite3_profile(void) {}
int sqlite3_progress_handler(void) { return 0; }
int sqlite3_snapshot_cmp(void) { return 0; }
void sqlite3_snapshot_free(void) {}
int sqlite3_snapshot_get(void) { return 0; }
int sqlite3_snapshot_open(void) { return 0; }
int sqlite3_snapshot_recover(void) { return 0; }
int sqlite3_stmt_scanstatus(void) { return 0; }
int sqlite3_stmt_scanstatus_reset(void) { return 0; }
int sqlite3_stmt_scanstatus_v2(void) { return 0; }
void sqlite3_thread_cleanup(void) {}
void sqlite3_trace(void) {}
int sqlite3_transfer_bindings(void) { return 0; }
int sqlite3_unlock_notify(void) { return 0; }
int sqlite3_win32_set_directory(void) { return 0; }
int sqlite3_win32_set_directory16(void) { return 0; }
int sqlite3_win32_set_directory8(void) { return 0; }
CEOF
/usr/bin/xcrun -sdk "$SDKROOT" clang -target "arm64-apple-ios${MINOS}-macabi" \
  -c "$work/dsh_sqlite3_legacy_stubs.c" -o "$work/dsh_sqlite3_legacy_stubs.o"

# 重建归档（成员顺序对链接无影响；ranlib 重新生成符号索引）
(cd "$work" && rm -f in.ar && ar qc out.ar *.o && ranlib out.ar)
cp "$work/out.ar" "$BIN"
echo "[patch-kmp-maccatalyst] rewrote $patched object(s) in $BIN -> maccatalyst minos=$MINOS sdk=$SDKV"
