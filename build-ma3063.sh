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

log "[1/9] copy MA3063 DTS into tree"
mkdir -p target/linux/ipq50xx/dts
cp "$PATCHES/files/target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts" \
   target/linux/ipq50xx/dts/ipq5018-ruijie-ma3063.dts

log "[2/9] register MA3063 device in image/Makefile"
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

log "[3/9] write .config and run defconfig"
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

log "[4/9] pre-fill known arch symbols into target config template (insurance)"
for f in $(find target/linux/ipq50xx -name 'config-5.15*' 2>/dev/null); do
  # MA3063: the OEM u-boot only passes "ubi.mtd=rootfs" and no mtdparts=, so the
  # DTS fixed-partitions table is the only source of a partition named "rootfs".
  # The ipq50xx target leaves CONFIG_MTD_OF_PARTS unset, which means the
  # ofpart parser never runs and the DTS partitions are silently ignored.
  # Defensive only: target/linux/generic/config-5.15 already sets
  # CONFIG_MTD_OF_PARTS=y (verified), so the fixed-partitions parser is present
  # and the DTS table under nandcs@0 is parsed. Keep this guard so a future
  # generic-config change cannot silently kill the rootfs partition again.
  if grep -q '^# CONFIG_MTD_OF_PARTS is not set' "$f"; then
    sed -i 's/^# CONFIG_MTD_OF_PARTS is not set/CONFIG_MTD_OF_PARTS=y/' "$f"
    echo "  MTD_OF_PARTS: flipped to =y in $f" | tee -a build.log
  elif grep -q '^CONFIG_MTD_OF_PARTS=y' "$f"; then
    echo "  MTD_OF_PARTS: already =y in $f" | tee -a build.log
  else
    echo "CONFIG_MTD_OF_PARTS=y" >> "$f"
    echo "  MTD_OF_PARTS: appended =y to $f" | tee -a build.log
  fi
  # MA3063: rootfs is mounted as /dev/ubiblock0_1 (build#21 serial log shows
  # "Waiting for root device /dev/ubiblock0_1"), so ubiblock must exist before
  # prepare_namespace(). Without CONFIG_MTD_UBI_BLOCK the UBI volume block
  # devices are never created and the root mount degrades to mtdblockN
  # (which then fails with "SQUASHFS error: unable to read id index table"
  # because mtdblockN exposes UBI headers, not raw squashfs).
  if grep -q '^CONFIG_MTD_UBI_BLOCK=y' "$f"; then
    echo "  MTD_UBI_BLOCK: already =y in $f" | tee -a build.log
  else
    echo "CONFIG_MTD_UBI_BLOCK=y" >> "$f"
    echo "  MTD_UBI_BLOCK: appended =y to $f" | tee -a build.log
  fi
  {
    grep -q "CONFIG_ARM64_EPAN" "$f"        || echo "CONFIG_ARM64_EPAN=y"
    grep -q "CONFIG_ARM64_PA_BITS_48" "$f"  || echo "CONFIG_ARM64_PA_BITS_48=y"
    grep -q "CONFIG_ARM64_VA_BITS_39" "$f"  || echo "CONFIG_ARM64_VA_BITS_39=y"
    grep -q "CONFIG_ARM64_4K_PAGES" "$f"    || echo "CONFIG_ARM64_4K_PAGES=y"
    grep -q "CONFIG_QCOM_CLK_APCC_MSM8996" "$f" || echo "# CONFIG_QCOM_CLK_APCC_MSM8996 is not set"
  } >> "$f"
  echo "patched $f" | tee -a build.log
done

log "[5/9] prepare pass 1: extract kernel (syncconfig prompt-fail tolerated)"
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

log "[6/9] SAFE conf.c patch (correct anchor) + force rebuild conf binary"
CF="$LINUX/scripts/kconfig/conf.c"
python3 - "$CF" <<'PYEOF' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063_NOSYNC' in s:
    print("conf.c already patched, skip"); sys.exit(0)
lines = s.splitlines(keepends=True)
# Correct anchor: check_conf()'s 'default:' branch (the one that falls through to
# conf(rootEntry) and prompts). When input_mode==syncconfig, we must NOT prompt;
# instead set all not-yet-valued NEW symbols to their Kconfig default and break.
# (conf_set_all_new_symbols in main() runs only once and misses symbols that
#  re-emerge as unvalued/changeable after a choice override, e.g. ETM4X_IMPDEF_FEATURE.)
done = False
for k, l in enumerate(lines):
    if l.strip() == 'default:' and k + 1 < len(lines) \
       and 'if (!conf_cnt++)' in lines[k + 1]:
        indent = l[:len(l) - len(l.lstrip())]      # indentation of 'default:'
        inner = indent + '\t'
        block = (indent + 'default:\n'
                 + inner + 'if (input_mode == syncconfig) {\n'
                 + inner + '\tconf_set_all_new_symbols(def_default); /* MA3063_NOSYNC */\n'
                 + inner + '\tbreak;\n'
                 + inner + '}\n')
        lines[k] = block
        print("patched conf.c via check_conf default branch (syncconfig sets default, no prompt)")
        done = True
        break
if not done:
    print("ERROR: no check_conf 'default:' anchor found in %s" % p)
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

log "[6b/9] inject GD5F2GM7REYIGR SPI-NAND into nand_ids.c"
NID="$LINUX/drivers/mtd/nand/raw/nand_ids.c"
if [ -f "$NID" ]; then
  python3 - "$NID" <<'PYEOF2' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'GD5F2GM7REYIGR' in s:
    print("nand_ids.c already has GD5F2GM7REYIGR, skip"); sys.exit(0)
# Anchor: insert before the first LEGACY_ID_NAND line (end of the .id table's
# modern entries), same placement style as upstream patch 407.
anchor = 'LEGACY_ID_NAND('
idx = s.find(anchor)
if idx < 0:
    print("ERROR: LEGACY_ID_NAND anchor not found in %s" % p); sys.exit(2)
entry = ('\t{"GD5F2GM7REYIGR SPI NAND 2G",\n'
         '\t\t{ .id = {0xc8, 0x82} },\n'
         '\t\tSZ_2K, SZ_256, SZ_128K, 0, 2, 128, NAND_ECC_INFO(8, SZ_512) },\n\n')
