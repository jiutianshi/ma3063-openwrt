#!/usr/bin/env python3
"""MA3063 Build#25 -- disable ath11k coldboot calibration for IPQ5018 / QCN6122.

Why
---
Build#24 booted into a kernel panic while ath11k was starting up:

    Unable to handle kernel paging request at virtual address ffffffc10a400000
    Workqueue: ath11k_qmi_driver_event ath11k_qmi_deinit_service [ath11k]
     ath11k_ce_get_attr_flags
     ath11k_ce_init_pipes
     ath11k_core_qmi_firmware_ready

0xffffffc10a400000 is a linear-map alias: for VA_BITS=39 the linear map base is
0xffffffc000000000 + <KASLR shift>, and the address corresponds to physical
0x4A400000.  0x4A400000 is exactly ATH11K_QMI_CALDB_ADDRESS, referenced in
ath11k in exactly one place -- the coldboot-calibration branch of
ath11k_qmi_assign_target_mem_chunk():

    if (ath11k_cold_boot_cal && ab->hw_params.cold_boot_calib) {
            if (hremote_node) { ... res.start + host_ddr_sz ... }
            else             { ... ATH11K_QMI_CALDB_ADDRESS ... }
    } else {
            paddr = 0; vaddr = NULL;      /* normal dma_alloc_coherent() path */
    }

Our DTS reserves 0x4A400000 as tz_apps (no-map), so it is deliberately absent
from the linear map -> touching it page-faults.

Upstream hit the same failure and fixed it exactly this way (openwrt PR #19083,
June 2025):

    "Coldboot calibration does not work causes the firmware to crash during
     wifi startup. So let's disable coldboot calibration until a solution is
     found."

The hzyitc 23.05 tree we build from predates that fix: patch 0019 (IPQ5018 hw
params, later split by 0091) and patch 301 (QCN6122 hw params) both leave
.coldboot_cal_* = true.

What this script does
---------------------
1. Walk the ath11k_hw_params[] array in ath11k/core.c and pick the IPQ5018 and
   QCN6122 entries.
2. Flip their coldboot fields to false:
       .coldboot_cal_mm  = true,  ->  .coldboot_cal_mm  = false, /* MARK */
       .coldboot_cal_ftm = true,  ->  .coldboot_cal_ftm = false, /* MARK */
   (the pre-0091 single field .cold_boot_calib is handled too, so the script
   keeps working if the tree layout ever changes).
3. Add a pr_info() carrying the same marker inside
   ath11k_core_qmi_firmware_ready().  That makes the fix (a) provable by
   grepping the freshly built ath11k.ko and (b) visible on the serial console at
   every wifi bring-up.
4. Nothing is written unless a target entry was really changed -- the script
   exits non-zero instead of silently doing nothing.

Usage
-----
    python3 ma3063-ath11k-coldboot.py <.../ath11k/core.c>

Exit codes
----------
    0   core.c patched, or already carried the patch
    1   no IPQ5018/QCN6122 entry matched -> nothing changed (hard failure)
    2   hard error (ath11k_hw_params[] anchor not found)
"""

import re
import sys

MARK = "MA3063DBG_COLDBOOT"          # bare marker (printk + comments)
STRUCT_MARK = "/* %s */" % MARK      # trailing comment on the flipped fields
PRINT_MARK = 'pr_info("%s ' % MARK   # the runtime sensor line

ARRAY_RE = re.compile(r'ath11k_hw_params\[\]\s*=\s*\{')
ENTRY_OPEN = '\t{'
ENTRY_CLOSE = '\t},'

TARGETS = (
    ("IPQ5018", (r'\.hw_rev\s*=\s*ATH11K_HW_IPQ5018', r'\.name\s*=\s*"ipq5018')),
    ("QCN6122", (r'\.hw_rev\s*=\s*ATH11K_HW_QCN6122', r'\.name\s*=\s*"qcn6122')),
)

# field names, in the order they are printed by the runtime sensor
COLD_FIELDS = ("coldboot_cal_mm", "coldboot_cal_ftm", "cold_boot_calib")

SIG = "int ath11k_core_qmi_firmware_ready(struct ath11k_base *ab)"


def log(msg):
    print(msg, flush=True)


def find_array(lines):
    """Return (array_line_index, close_line_index) for ath11k_hw_params[]."""
    start = None
    for i, ln in enumerate(lines):
        if ARRAY_RE.search(ln):
            start = i
            break
    if start is None:
        return None
    depth = lines[start].count('{') - lines[start].count('}')
    for j in range(start + 1, len(lines)):
        depth += lines[j].count('{') - lines[j].count('}')
        if depth <= 0:
            return (start, j)
    return None


def iter_entries(lines, span):
    """Yield (start, end) inclusive line index pairs of each hw_params entry."""
    depth = lines[span[0]].count('{') - lines[span[0]].count('}')
    start = None
    out = []
    for j in range(span[0] + 1, span[1] + 1):
        ln = lines[j]
        if start is None and depth == 1 and ln == ENTRY_OPEN:
            start = j
        depth += ln.count('{') - ln.count('}')
        if start is not None and depth == 1 and ln == ENTRY_CLOSE:
            out.append((start, j))
            start = None
    return out


