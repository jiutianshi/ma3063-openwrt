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

echo "== [1/8] copy MA3063 DTS into tree =="
mkdir -p target/linux/ipq50xx/dts
cp "$PATCHES/files/target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts" \
   target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts

echo "== [2/8] register MA3063 device in image/Makefile =="
python3 - <<'PY'
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

echo "== [3/8] write .config and run defconfig =="
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
make defconfig

echo "== [4/8] pre-fill known arch symbols into target config template (insurance) =="
for f in $(find target/linux/ipq50xx -name 'config-5.15*' 2>/dev/null); do
  {
    grep -q "CONFIG_ARM64_EPAN" "$f"        || echo "CONFIG_ARM64_EPAN=y"
    grep -q "CONFIG_ARM64_PA_BITS_48" "$f"  || echo "CONFIG_ARM64_PA_BITS_48=y"
    grep -q "CONFIG_ARM64_VA_BITS_39" "$f"  || echo "CONFIG_ARM64_VA_BITS_39=y"
    grep -q "CONFIG_ARM64_4K_PAGES" "$f"    || echo "CONFIG_ARM64_4K_PAGES=y"
    grep -q "CONFIG_QCOM_CLK_APCC_MSM8996" "$f" || echo "# CONFIG_QCOM_CLK_APCC_MSM8996 is not set"
  } >> "$f"
  echo "patched $f"
done

echo "== [5/8] prepare pass 1: extract kernel (syncconfig may prompt-fail, tolerated) =="
LINUX=$(ls -d build_dir/target-aarch64_cortex-a53_musl/linux-ipq50xx_aarch64/linux-5.15.150 2>/dev/null | head -1)
if [ -z "$LINUX" ]; then
  make target/linux/prepare V=s || echo "[warn] prepare pass1 non-zero (expected if syncconfig prompted before patch); will retry after patching conf.c"
  LINUX=$(ls -d build_dir/target-aarch64_cortex-a53_musl/linux-ipq50xx_aarch64/linux-5.15.150 2>/dev/null | head -1)
fi
[ -n "$LINUX" ] || { echo "ERROR: kernel source not extracted"; exit 1; }
echo "linux source dir: $LINUX"

echo "== [6/8] SAFE conf.c patch (append to existing 'case syncconfig:', no duplicate label) =="
CF="$LINUX/scripts/kconfig/conf.c"
python3 - "$CF" <<'PYEOF'
import sys, os
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
if 'MA3063_NOSYNC' in s:
    print("conf.c already patched, skip")
    sys.exit(0)
needle = 'case syncconfig:'
if needle not in s:
    print("ERROR: '%s' not found in %s" % (needle, p))
    sys.exit(2)
s = s.replace(needle,
    'case syncconfig:\n\tconf_set_all_new_symbols(def_default); /* MA3063_NOSYNC */',
    1)
open(p, 'w').write(s)
print("patched conf.c: syncconfig now sets all NEW symbols to default (no prompt)")
cb = os.path.join(os.path.dirname(p), 'conf')
if os.path.exists(cb):
    os.remove(cb)
    print("removed stale conf binary -> force rebuild from patched source")
PYEOF

echo "== [7/8] prepare pass 2: configure kernel with patched conf.c (no prompt) =="
make target/linux/prepare V=s

echo "== [8/8] build =="
set +o pipefail
make -j"$(nproc)" V=s 2>&1 | tee build.log
rc=${PIPESTATUS[1]}
set -o pipefail
if [ "$rc" -ne 0 ]; then
  echo "make failed rc=$rc"
  exit "$rc"
fi
echo "BUILD OK"