s = s[:idx] + entry + s[idx:]
open(p, 'w', encoding='utf-8', newline='').write(s)
print("injected GD5F2GM7REYIGR (0xc8 0x82) into nand_ids.c")
PYEOF2
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "nand_ids.c injection FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: nand_ids.c not found at $NID (kernel layout changed?) -- continuing" | tee -a build.log
fi

log "[6c/9] fix ipq5018_nandc_props: add missing .is_qpic = true"
QNC="$LINUX/drivers/mtd/nand/raw/qcom_nandc.c"
if [ -f "$QNC" ]; then
  python3 - "$QNC" <<'PYEOF3' 2>&1 | tee -a build.log
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
m = re.search(r'ipq5018_nandc_props = \{(.*?)\}', s, re.S)
if m and '.is_qpic' in m.group(1):
    print("ipq5018_nandc_props already has .is_qpic, skip"); sys.exit(0)
# Upstream patch 403 defines ipq5018_nandc_props without .is_qpic = true
# (ipq4019/ipq8074/sdx55 all have it). qcom_nandc_setup() then runs:
#   if (!nandc->props->is_qpic) nandc_write(nandc, SFLASHC_BURST_CFG, 0);
# zeroing the QPIC serial-flash burst config on IPQ5018, which breaks access to
# the SPI-NAND (the OEM u-boot still reads the same chip fine).
ins = '\t.is_qpic = true,\n'
# Preferred anchor: right after ".is_bam = true," inside ipq5018_nandc_props
# (matches patch 403's layout). Fallback: right after the opening brace, so we
# still work if upstream ever joins the fields onto one line.
for pat in (r'(ipq5018_nandc_props = \{[^}]*?\.is_bam = true,\n)',
            r'(ipq5018_nandc_props = \{\n)'):
    m = re.search(pat, s, re.S)
    if m:
        s = s[:m.end(1)] + ins + s[m.end(1):]
        open(p, 'w', encoding='utf-8', newline='').write(s)
        print("added .is_qpic = true to ipq5018_nandc_props")
        sys.exit(0)
print("WARN: ipq5018_nandc_props anchor not found -- continuing")
PYEOF3
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "qcom_nandc.c is_qpic fix FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: qcom_nandc.c not found at $QNC -- continuing" | tee -a build.log
fi

log "[6d/9] add temporary READID diagnostics to nand_base.c"
NBB="$LINUX/drivers/mtd/nand/raw/nand_base.c"
if [ -f "$NBB" ]; then
  python3 - "$NBB" <<'PYEOF4' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG' in s:
    print("nand_base.c already instrumented, skip"); sys.exit(0)
# nand_detect() prints nothing when the ID lookup fails in 5.15 (the old
# "device found, Manufacturer ID:" line only runs on the success path), so a
# failed detection is completely silent. Print the raw bytes we actually read
# from the chip so the next serial log is conclusive.
a1 = "\tchip->id.len = nand_id_len(id_data, ARRAY_SIZE(chip->id.data));\n"
if s.count(a1) != 1:
    print("WARN: nand_id_len anchor count=%d -- diagnostics skipped" % s.count(a1)); sys.exit(0)
# Print the bytes explicitly (no %phN hexdump -- avoids any printk format risk
# and reads better in a serial log).
s = s.replace(a1, a1 + (
    '\tpr_info("MA3063DBG readid maf=0x%02x dev=0x%02x idlen=%d b=%02x%02x%02x%02x\\n",\n'
    '\t\tmaf_id, dev_id, chip->id.len,\n'
    '\t\tid_data[0], id_data[1], id_data[2], id_data[3]);\n'), 1)
# NOTE: in v5.15 this line ends with " {" (brace on the same line, single
# occurrence). Keep the unbraced form as a fallback for other tree revisions.
ins2 = '\tpr_info("MA3063DBG match loop dev_id=0x%02x\\n", dev_id);\n'
done2 = False
for a2 in ("\tfor (; type->name != NULL; type++) {\n",
           "\tfor (; type->name != NULL; type++)\n"):
    if s.count(a2) == 1:
        s = s.replace(a2, ins2 + a2, 1)
        print("match-loop print inserted")
        done2 = True
        break
if not done2:
    print("note: match-loop anchor not found -- base print only")
open(p, 'w', encoding='utf-8', newline='').write(s)
print("nand_base.c READID diagnostics inserted")
PYEOF4
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "nand_base.c diagnostics FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: nand_base.c not found at $NBB -- continuing" | tee -a build.log
fi

log "[6e/9] MTD partition pipeline diagnostics + driver-provided partition fallback"
# Build#21 result: the SPI-NAND chip is now detected correctly, but the kernel
# never registers any MTD partition (no "N partitions found" / "Creating N MTD
# partitions" lines at all) so UBI fails with "cannot open mtd rootfs, error -2".
# Static analysis of the whole chain came back clean:
#   qcom_nandc.c  nand_set_flash_node(chip, dn) -> mtd->dev.of_node = nandcs@0
#   mtdcore.c     mtd_set_dev_defaults() does NOT touch mtd->dev.of_node
#   mtdpart.c     parse_mtd_partitions() -> mtd_part_of_parse() -> ofpart
#   ofpart_core.c parse_fixed_partitions() looks up nandcs@0/partitions
#   the built DTB really contains /soc/qpic-nand@79b0000/nandcs@0/partitions
#   drivers/mtd/Makefile links nand/ *before* ubi/, so ordering is fine
# The remaining possibilities are runtime only (of_node lost/ pointing at the
# controller node, parser silently returning 0, nand_scan() bailing out after
# ident). So: (1) trace every stage, (2) hand mtd_device_parse_register() the
# board partition table as its documented "driver-provided fallback"
# (mtdcore.c:969 "Prefer parsed partitions over driver-provided fallback" - the
# array is only used when the parsers yield nothing, so it cannot duplicate
# partitions when ofpart works).
QNC="$LINUX/drivers/mtd/nand/raw/qcom_nandc.c"
if [ -f "$QNC" ]; then
  python3 - "$QNC" <<'PYEOF5' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG_PARTS' in s:
    print("qcom_nandc.c already instrumented, skip"); sys.exit(0)

