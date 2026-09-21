#!/usr/bin/env bash
# MA3063 OpenWrt build script (RG-MA3063 / ipq5018, hzyitc ipq50xx 23.05, kernel 5.15.150)
# 设计要点：
#  - 内核 5.15.150 相对 hzyitc 的 config-5.15 模板多出一批 NEW 符号，OpenWrt 在 target/linux
#    prepare 阶段用 kconfig 的 syncconfig 生成 auto.conf；syncconfig 在云端非 TTY(stdin=/dev/null)
#    遇 NEW 符号直接报错退出且不读 stdin -> 构建崩溃。
#  - 机制级根治：修补解包后的内核 conf.c，在已有的 "case syncconfig:" 标签后追加
#    conf_set_all_new_symbols(def_default)，让 syncconfig 对全部 NEW 符号取 Kconfig 默认值、
#    不弹提示，且不影响其写 include/config/auto.conf 的职责（与 olddefconfig 同一机制）。
#    这样写【不会】产生重复 case 标签（5.15 里 syncconfig 已与 oldconfig 共享同一 case）。
#  - 鸡生蛋：prepare 内部才解包内核源码，而 prepare 本身又跑 syncconfig。故先跑一遍 prepare
#    解包（config 报错容错），打补丁后再跑一遍 prepare 做 configure（extract stamp 已存在，
#    不会重新解包覆盖补丁）。
set -euo pipefail

PATCHES="${GITHUB_WORKSPACE:?}/ma3063-patches"
OPENWRT="${GITHUB_WORKSPACE:?}/openwrt"
cd "$OPENWRT"
# 所有 make 输出都落到 build.log，便于失败时通过 build-output 分支回传诊断
: > build.log

echo "== [1/8] copy MA3063 DTS into tree ==" | tee -a build.log
mkdir -p target/linux/ipq50xx/dts
cp "$PATCHES/files/target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts" \
   target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts

echo "== [2/8] register MA3063 device in image/Makefile ==" | tee -a build.log
python3 - <<'PY' 2>&1 | tee -a build.log
p = "target/linux/ipq50xx/image/Makefile"
s = open(p).read()
block = '''
define Device/ruijie_rg-ma3063
  $(call Device/FitImage)
  $(call Device/UbiFit)
  SOC := ipq5018
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-MA3063
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  DEVICE_DTS := ipq5018-ruijie-ma3063
  DEVICE_DTS_CONFIG := config@mp03.5-c1
  IMAGES := nand-factory.ubi sysupgrade.tar
  IMAGE/sysupgrade.tar := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := ath11k-firmware-ipq5018 ath11k-firmware-qcn6122 ipq-wifi-cmcc_rax3000q
endef
TARGET_DEVICES += ruijie_rg-ma3063
'''
marker = "$(eval $(call BuildImage))"
if marker not in s:
    raise SystemExit("ERROR: BuildImage marker not found in image/Makefile")
if "ruijie_rg-ma3063" in s:
    print("device already registered, skip")
else:
    s = s.replace(marker, block + "\n" + marker, 1)
    open(p, "w").write(s)
    print("patched image/Makefile OK")
PY

echo "== [3/8] write .config and run defconfig ==" | tee -a build.log
cat > .config <<'EOF'
CONFIG_TARGET_ipq50xx=y
CONFIG_TARGET_ipq50xx_aarch64=y
CONFIG_TARGET_ipq50xx_aarch64_DEVICE_ruijie_rg-ma3063=y
CONFIG_PACKAGE_ath11k-firmware-ipq5018=y
CONFIG_PACKAGE_ath11k-firmware-qcn6122=y
CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q=y
CONFIG_PACKAGE_wpad-basic-wolfssl=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_ARM64_EPAN=y
EOF
make defconfig 2>&1 | tee -a build.log