def field_of(block, field):
    m = re.search(r'\.%s\s*=\s*(\w+)' % field, block)
    return m.group(1) if m else None


def summarize(block):
    rev = re.search(r'\.hw_rev\s*=\s*([A-Za-z0-9_]+)', block)
    name = re.search(r'\.name\s*=\s*"([^"]*)"', block)
    cold = {f: (field_of(block, f) or "-") for f in COLD_FIELDS}
    return (rev.group(1) if rev else "?"), (name.group(1) if name else "?"), cold


def add_runtime_print(lines, fields):
    """Insert the marker pr_info() as the first statement of the function."""
    s = '\n'.join(lines)
    if PRINT_MARK in s:
        return lines, "runtime printk: already present"
    fn_i = s.find(SIG)
    if fn_i < 0:
        return lines, "runtime printk: WARN anchor %s not found" % SIG
    brace = s.find('{', fn_i)
    # the kernel is built with -Werror=declaration-after-statement, so the
    # statement must go after every declaration of the opening block: insert
    # right after the blank line that terminates the declaration block.
    gap = s.find('\n\n', brace)
    if brace < 0 or gap < 0:
        return lines, "runtime printk: WARN declaration block not found"
    if 'coldboot_cal_mm' in fields:
        fmt = ('\tpr_info("%s cbcal_mm=%%d cbcal_ftm=%%d fw_mem_mode=%%d '
               'cal_done=%%d\\n",\n'
               '\t\tab->hw_params.coldboot_cal_mm,\n'
               '\t\tab->hw_params.coldboot_cal_ftm,\n'
               '\t\tab->hw_params.fw_mem_mode, ab->qmi.cal_done);\n'
               ) % MARK
    else:
        fmt = ('\tpr_info("%s cold_boot_calib=%%d fw_mem_mode=%%d cal_done=%%d\\n",\n'
               '\t\tab->hw_params.cold_boot_calib,\n'
               '\t\tab->hw_params.fw_mem_mode, ab->qmi.cal_done);\n') % MARK
    s = s[:gap + 2] + fmt + s[gap + 2:]
    return s.split('\n'), "runtime printk: inserted into ath11k_core_qmi_firmware_ready()"


def main(argv):
    if len(argv) != 2:
        log("usage: %s <ath11k/core.c>" % argv[0])
        return 2
    path = argv[1]
    # newline='' -- never let Python rewrite the line endings of a kernel source
    with open(path, encoding='utf-8', errors='replace', newline='') as f:
        s = f.read()

    log("== ath11k coldboot-calibration fix: %s ==" % path)

    if PRINT_MARK in s:
        log("core.c already carries the Build#25 fix -- nothing to do")
        return 0

    lines = s.split('\n')
    span = find_array(lines)
    if span is None:
        log("ERROR: ath11k_hw_params[] not found in %s" % path)
        return 2

    entries = iter_entries(lines, span)
    log("ath11k_hw_params[]: %d entries (lines %d..%d)"
        % (len(entries), span[0] + 1, span[1] + 1))
    for (a, b) in entries:
        rev, name, cold = summarize('\n'.join(lines[a:b + 1]))
        log("  - %-24s %-16s mm=%-5s ftm=%-5s cbcal=%s"
            % (rev, name, cold["coldboot_cal_mm"], cold["coldboot_cal_ftm"],
               cold["cold_boot_calib"]))

    report = []
    changed_total = 0
    hit_labels = set()
    seen_fields = set()
    for label, idents in TARGETS:
        matched = False
        for (a, b) in entries:
            block = '\n'.join(lines[a:b + 1])
            if not any(re.search(p, block) for p in idents):
                continue
            matched = True
            for field in COLD_FIELDS:
                if field_of(block, field) is None:
                    continue
                seen_fields.add(field)
                pat = re.compile(r'(\.%s\s*=\s*)true(,)' % field)
                sub = pat.subn(
                    lambda m: '%sfalse%s %s' % (m.group(1), m.group(2), STRUCT_MARK),
                    block)
                if sub[1]:
                    block = sub[0]
                    changed_total += sub[1]
                    report.append("  %s: .%s true -> false" % (label, field))
            newlines = block.split('\n')
            assert len(newlines) == b - a + 1, "in-place edit must not change line count"
            lines[a:b + 1] = newlines
            hit_labels.add(label)
        if not matched:
            report.append("  %s: WARN no hw_params entry matched (patterns %s)"
                          % (label, idents))

    if changed_total == 0 and STRUCT_MARK not in '\n'.join(lines):
        log("ERROR: no coldboot_cal_*/.cold_boot_calib field was found in the "
            "IPQ5018/QCN6122 entries -- refusing to write a no-op patch")
        for line in report:
            log(line)
        return 1

    lines, note = add_runtime_print(lines, seen_fields or set(COLD_FIELDS))
    report.append("  " + note)

    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(lines))

    log("patched %d coldboot field(s) in %s"
        % (changed_total, ", ".join(sorted(hit_labels)) or "nothing"))
    for line in report:
        log(line)
    log("OK: %s written" % MARK)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