# struct mtd_partition is only forward-declared by mtd.h -> need the real header
inc = '#include <linux/mtd/partitions.h>'
a = '#include <linux/mtd/mtd.h>'
if inc not in s:
    if s.count(a) == 1:
        s = s.replace(a, a + '\n' + inc, 1)
        print("added " + inc)
    else:
        print("WARN: mtd.h include anchor count=%d" % s.count(a))

# Board partition table -- mirrors the DTS partitions node under nandcs@0.
# Designated initialisers only: struct mtd_partition is
# {name, types, size, offset, mask_flags, add_flags, of_node} in 5.15, so the
# historical positional order (offset, size) would be silently wrong.
parts = [
    ("0:SBL1",        0x0000000, 0x0080000, True),
    ("0:MIBIB",       0x0080000, 0x0080000, True),
    ("0:BOOTCONFIG",  0x0100000, 0x0040000, True),
    ("0:BOOTCONFIG1", 0x0140000, 0x0040000, True),
    ("0:QSEE",        0x0180000, 0x0100000, True),
    ("0:QSEE_1",      0x0280000, 0x0100000, True),
    ("0:DEVCFG",      0x0380000, 0x0040000, True),
    ("0:DEVCFG_1",    0x03c0000, 0x0040000, True),
    ("0:CDT",         0x0400000, 0x0040000, True),
    ("0:CDT_1",       0x0440000, 0x0040000, True),
    ("0:APPSBLENV",   0x0480000, 0x0080000, True),
    ("0:APPSBL",      0x0500000, 0x0140000, True),
    ("0:APPSBL_1",    0x0640000, 0x0140000, True),
    ("0:ART",         0x0780000, 0x0100000, True),
    ("0:TRAINING",    0x0880000, 0x0080000, True),
    ("rootfs",        0x0900000, 0x4340000, False),
    ("rootfs_1",      0x4c40000, 0x4340000, False),
    ("ttyMTD",        0x8f80000, 0x0120000, True),
    ("productinfo",   0x90a0000, 0x0080000, True),
    ("data",          0x9120000, 0x6d80000, False),
]
tbl = '/* MA3063DBG_PARTS: fallback table, mirrors DTS nandcs@0/partitions */\n'
tbl += 'static const struct mtd_partition ma3063_dbg_parts[] = {\n'
for (nm, off, sz, ro) in parts:
    tbl += '\t{ .name = "%s", .offset = 0x%x, .size = 0x%x%s },\n' % (
        nm, off, sz, ", .mask_flags = MTD_WRITEABLE" if ro else "")
tbl += '};\n\n'
anchor = 'static const char * const probes[] = { "cmdlinepart", "ofpart", "qcomsmem", NULL };\n'
if s.count(anchor) != 1:
    print("ERROR: probes[] anchor count=%d -- abort" % s.count(anchor)); sys.exit(2)
s = s.replace(anchor, tbl + anchor, 1)

# trace nand_scan(): ident succeeding but scan_tail failing would return early
# and skip mtd_device_parse_register() entirely -> no partitions, no parser log.
a = '\tret = nand_scan(chip, 1);\n'
if s.count(a) == 1:
    s = s.replace(a, a + '\tpr_info("MA3063DBG nand_scan ret=%d\\n", ret);\n', 1)
else:
    print("WARN: nand_scan anchor count=%d" % s.count(a))

# pass the fallback table + trace the of_node the parser will actually see
a = '\tret = mtd_device_parse_register(mtd, probes, NULL, NULL, 0);\n'
if s.count(a) != 1:
    print("ERROR: mtd_device_parse_register anchor count=%d -- abort" % s.count(a)); sys.exit(2)
new = ('\tpr_info("MA3063DBG pre-parse name=%s of_node=%s dn=%s\\n",\n'
       '\t\tmtd->name,\n'
       '\t\tmtd->dev.of_node ? mtd->dev.of_node->full_name : "(null)",\n'
       '\t\tdn ? dn->full_name : "(null)");\n'
       '\tret = mtd_device_parse_register(mtd, probes, NULL, ma3063_dbg_parts,\n'
       '\t\t\t\t\tARRAY_SIZE(ma3063_dbg_parts));\n'
       '\tpr_info("MA3063DBG post-parse ret=%d has_parts=%d\\n", ret,\n'
       '\t\t!list_empty(&mtd->partitions));\n')
s = s.replace(a, new, 1)

# trace the per-child probe loop (which child failed, if any)
a = '\t\tret = qcom_nand_host_init_and_register(nandc, host, child);\n'
if s.count(a) == 1:
    s = s.replace(a, a + '\t\tpr_info("MA3063DBG child=%s init_ret=%d\\n",\n'
                          '\t\t\tchild->full_name, ret);\n', 1)
else:
    print("WARN: child init anchor count=%d" % s.count(a))

open(p, 'w', encoding='utf-8', newline='').write(s)
print("qcom_nandc.c: diagnostics + fallback partition table installed")
PYEOF5
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "qcom_nandc.c partition instrumentation FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: qcom_nandc.c not found at $QNC -- continuing" | tee -a build.log
fi

log "[6f/9] MTD parser diagnostics (mtdpart.c + ofpart_core.c)"
MPT="$LINUX/drivers/mtd/mtdpart.c"
if [ -f "$MPT" ]; then
  python3 - "$MPT" <<'PYEOF6' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG of_parse' in s:
    print("mtdpart.c already instrumented, skip"); sys.exit(0)
a = '\tnp = mtd_get_of_node(master);\n\tif (mtd_is_partition(master))\n'
if s.count(a) == 1:
    s = s.replace(a, '\tnp = mtd_get_of_node(master);\n'
                     '\tpr_info("MA3063DBG of_parse master=%s mtd_of=%s\\n",\n'
                     '\t\tmaster->name, np ? np->full_name : "(null)");\n'
                     '\tif (mtd_is_partition(master))\n', 1)
    print("mtd_part_of_parse(): of_node print inserted")
else:
    print("WARN: mtd_part_of_parse anchor count=%d -- skipped" % s.count(a))
