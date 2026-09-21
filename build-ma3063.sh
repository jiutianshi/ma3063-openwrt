#!/usr/bin/env bash
# MA3063 OpenWrt build script (RG-MA3063 / ipq5018, hzyitc ipq50xx 23.05, kernel 5.15.150)
#
# syncconfig NEW-symbol problem (mechanism):
#   OpenWrt 的 target/linux/prepare 用内核 kconfig 的 syncconfig 生成 auto.conf。
#   5.15.150 的 conf.c 中，case syncconfig:（main 第二处 switch，与 oldconfig 共享
#   check_conf 循环）对未设值的 NEW 符号会弹提示；CI 非 TTY(stdin=/dev/null) 时
#   读不到输入 -> 构建崩溃。
#   根治：给该 case 在 check_conf 循环【前】插入 conf_set_all_new_symbols(def_default)
#   （与 defconfig 同机制），让所有 NEW 符号先取 Kconfig 默认值、不再弹提示，
#   syncconfig 仍会写 include/config/auto.conf。
#
# 注意：旧补丁用 s.replace('case syncconfig:',...) 命中的是 getopt 处理处（conf_parse
#   之前），完全无效；本脚本改为基于行匹配、精确插入到 check_conf 循环前。
#
# 鸡生蛋：prepare 内部才解包内核；而 prepare 本身又跑 syncconfig。故先跑一遍 prepare
#   解包（syncconfig 报错容错），打补丁后再跑一遍 prepare 做 configure（extract stamp
#   已存在，不会重新解包覆盖补丁）。
#
# 不使用全局 set -e：errexit + pipefail 在 make 管道里会造成“静默退出且不留日志”。
# 改为显式检查每个关键步骤的 $?。

PATCHES="${GITHUB_WORKSPACE:?}/ma3063-patches"
OPENWRT="${GITHUB_WORKSPACE:?}/openwrt"
cd "$OPENWRT"

: > build.log
trap 'echo ">>> TRAP: build-ma3063.sh exiting code=$? at LINENO=$LINENO" >> build.log' EXIT

log() { echo "== $* ==" | tee -a build.log; }

detect_linux() {
  # 内核解包目录形如 build_dir/target-*/linux-ipq50xx/linux-5.15.150
  find build_dir -type d -name 'linux-5.15.150' 2>/dev/null | head -1
}

log "[1/8] copy MA3063 DTS into tree"
mkdir -p target/linux/ipq50xx/dts
cp "$PATCHES/files/target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts" \
   target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts

log "[2/8] register MA3063 device in image/Makefile"
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

log "[3/8] write .config and run defconfig"
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
make defconfig >> build.log 2>&1
echo "defconfig rc=$?" | tee -a build.log

log "[4/8] pre-fill known arch symbols into target config template (insurance)"
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

log "[5/8] prepare pass 1: extract kernel (syncconfig prompt-fail tolerated)"
LINUX="$(detect_linux)"
if [ -z "$LINUX" ]; then
  make target/linux/prepare V=s >> build.log 2>&1
  rc1=$?
  echo "prepare pass1 rc=$rc1 (non-zero expected if syncconfig prompted before conf.c patch)" | tee -a build.log
  LINUX="$(detect_linux)"
fi
if [ -z "$LINUX" ]; then
  echo "ERROR: kernel source not extracted (download/extract failed) -- see build.log" | tee -a build.log
  exit 1
fi
echo "linux source dir: $LINUX" | tee -a build.log

log "[6/8] SAFE conf.c patch (correct anchor) + force rebuild conf binary"
CF="$LINUX/scripts/kconfig/conf.c"
python3 - "$CF" <<'PYEOF' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
if 'MA3063_NOSYNC' in s:
    print("conf.c already patched, skip"); sys.exit(0)
lines = s.splitlines(keepends=True)
# Primary anchor: case syncconfig: immediately followed by the check_conf loop comment
for k, l in enumerate(lines):
    if l.strip() == 'case syncconfig:' and k + 1 < len(lines) \
       and 'Update until a loop caused no more changes' in lines[k + 1]:
        lines.insert(k + 1, '\t\tconf_set_all_new_symbols(def_default); /* MA3063_NOSYNC */\n')
        print("patched conf.c via check_conf-loop anchor (NEW symbols get default before check_conf)")
        break
else:
    # Fallback: insert right after conf_read(NULL); inside a 'case syncconfig:' block
    for k, l in enumerate(lines):
        if l.strip() == 'case syncconfig:' and k + 1 < len(lines) \
           and lines[k + 1].strip() == 'conf_read(NULL);':
            lines.insert(k + 2, '\t\tconf_set_all_new_symbols(def_default); /* MA3063_NOSYNC */\n')
            print("patched conf.c via conf_read fallback")
            break
    else:
        print("ERROR: no known syncconfig anchor found in %s" % p)
        sys.exit(2)
open(p, 'w').write(''.join(lines))
PYEOF
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "conf.c patch FAILED rc=$rc" | tee -a build.log
  exit "$rc"
fi
# Force rebuild of the kconfig 'conf' host binary so the patched conf.c takes effect.
rm -f "$LINUX/scripts/kconfig/conf" "$LINUX/scripts/kconfig/conf.o" 2>/dev/null
echo "removed stale conf + conf.o -> kernel Makefile recompiles from patched conf.c" | tee -a build.log

log "[7/8] prepare pass 2: configure kernel with patched conf.c (no prompt)"
make target/linux/prepare V=s >> build.log 2>&1
rc2=$?
echo "prepare pass2 rc=$rc2" | tee -a build.log
if [ "$rc2" -ne 0 ]; then
  echo "ERROR: prepare pass2 failed -- see build.log" | tee -a build.log
  exit 1
fi

log "[8/8] build"
make -j"$(nproc)" V=s >> build.log 2>&1
rc3=$?
echo "build rc=$rc3" | tee -a build.log
if [ "$rc3" -ne 0 ]; then
  echo "ERROR: build failed -- see build.log" | tee -a build.log
  exit 1
fi
echo "BUILD OK" | tee -a build.log