echo "== [4/8] pre-fill known arch symbols into target config template (insurance) ==" | tee -a build.log
for f in $(find target/linux/ipq50xx -name 'config-5.15*' 2>/dev/null); do
  {
    grep -q "CONFIG_ARM64_EPAN" "$f"        || echo "CONFIG_ARM64_EPAN=y"
    grep -q "CONFIG_ARM64_PA_BITS_48" "$f"  || echo "CONFIG_ARM64_PA_BITS_48=y"
    grep -q "CONFIG_ARM64_VA_BITS_39" "$f"  || echo "CONFIG_ARM64_VA_BITS_39=y"
    grep -q "CONFIG_ARM64_4K_PAGES" "$f"    || echo "CONFIG_ARM64_4K_PAGES=y"
    grep -q "CONFIG_QCOM_CLK_APCC_MSM8996" "$f" || echo "# CONFIG_QCOM_CLK_APCC_MSM8996 is not set"
  } >> "$f"
  echo "patched $f" | tee -a build.log
done

# 探测内核目录（用 find，避免 ls 在 set -e + pipefail 下因无匹配而炸脚本）
detect_linux() {
  find build_dir -maxdepth 5 -type d -name 'linux-5.15.150' 2>/dev/null | head -1
}

echo "== [5/8] prepare pass 1: extract kernel (syncconfig prompt-fail tolerated) ==" | tee -a build.log
LINUX="$(detect_linux)"
if [ -z "$LINUX" ]; then
  set +e
  make target/linux/prepare V=s 2>&1 | tee -a build.log
  rc1=${PIPESTATUS[0]}
  set -e
  echo "prepare pass1 rc=$rc1 (non-zero expected if syncconfig prompted before conf.c patch)" | tee -a build.log
  LINUX="$(detect_linux)"
fi
[ -n "$LINUX" ] || { echo "ERROR: kernel source not extracted (check build.log for download/extract error)"; exit 1; }
echo "linux source dir: $LINUX" | tee -a build.log

echo "== [6/8] SAFE conf.c patch (no duplicate label) + force rebuild conf binary ==" | tee -a build.log
CF="$LINUX/scripts/kconfig/conf.c"
python3 - "$CF" <<'PYEOF' 2>&1 | tee -a build.log
import sys, os
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
if 'MA3063_NOSYNC' in s:
    print("conf.c already patched, skip")
    sys.exit(0)
# Preferred anchor: main switch's 'case syncconfig:' (shared with oldconfig,
# body is conf_read(input_file); break;). Inserting the default-set BEFORE
# conf_read means: conf_set_all_new_symbols first sets every not-yet-set symbol
# to its Kconfig default, then conf_read(input_file) overrides the listed ones
# from .config; unlisted NEW symbols keep their default -> no prompt.
needle = 'case syncconfig:'
if needle in s:
    s = s.replace(needle,
        'case syncconfig:\n\tconf_set_all_new_symbols(def_default); /* MA3063_NOSYNC */',
        1)
    print("patched conf.c via main-switch 'case syncconfig:' (default-set before conf_read)")
elif 'conf(conf_syncconfig)' in s:
    # Fallback: second switch's syncconfig call (after .config read).
    s = s.replace('conf(conf_syncconfig)',
        'conf_set_all_new_symbols(def_default);\n\tconf(conf_syncconfig)', 1)
    print("patched conf.c via second-switch 'conf(conf_syncconfig)'")
else:
    print("ERROR: no known syncconfig anchor found in %s" % p)
    sys.exit(2)
open(p, 'w').write(s)
PYEOF
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
# Force rebuild of the kconfig 'conf' host binary so the patched conf.c takes effect.
# (mtime-based rebuild is unreliable across OpenWrt's prepare; remove the binary AND
#  its object explicitly.)
rm -f "$LINUX/scripts/kconfig/conf" "$LINUX/scripts/kconfig/conf.o" 2>/dev/null || true
echo "removed stale conf + conf.o -> kernel Makefile will recompile from patched conf.c" | tee -a build.log

echo "== [7/8] prepare pass 2: configure kernel with patched conf.c (no prompt) ==" | tee -a build.log
make target/linux/prepare V=s 2>&1 | tee -a build.log
echo "prepare pass2 OK" | tee -a build.log

echo "== [8/8] build ==" | tee -a build.log
make -j"$(nproc)" V=s 2>&1 | tee -a build.log
echo "BUILD OK" | tee -a build.log