a = '\t\tnp = of_get_child_by_name(np, "partitions");\n'
if s.count(a) == 1:
    s = s.replace(a, a + '\tpr_info("MA3063DBG of_parse parts_node=%s\\n",\n'
                          '\t\tnp ? np->full_name : "(null)");\n', 1)
    print("mtd_part_of_parse(): partitions-node print inserted")
else:
    print("WARN: partitions node anchor count=%d -- skipped" % s.count(a))
open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF6
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "mtdpart.c instrumentation FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: mtdpart.c not found at $MPT -- continuing" | tee -a build.log
fi

OPC="$LINUX/drivers/mtd/parsers/ofpart_core.c"
if [ -f "$OPC" ]; then
  python3 - "$OPC" <<'PYEOF7' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG fixed_parse' in s:
    print("ofpart_core.c already instrumented, skip"); sys.exit(0)
# parse_fixed_partitions() only -- parse_ofoldpart_partitions() uses `dp`.
a = ('\t/* Pull of_node from the master device node */\n'
     '\tmtd_node = mtd_get_of_node(master);\n')
if s.count(a) == 1:
    s = s.replace(a, a + '\tpr_info("MA3063DBG fixed_parse master=%s mtd_node=%s\\n",\n'
                          '\t\tmaster->name,\n'
                          '\t\tmtd_node ? mtd_node->full_name : "(null)");\n', 1)
    print("parse_fixed_partitions(): entry print inserted")
else:
    print("WARN: ofpart_core anchor count=%d -- skipped" % s.count(a))
a = '\tif (nr_parts == 0)\n\t\treturn 0;\n'
if s.count(a) == 1:
    s = s.replace(a, '\tpr_info("MA3063DBG fixed_parse nr_parts=%d\\n", nr_parts);\n' + a, 1)
    print("parse_fixed_partitions(): nr_parts print inserted")
else:
    print("WARN: nr_parts anchor count=%d -- skipped" % s.count(a))
open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF7
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ofpart_core.c instrumentation FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: ofpart_core.c not found at $OPC -- continuing" | tee -a build.log
fi

log "[6g/9] UBI attach diagnostics + late-init deferral"
# If ubi_init() runs before the NAND driver has registered its partitions, the
# named attach ("ubi.mtd=rootfs") fails once with ENOENT and is never retried
# (built-in UBI just `continue`s). The dump tells us whether "rootfs" was
# missing because no partition existed at all, or because UBI ran too early.
# Moving ubi_init to late_initcall_sync() keeps it well before
# prepare_namespace() but after every device_initcall-level probe.
UBI="$LINUX/drivers/mtd/ubi/build.c"
if [ -f "$UBI" ]; then
  python3 - "$UBI" <<'PYEOF8' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG ubi_init' in s:
    print("ubi/build.c already instrumented, skip"); sys.exit(0)

helper = (
'/* MA3063DBG: dump every registered MTD device (temporary diagnostic) */\n'
'static void ma3063_dbg_dump_mtds(void)\n'
'{\n'
'\tint i;\n'
'\n'
'\tpr_err("MA3063DBG ubi_init entry mtd_devs=%d\\n", mtd_devs);\n'
'\n'
'\tfor (i = 0; i < 64; i++) {\n'
'\t\tstruct mtd_info *dbgm = get_mtd_device(NULL, i);\n'
'\n'
'\t\tif (IS_ERR(dbgm))\n'
'\t\t\tcontinue;\n'
'\t\tpr_err("MA3063DBG mtd%d name=%s size=%llu node=%s partition=%s\\n",\n'
'\t\t       dbgm->index, dbgm->name, (unsigned long long)dbgm->size,\n'
'\t\t       dbgm->dev.of_node ? dbgm->dev.of_node->full_name : "(null)",\n'
'\t\t       dbgm->parent ? "yes" : "no");\n'
'\t\tput_mtd_device(dbgm);\n'
'\t}\n'
'}\n'
'\n')

anchor_fn = 'static int __init ubi_init(void)\n{\n'
decl = '\tint err, i, k;\n'
fn_i = s.find(anchor_fn)
if fn_i < 0:
    print("WARN: ubi_init anchor not found -- helper skipped")
else:
    # The call must land AFTER the function's declarations: 5.15 is built with
    # -Werror=declaration-after-statement (ISO C90), so a statement placed right
    # after "{" fails the build ("ISO C90 forbids mixed declarations and code").
    s = s[:fn_i] + helper + s[fn_i:]
    fn_i += len(helper)
    decl_i = s.find(decl, fn_i)
    if decl_i < 0:
        print("WARN: ubi_init declaration anchor missing -- dump call skipped")
    else:
        ins_at = decl_i + len(decl)
        s = s[:ins_at] + '\n\tma3063_dbg_dump_mtds();\n' + s[ins_at:]
        print("ubi/build.c: dump helper + call inserted after declarations")

key = 'cannot open mtd %s'
i = s.find(key)
if i < 0:
    print("WARN: 'cannot open mtd %%s' anchor not found -- dump call skipped")
else:
    j = s.find('err);', i)
    k = s.find('\n', j) if j > 0 else -1
    if k < 0:
        print("WARN: dump call insert point not found")
    else:
        s = s[:k + 1] + '\t\t\tma3063_dbg_dump_mtds();\n' + s[k + 1:]
        print("ubi_init(): MTD dump call inserted after the attach failure")

a = 'module_init(ubi_init);'
# v5.15 already registers UBI from late_initcall(), i.e. after all
# device_initcall-level probes, and drivers/mtd/Makefile links nand/ before
# ubi/ -- so the named attach normally cannot race the NAND driver. Only force
# a later (sync) level if some tree still uses an earlier initcall.
if 'late_initcall(ubi_init);' in s or 'late_initcall_sync(ubi_init);' in s:
    print("ubi_init: already registered from late_initcall -- no change")
elif s.count(a) == 1:
    s = s.replace(a, 'late_initcall_sync(ubi_init);', 1)
    print("ubi_init: module_init -> late_initcall_sync")
else:
    print("WARN: no known ubi_init initcall anchor -- level unchanged")

open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF8
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ubi/build.c instrumentation FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: ubi/build.c not found at $UBI -- continuing" | tee -a build.log
fi

log "[6h/9] ofpart: tolerate an empty 'partitions' container"
# 根因（Build#23 运行日志已证实）：
#   RG-MA3063 的 OEM u-boot 在启动时把 DTB 里 nandcs@0/partitions 的 20 个子节点
#   全部搬到了 nandcs@0 之下（partition@N 直挂 flash 节点，且 label/reg 都还在），
#   但那个空的 'partitions' 容器被留了下来（仍带 compatible="fixed-partitions"）。
#   parse_fixed_partitions() 一旦发现容器存在就只遍历容器（dedicated=true），
#   于是数出 0 个分区并 return 0；更糟的是这同时堵死了内核本来就支持的
#   「直接子节点」legacy 路径（mtdpart.c 里 backward-compat 注释正是指它）。
#   结果：ofpart 失灵 -> 只能靠 qcom_nandc.c 里的驱动内建兜底表建分区。
# 修法：容器存在但为空时，回退到遍历 flash 节点的直接子节点（跳过带 compatible
#   的空容器本身）。该条件只在这种畸形树上成立，容器非空的正常设备零影响。
OPC2="$LINUX/drivers/mtd/parsers/ofpart_core.c"
if [ -f "$OPC2" ]; then
  python3 - "$OPC2" <<'PYEOF9' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
# newline='' keeps the patch byte-faithful on every host: with the default
# text mode, Python rewrites every '\n' as os.linesep ('\r\n' on Windows),
# which would silently convert the whole source file.
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'MA3063DBG empty' in s:
    print("ofpart_core.c: empty-container fallback already present, skip"); sys.exit(0)
a = ('\t\t\tofpart_node = mtd_node;\n'
     '\t\t\tdedicated = false;\n'
     '\t\t}\n'
     '\t} else { /* Partition */\n')
b = ('\t\t\tofpart_node = mtd_node;\n'
     '\t\t\tdedicated = false;\n'
     '\t\t} else if (of_get_child_count(ofpart_node) == 0) {\n'
     '\t\t\t/*\n'
     '\t\t\t * MA3063DBG empty: the \'partitions\' container exists but has no\n'
     '\t\t\t * children. The RG-MA3063 OEM u-boot promotes the partition nodes\n'
     '\t\t\t * to direct subnodes of the flash node while leaving the empty\n'
     '\t\t\t * (compatible="fixed-partitions") container behind. Honouring\n'
     '\t\t\t * that empty container hides the real partitions, so fall back\n'
     '\t\t\t * to the direct subnodes -- the legacy layout that the code\n'
     '\t\t\t * below already understands.\n'
     '\t\t\t */\n'
     '\t\t\tpr_info("%s: empty \'partitions\' subnode on %pOF, parsing direct subnodes\\n",\n'
     '\t\t\t\tmaster->name, mtd_node);\n'
     '\t\t\tofpart_node = mtd_node;\n'
     '\t\t\tdedicated = false;\n'
     '\t\t}\n'
     '\t} else { /* Partition */\n')
if s.count(a) == 1:
    s = s.replace(a, b, 1)
    print("parse_fixed_partitions(): empty-container fallback inserted")
else:
    print("WARN: ofpart fallback anchor count=%d -- skipped" % s.count(a))
open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF9
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ofpart_core.c fallback FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: ofpart_core.c not found at $OPC2 -- continuing" | tee -a build.log
fi

log "[6i/9] ath11k caldata extraction for ruijie,rg-ma3063"
# Build#23 启动日志：
#   ath11k c000000.wifi: qmi failed to load CAL data file:caldata.bin
#   ath11k c000000.wifi: failed to load board data file: -12
#   ath11k soc:wifi1@c000000: qmi failed to load CAL data file:caldata_1.bin
# 原因：hzyitc 的 11-ath11k-caldata 里两个 case 只列了
#   cmcc,rax3000q / redmi,ax3000 / xiaomi,cr881x，
#   没有 ruijie,rg-ma3063，所以 /lib/firmware/ath11k/*/caldata*.bin 永远不生成。
# 偏移取自本机 0:ART 实测（Build#23 串口 hexdump）：
#   0x1000  -> 01 00 04 04 ... 4c 7e 18 04   IPQ5018 2.4G 校准数据
#   0x26800 -> 01 00 04 04 ... f7 1d 18 04   QCN6122 5G  校准数据
#   两者与 AX3000 / RAX3000Q 同布局，故沿用同一组偏移。
CAL="target/linux/ipq50xx/base-files/etc/hotplug.d/firmware/11-ath11k-caldata"
if [ -f "$CAL" ]; then
  python3 - "$CAL" <<'PYEOF10' 2>&1 | tee -a build.log
import sys
p = sys.argv[1]
# newline='' -- see the note in [6h/9]: never let Python rewrite line endings.
s = open(p, encoding='utf-8', errors='replace', newline='').read()
if 'ruijie,rg-ma3063' in s:
    print("11-ath11k-caldata already patched, skip"); sys.exit(0)
cr = '\r' if '\r\n' in s else ''
n = 0
out = []
for ln in s.split('\n'):
    if ln.rstrip('\r').strip() == 'xiaomi,cr881x)':
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(indent + 'ruijie,rg-ma3063|\\' + cr)
        n += 1
    out.append(ln)
if n:
    s = '\n'.join(out)
    print("11-ath11k-caldata: ruijie,rg-ma3063 added to %d case block(s)" % n)
else:
    print("WARN: ath11k caldata anchor 'xiaomi,cr881x)' not found -- patch skipped")
open(p, 'w', encoding='utf-8', newline='').write(s)
PYEOF10
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "11-ath11k-caldata patch FAILED rc=$rc" | tee -a build.log
    exit "$rc"
  fi
else
  echo "WARN: 11-ath11k-caldata not found -- continuing" | tee -a build.log
fi

log "[7/9] prepare pass 2: configure kernel with patched conf.c (no prompt)"
make target/linux/prepare V=s >> build.log 2>&1
rc2=$?
echo "prepare pass2 rc=$rc2" | tee -a build.log
if [ "$rc2" -ne 0 ]; then
  echo "ERROR: prepare pass2 failed -- see build.log" | tee -a build.log
  exit 1
fi

log "[8/9] build (pass 1)"
make -j"$(nproc)" V=s >> build.log 2>&1
rc3=$?
echo "build pass1 rc=$rc3" | tee -a build.log
if [ "$rc3" -ne 0 ]; then
  echo "ERROR: build failed -- see build.log" | tee -a build.log
  exit 1
fi
echo "BUILD OK (pass 1)" | tee -a build.log

# Baseline for the Build#25 fix: the image produced by the unpatched ath11k.
IMG1="$(find bin/targets/ipq50xx -name '*nand-factory.ubi' 2>/dev/null | head -1)"
[ -n "$IMG1" ] || IMG1="$(find bin/targets/ipq50xx -name '*.ubi' 2>/dev/null | head -1)"
HASH1="$(sha256sum "$IMG1" 2>/dev/null | cut -d' ' -f1)"
echo "pass1 image: $IMG1 sha256=$HASH1" | tee -a build.log

log "[9/9] ath11k: disable coldboot calibration for IPQ5018/QCN6122 (package patch) + rebuild"
# ---------------------------------------------------------------------------
# Build#24 boot result (serial log):
#   [19.222283] Unable to handle kernel paging request at virtual address
#               ffffffc10a400000
#   [19.450108]  ath11k_ce_get_attr_flags+0xb8/0x290 [ath11k]
#   [19.455663]  ath11k_ce_init_pipes+0x48/0x190 [ath11k]
#   [19.460699]  ath11k_core_qmi_firmware_ready+0x38/0x56c [ath11k]
#   [19.466429]  ath11k_qmi_deinit_service+0x1454/0x1ae0 [ath11k]
#   Kernel panic - not syncing: Oops: Fatal exception  ->  Reboot loop
#
# 0xffffffc10a400000 is a linear-map alias.  With VA_BITS=39 the linear map
# starts at 0xffffffc000000000 + <KASLR shift>, so the address maps to physical
# 0x4A400000 == ATH11K_QMI_CALDB_ADDRESS.  That constant is referenced in
# ath11k in exactly one place: the coldboot-calibration branch of
# ath11k_qmi_assign_target_mem_chunk().  Our DTS reserves 0x4A400000 as
# tz_apps/no-map, i.e. it is deliberately absent from the linear map, so any
# host-side touch of it faults.
#
# Upstream (openwrt PR #19083, 2025-06) hit the same "firmware crashes during
# wifi startup" failure on IPQ5018 and fixed it by setting
# .coldboot_cal_mm/.coldboot_cal_ftm = false for IPQ5018 and QCN6122 (plus
# fw-memory-mode 2 -> 1 in the board DTS, which we already did in
# files/.../ipq5018-ruijie-ma3063.dts).  The hzyitc 23.05 tree predates that
# fix: patch 0019 (IPQ5018) and patch 301 (QCN6122) leave both fields true.
#
# Why the change is turned into a *package patch* instead of an in-place edit
# ---------------------------------------------------------------------------
# Build#25 (first attempt) edited the extracted core.c in place and then ran
# make.  That failed, and the gates caught it:
#
#     GATE 1 FAIL: MA3063DBG_COLDBOOT missing from ath11k/core.c
#     GATE 2b FAIL: ath11k.ko is byte-identical to pass 1
#
# The reason is in package/kernel/mac80211/Makefile:
#
#     PKG_BUILD_DIR := $(KERNEL_BUILD_DIR)/backports-$(PKG_VERSION)
#     define Build/Prepare
#         rm -rf $(PKG_BUILD_DIR)      <-- wipes the whole source tree
#         mkdir -p $(PKG_BUILD_DIR)
#         $(PKG_UNPACK)                <-- re-extracts the tarball
#         $(Build/Patch)               <-- re-applies patches/ath11k/*.patch
#         ...
#
# so an in-place edit cannot survive a re-prepare.  The fix therefore: run the
# injector once on the pass-1 source to *generate* a unified diff, install that
# diff as patches/ath11k/906-*.patch, then wipe $(PKG_BUILD_DIR) and let make
# re-extract + re-apply every patch, ours included.  From then on the change is
# part of the normal patch series and survives any number of re-prepares.
# ---------------------------------------------------------------------------
BP="$(find build_dir -maxdepth 3 -type d -name 'backports-*' 2>/dev/null | head -1)"
if [ -z "$BP" ]; then
  echo "ERROR: backports source dir not found under build_dir" | tee -a build.log
  exit 1
fi
echo "backports source dir: $BP" | tee -a build.log
CORE="$BP/drivers/net/wireless/ath/ath11k/core.c"
if [ ! -f "$CORE" ]; then
  echo "ERROR: $CORE not found" | tee -a build.log
  exit 1
fi
KO_TREE_BEFORE="$BP/drivers/net/wireless/ath/ath11k/ath11k.ko"
HASH_KO_BEFORE=""
if [ -f "$KO_TREE_BEFORE" ]; then
  HASH_KO_BEFORE="$(sha256sum "$KO_TREE_BEFORE" | cut -d' ' -f1)"
fi
echo "pass1 ath11k.ko (build tree): ${HASH_KO_BEFORE:-<none>}" | tee -a build.log

PRISTINE=/tmp/ma3063-core.c.pristine
cp -f "$CORE" "$PRISTINE"
echo "pristine copy: $PRISTINE ($(wc -c < "$PRISTINE") bytes)" | tee -a build.log

python3 "$PATCHES/ma3063-ath11k-coldboot.py" "$CORE" 2>&1 | tee -a build.log
rcfix=${PIPESTATUS[0]}
if [ "$rcfix" -ne 0 ]; then
  echo "ERROR: ath11k coldboot-calibration injector FAILED rc=$rcfix" | tee -a build.log
  exit "$rcfix"
fi

# GATE 0: the edit really landed in the freshly extracted source.
if grep -q MA3063DBG_COLDBOOT "$CORE"; then
  echo "GATE 0 OK: marker present in the extracted core.c" | tee -a build.log
else
  echo "GATE 0 FAIL: marker missing right after the injector ran" | tee -a build.log
  exit 1
fi

# --- turn the edit into a real package patch -------------------------------
PDIR="$OPENWRT/package/kernel/mac80211/patches/ath11k"
mkdir -p "$PDIR"
PATCHFILE="$PDIR/906-wifi-ath11k-disable-coldboot-calibration-ipq5018-qcn6122.patch"
{
  echo "From: MA3063 build script <wb@local>"
  echo "Date: $(date -R)"
  echo "Subject: [PATCH] wifi: ath11k: disable coldboot calibration for ipq5018/qcn6122"
  echo
  echo "Port of openwrt PR #19083 (patches 0907 + 920) onto the hzyitc 23.05"
  echo "backports tree, which predates that fix."
  echo
  echo "Coldboot calibration makes the firmware request a fixed CALDB chunk that"
  echo "the host has to back with the physical address 0x4A400000"
  echo "(ATH11K_QMI_CALDB_ADDRESS).  The board DTS reserves that range as"
  echo "tz_apps/no-map, so it is absent from the linear map and any host-side"
  echo "touch page-faults -- which is the Build#24 kernel panic."
  echo
  echo "Generated by ma3063-ath11k-coldboot.py from the pass-1 source."
  echo "---"
  diff -u --label a/drivers/net/wireless/ath/ath11k/core.c \
          --label b/drivers/net/wireless/ath/ath11k/core.c \
          "$PRISTINE" "$CORE" || true
} > "$PATCHFILE"
echo "package patch written: $PATCHFILE ($(wc -l < "$PATCHFILE") lines)" | tee -a build.log
sed -n '1,12p' "$PATCHFILE" | tee -a build.log

# --- pre-flight: the patch must apply cleanly and reproduce the edit --------
rm -rf /tmp/pfcheck
mkdir -p /tmp/pfcheck/drivers/net/wireless/ath/ath11k
cp -f "$PRISTINE" /tmp/pfcheck/drivers/net/wireless/ath/ath11k/core.c
if ! patch -p1 --silent -d /tmp/pfcheck -i "$PATCHFILE"; then
  echo "GATE P FAIL: generated patch does not apply to the pristine source" | tee -a build.log
  exit 1
fi
if ! cmp -s /tmp/pfcheck/drivers/net/wireless/ath/ath11k/core.c "$CORE"; then
  echo "GATE P FAIL: patch round-trip does not reproduce the injected file" | tee -a build.log
  exit 1
fi
echo "GATE P OK: patch applies to the pristine source and round-trips exactly" | tee -a build.log

# ---------------------------------------------------------------------------
# [9b] IPQ5018 CE-register remap fix -> package patch 907
#
# This is the actual fix for the Build#24/#25 boot panic.  Port of upstream
#   "wifi: ath11k: fix remapped ce accessing issue on 64bit OS"
#   (Ziyang Huang, 2024-05-01, mainline)
# which states: "On 64bit OS, when ab->mem_ce is lower than or 4G far away from
# ab->mem, u32 is not enough to store the offsets, which makes
# ath11k_ahb_read32() and ath11k_ahb_write32() access incorrect address and
# causes Data Abort Exception."
#
# Pre-fix code stores the pointer difference ab->mem_ce - ab->mem inside the
# u32 srng_config->reg_start[], and ath11k_ahb_write32() then does
#   iowrite32(value, ab->mem + offset);
# With ab->mem = 0xffffffc00b000000 and the CE space ioremapped 12 MB below it,
# (u32)(-0xC00000) == 0xFF400000 and the write lands at 0xffffffc10a400000 --
# exactly the fault address in the oops.
# ---------------------------------------------------------------------------
ATH11K_DIR="$BP/drivers/net/wireless/ath/ath11k"
if [ ! -d "$ATH11K_DIR" ]; then
  echo "ERROR: $ATH11K_DIR not found" | tee -a build.log
  exit 1
fi

PRIS_DIR=/tmp/ma3063-ce-pristine
rm -rf "$PRIS_DIR"
mkdir -p "$PRIS_DIR"
for f in hw.h hw.c hal.c ahb.c; do
  if [ ! -f "$ATH11K_DIR/$f" ]; then
    echo "ERROR: ath11k/$f missing -- CE remap fix cannot be applied" | tee -a build.log
    exit 1
  fi
  cp -f "$ATH11K_DIR/$f" "$PRIS_DIR/$f"
done

CEREPORT="$PATCHES/b26_ce.txt"
python3 "$PATCHES/ma3063-ath11k-ce-remap.py" "$ATH11K_DIR" "$CEREPORT" 2>&1 | tee -a build.log
rcce=${PIPESTATUS[0]}
if [ "$rcce" -ne 0 ]; then
  echo "ERROR: ath11k CE-remap injector FAILED rc=$rcce" | tee -a build.log
  exit "$rcce"
fi

# GATE C: all four required edits really landed
CE_FAIL=0
if ! grep -q 'ATH11K_REG_OFFSET_MASK' "$ATH11K_DIR/hw.h"; then
  echo "GATE C FAIL: hw.h lacks the ATH11K_REG_OFFSET_MASK macro" | tee -a build.log
  CE_FAIL=1
fi
NTAG=$(grep -c 'ATH11K_REG_TYPE_CE' "$ATH11K_DIR/hw.c")
if [ "$NTAG" -lt 4 ]; then
  echo "GATE C FAIL: hw.c carries only $NTAG ATH11K_REG_TYPE_CE tag(s), expected >= 4" | tee -a build.log
  CE_FAIL=1
fi
if grep -q 'ATH11K_CE_OFFSET' "$ATH11K_DIR"/*.c "$ATH11K_DIR"/*.h 2>/dev/null; then
  echo "GATE C FAIL: ATH11K_CE_OFFSET is still referenced:" | tee -a build.log
  grep -n 'ATH11K_CE_OFFSET' "$ATH11K_DIR"/*.c "$ATH11K_DIR"/*.h 2>/dev/null | head -20 | tee -a build.log
  CE_FAIL=1
fi
if ! grep -q 'case ATH11K_REG_TYPE_CE:' "$ATH11K_DIR/ahb.c"; then
  echo "GATE C FAIL: ahb.c accessors were not rewritten" | tee -a build.log
  CE_FAIL=1
fi
if [ "$CE_FAIL" -eq 0 ]; then
  echo "GATE C OK: CE remap fix applied (hw.h macros, $NTAG hw.c tags, no ATH11K_CE_OFFSET left, ahb.c dispatch)" | tee -a build.log
else
  exit 1
fi

CEDIFF=/tmp/ma3063-ce.diff
: > "$CEDIFF"
for f in hw.h hw.c hal.c ahb.c; do
  diff -u --label "a/drivers/net/wireless/ath/ath11k/$f" \
          --label "b/drivers/net/wireless/ath/ath11k/$f" \
          "$PRIS_DIR/$f" "$ATH11K_DIR/$f" >> "$CEDIFF" || true
done
PATCHFILE2="$PDIR/907-wifi-ath11k-fix-remapped-ce-accessing.patch"
{
  echo "From: MA3063 build script <wb@local>"
  echo "Date: $(date -R)"
  echo "Subject: [PATCH] wifi: ath11k: fix remapped ce accessing issue on 64bit OS"
  echo
  echo "Upstream port (Ziyang Huang, 2024-05).  ab->mem_ce - ab->mem does not fit"
  echo "in a u32, so ath11k_ahb_read32()/write32() can compute an address ~4 GiB"
  echo "away from ab->mem and Data Abort.  Tag register values with the space they"
  echo "live in (high nibble) and dispatch to ab->mem / ab->mem_ce accordingly."
  echo "Register values themselves are unchanged."
  echo
  echo "Generated by ma3063-ath11k-ce-remap.py from the pass-1 source."
  echo "---"
  cat "$CEDIFF"
} > "$PATCHFILE2"
echo "package patch written: $PATCHFILE2 ($(wc -l < "$PATCHFILE2") lines)" | tee -a build.log

# GATE P2: the concatenated 4-file patch must apply to pristine copies exactly
rm -rf /tmp/pfcheck2
mkdir -p /tmp/pfcheck2/drivers/net/wireless/ath/ath11k
for f in hw.h hw.c hal.c ahb.c; do
  cp -f "$PRIS_DIR/$f" "/tmp/pfcheck2/drivers/net/wireless/ath/ath11k/$f"
done
if ! patch -p1 --silent -d /tmp/pfcheck2 -i "$PATCHFILE2"; then
  echo "GATE P2 FAIL: 907 patch does not apply to the pristine copies" | tee -a build.log
  exit 1
fi
for f in hw.h hw.c hal.c ahb.c; do
  if ! cmp -s "/tmp/pfcheck2/drivers/net/wireless/ath/ath11k/$f" "$ATH11K_DIR/$f"; then
    echo "GATE P2 FAIL: 907 round-trip mismatch for $f" | tee -a build.log
    exit 1
  fi
done
echo "GATE P2 OK: 907 applies cleanly and round-trips for all four files" | tee -a build.log


# Force a full re-prepare: Build/Prepare does `rm -rf $(PKG_BUILD_DIR)` and then
# re-extracts + re-applies patches/*.patch, so wiping it is what makes our new
# 906 patch take effect (and it also invalidates every stamp inside it).
rm -rf "$BP"
echo "wiped $BP -> Build/Prepare will re-unpack and re-apply all ath11k patches" | tee -a build.log

make -j"$(nproc)" V=s >> build.log 2>&1
rc4=$?
echo "build pass2 rc=$rc4" | tee -a build.log

MARKER="MA3063DBG_COLDBOOT"
GATE_FAIL=0

if grep -q "$MARKER" "$CORE"; then
  echo "GATE 1 OK: $MARKER present in ath11k/core.c (patch survived the rebuild)" | tee -a build.log
else
  echo "GATE 1 FAIL: $MARKER missing from ath11k/core.c" | tee -a build.log
  GATE_FAIL=1
fi

KO="$BP/drivers/net/wireless/ath/ath11k/ath11k.ko"
if [ -f "$KO" ] && grep -q "$MARKER" "$KO"; then
  echo "GATE 2 OK: $MARKER present in the freshly built $(basename "$KO")" | tee -a build.log
elif [ -f "$BP/drivers/net/wireless/ath/ath11k/core.o" ] && \
     grep -q "$MARKER" "$BP/drivers/net/wireless/ath/ath11k/core.o"; then
  echo "GATE 2 OK: $MARKER present in core.o (no ath11k.ko -- built-in config?)" | tee -a build.log
else
  echo "GATE 2 FAIL: built ath11k objects do not carry $MARKER -- not recompiled" | tee -a build.log
  GATE_FAIL=1
fi

HASH_KO_AFTER=""
if [ -f "$KO" ]; then
  HASH_KO_AFTER="$(sha256sum "$KO" | cut -d' ' -f1)"
fi
echo "pass2 ath11k.ko (build tree): ${HASH_KO_AFTER:-<none>}" | tee -a build.log
if [ -n "$HASH_KO_BEFORE" ] && [ "$HASH_KO_BEFORE" = "$HASH_KO_AFTER" ]; then
  echo "GATE 2b FAIL: ath11k.ko is byte-identical to pass 1 ($HASH_KO_BEFORE)" | tee -a build.log
  GATE_FAIL=1
else
  echo "GATE 2b OK: ath11k.ko changed by the fix" | tee -a build.log
fi

IMG2="$(find bin/targets/ipq50xx -name '*nand-factory.ubi' 2>/dev/null | head -1)"
[ -n "$IMG2" ] || IMG2="$(find bin/targets/ipq50xx -name '*.ubi' 2>/dev/null | head -1)"
HASH2="$(sha256sum "$IMG2" 2>/dev/null | cut -d' ' -f1)"
echo "pass2 image: $IMG2 sha256=$HASH2" | tee -a build.log
if [ -n "$HASH2" ] && [ "$HASH2" != "$HASH1" ]; then
  echo "GATE 3 OK: firmware image rebuilt with the fixed ath11k ($HASH1 -> $HASH2)" | tee -a build.log
else
  echo "GATE 3 FAIL: firmware image unchanged ($HASH1) -- fixed module did not reach the image" | tee -a build.log
  GATE_FAIL=1
fi

if [ "$rc4" -ne 0 ] || [ "$GATE_FAIL" -ne 0 ]; then
  echo "ERROR: Build#25 ath11k fix is not verified -- refusing to publish this firmware" | tee -a build.log
  exit 1
fi

echo "BUILD OK" | tee -a build.log
