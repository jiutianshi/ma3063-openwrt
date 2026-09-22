#!/usr/bin/env python3
"""Port of the upstream fix for the IPQ5018 ath11k CE-register panic.

Upstream commit: "wifi: ath11k: fix remapped ce accessing issue on 64bit OS"
(Ziyang Huang <hzyitc@...>, 2024-05-01, mainline):

    On 64bit OS, when ab->mem_ce is lower than or 4G far away from ab->mem,
    u32 is not enough to store the offsets, which makes ath11k_ahb_read32()
    and ath11k_ahb_write32() access incorrect address and causes Data Abort
    Exception.

Pre-fix code (what this tree ships) does:

    #define ATH11K_CE_OFFSET(ab) (ab->mem_ce - ab->mem)          /* pointer diff! */
    ... hal.c: reg_start[0] = CE0_SRC_REG + HAL_CE_DST_RING_BASE_LSB
                              + ATH11K_CE_OFFSET(ab);              /* stored in u32 */
    ... ahb.c: iowrite32(value, ab->mem + offset);

For the MA3063 boot ab->mem = 0xffffffc00b000000 and the separately ioremapped
CE space sits 12 MB *below* it, so the difference is negative:

    (u32)(-0xC00000) == 0xFF400000
    ab->mem + 0xFF400000 == 0xffffffc10a400000   <-- the Build#24/#25 panic address

Fix: tag register values with the space they live in (high nibble) and let the
AHB accessors dispatch to ab->mem / ab->mem_ce.  Register *values* are unchanged;
only the addressing scheme changes, so no functionality is dropped.

Usage: ma3063-ath11k-ce-remap.py <ath11k source dir> [report file]
Exit code 0 = all required changes applied, 1 = something required failed.
"""
import os
import re
import sys

ATH = sys.argv[1] if len(sys.argv) > 1 else "."
REPORT = sys.argv[2] if len(sys.argv) > 2 else None

LOG = []
CHANGED = []
FAILED = []


def log(s=""):
    LOG.append(str(s))
    print(s, flush=True)


def read(p):
    with open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def strip_ce_offset(text):
    """Remove every `... + ATH11K_CE_OFFSET(ab)` term.

    The tree writes it two ways -- inline (`... + ATH11K_CE_OFFSET(ab);`) and as
    a line continuation (`... BASE_LSB +\\n\\t\\tATH11K_CE_OFFSET(ab);`) -- so the
    pattern must allow whitespace *including newlines* between `+` and the macro.
    A left-behind occurrence is a hard compile error once the macro is gone.
    """
    n = len(re.findall(r"\+\s*ATH11K_CE_OFFSET\(ab\)", text))
    text = re.sub(r"\+\s*ATH11K_CE_OFFSET\(ab\)", "", text)
    # tidy what a removed continuation leaves behind: a dangling newline+';'
    # (continuation form) or a stray space before ';' (inline form)
    text = re.sub(r"[ \t]*\n[ \t]*;", ";", text)
    text = re.sub(r"[ \t]+;", ";", text)
    return text, n


# NOTE: upstream's patch is written against a 6.x kernel and uses
#   #define ATH11K_REG_TYPE(x) FIELD_PREP_CONST(ATH11K_REG_TYPE_MASK, x)
# FIELD_PREP_CONST() only appeared in v6.6.  This tree is backports-6.1.24 on
# top of a 5.15.150 kernel, so that macro does not exist (build error:
# "implicit declaration of function 'FIELD_PREP_CONST'").  FIELD_PREP() cannot
# be used either: it expands to a GCC statement expression, which is not a
# constant expression and therefore illegal in the `static const struct
# ath11k_hw_regs` initialisers ("initializer element is not constant").
# A plain shift is the equivalent constant expression:
#   FIELD_PREP_CONST(GENMASK(31, 28), x) == ((x << 28) & GENMASK(31, 28))
REG_MACROS = """\
#define ATH11K_REG_TYPE_MASK GENMASK(31, 28)
#define ATH11K_REG_TYPE(x) (((x) << 28) & ATH11K_REG_TYPE_MASK)
#define ATH11K_REG_TYPE_NORMAL ATH11K_REG_TYPE(0)
#define ATH11K_REG_TYPE_DP ATH11K_REG_TYPE(1)
#define ATH11K_REG_TYPE_CE ATH11K_REG_TYPE(2)
#define ATH11K_REG_OFFSET_MASK GENMASK(27, 0)"""

READ_BODY = """
\tswitch (offset & ATH11K_REG_TYPE_MASK) {
\tcase ATH11K_REG_TYPE_NORMAL:
\t\treturn ioread32(ab->mem + (offset & ATH11K_REG_OFFSET_MASK));
\tcase ATH11K_REG_TYPE_CE:
\t\treturn ioread32(ab->mem_ce + (offset & ATH11K_REG_OFFSET_MASK));
\tdefault:
\t\tBUG();
\t\treturn 0;
\t}
}
"""

WRITE_BODY = """
\tswitch (offset & ATH11K_REG_TYPE_MASK) {
\tcase ATH11K_REG_TYPE_NORMAL:
\t\tiowrite32(value, ab->mem + (offset & ATH11K_REG_OFFSET_MASK));
\t\tbreak;
\tcase ATH11K_REG_TYPE_CE:
\t\tiowrite32(value, ab->mem_ce + (offset & ATH11K_REG_OFFSET_MASK));
\t\tbreak;
\tdefault:
\t\tBUG();
\t\tbreak;
\t}
}
"""


def replace_fn_body(text, sig_substr, new_body, tag):
    """Replace the body of the function containing sig_substr.

    new_body must already end with the closing brace + newline; the slice below
    therefore drops the original "\\n}" so we do not emit a second brace.
    """
    i = text.find(sig_substr)
    if i < 0:
        return text, False, "%s: signature not found (%s)" % (tag, sig_substr[:48])
    j = text.find("{", i)
    if j < 0:
        return text, False, "%s: no opening brace" % tag
    k = text.find("\n}\n", j)
    if k < 0:
        return text, False, "%s: no closing brace" % tag
    return text[:j + 1] + new_body + text[k + 2:], True, ""


def table_span(text, name, kind="struct"):
    """Return (start, end) of `const <kind> ... name = { ... };`"""
    m = re.search(r"const\s+%s\s+[A-Za-z0-9_]+\s+%s\s*=\s*\{" % (kind, re.escape(name)), text)
    if not m:
        return None
    start = m.end()
    end = text.find("\n};", start)
    if end < 0:
        return None
    return (start, end)


log("=== MA3063 ath11k IPQ5018 CE-register remap fix ===")
log("ath11k source dir: %s" % os.path.abspath(ATH))

if not os.path.isdir(ATH):
    log("FATAL: %s is not a directory" % ATH)
    FAILED.append("ath11k source dir missing")

# ---------------------------------------------------------------------------
# 1. hw.h -- replace ATH11K_CE_OFFSET with the register-space tag macros
# ---------------------------------------------------------------------------
p = os.path.join(ATH, "hw.h")
if os.path.exists(p):
    s = read(p)
    if "ATH11K_REG_OFFSET_MASK" in s:
        log("SKIP hw.h: tag macros already present")
    else:
        lines = s.split("\n")
        out, hit = [], 0
        for ln in lines:
            if re.match(r"\s*#define\s+ATH11K_CE_OFFSET\b", ln):
                out.append(REG_MACROS)
                hit += 1
            else:
                out.append(ln)
        if hit:
            write(p, "\n".join(out))
            CHANGED.append("hw.h: ATH11K_CE_OFFSET -> ATH11K_REG_TYPE_* macros")
            log("OK   hw.h: replaced ATH11K_CE_OFFSET define with the tag macros")
        else:
            # fallback: drop the macros in front of the rate enum (upstream anchor)
            anchor = "enum ath11k_hw_rate_cck {"
            if anchor in s:
                s = s.replace(anchor, REG_MACROS + "\n\n" + anchor, 1)
                write(p, s)
                CHANGED.append("hw.h: tag macros inserted before enum ath11k_hw_rate_cck")
                log("OK   hw.h: ATH11K_CE_OFFSET define absent; macros inserted at enum anchor")
            else:
                FAILED.append("hw.h: neither ATH11K_CE_OFFSET nor the rate-enum anchor found")
                log("FAIL hw.h: no usable anchor")
else:
    FAILED.append("hw.h missing")

# ---------------------------------------------------------------------------
# 2. ahb.c -- dispatch on the tag, and drop ATH11K_CE_OFFSET everywhere
# ---------------------------------------------------------------------------
p = os.path.join(ATH, "ahb.c")
if os.path.exists(p):
    s = read(p)
    if "ATH11K_REG_TYPE_MASK" in s:
        log("SKIP ahb.c: accessors already tagged")
    else:
        s, ok, err = replace_fn_body(
            s, "ath11k_ahb_read32(struct ath11k_base *ab, u32 offset)", READ_BODY,
            "ahb.c read32")
        if ok:
            CHANGED.append("ahb.c: ath11k_ahb_read32 dispatches on the register-space tag")
            log("OK   ahb.c: read32 rewritten")
        else:
            FAILED.append(err)
            log("FAIL " + err)

        s, ok, err = replace_fn_body(
            s, "ath11k_ahb_write32(struct ath11k_base *ab, u32 offset, u32 value)",
            WRITE_BODY, "ahb.c write32")
        if ok:
            CHANGED.append("ahb.c: ath11k_ahb_write32 dispatches on the register-space tag")
            log("OK   ahb.c: write32 rewritten")
        else:
            FAILED.append(err)
            log("FAIL " + err)

    s, n = strip_ce_offset(s)
    if n:
        CHANGED.append("ahb.c: removed %d x ATH11K_CE_OFFSET(ab)" % n)
        log("OK   ahb.c: removed %d x ATH11K_CE_OFFSET(ab)" % n)
    write(p, s)
else:
    FAILED.append("ahb.c missing")

# ---------------------------------------------------------------------------
# 3. every other ath11k .c/.h: drop leftover ATH11K_CE_OFFSET uses
#    (the macro no longer exists -> any survivor would be a compile error)
# ---------------------------------------------------------------------------
total = 0
for name in sorted(os.listdir(ATH)):
    if not (name.endswith(".c") or name.endswith(".h")):
        continue
    if name in ("ahb.c",):
        continue
    q = os.path.join(ATH, name)
    s = read(q)
    if "ATH11K_CE_OFFSET" not in s:
        continue
    if name == "hw.h":
        continue
    s2, n = strip_ce_offset(s)
    if n:
        write(q, s2)
        total += n
        CHANGED.append("%s: removed %d x ATH11K_CE_OFFSET(ab)" % (name, n))
        log("OK   %s: removed %d x ATH11K_CE_OFFSET(ab)" % (name, n))
if total:
    log("     (total ATH11K_CE_OFFSET uses removed outside ahb.c: %d)" % total)

# ---------------------------------------------------------------------------
# 4. hw.c -- tag the IPQ5018 CE register values (values themselves unchanged)
# ---------------------------------------------------------------------------
p = os.path.join(ATH, "hw.c")
if os.path.exists(p):
    s = read(p)

    span = table_span(s, "ipq5018_regs")
    if span is None:
        FAILED.append("hw.c: ipq5018_regs table not found")
        log("FAIL hw.c: ipq5018_regs table not found")
    else:
        a, b = span
        chunk = s[a:b]
        new, n = re.subn(
            r"(\.hal_seq_wcss_umac_ce[01]_(?:src|dst)_reg\s*=\s*)"
            r"(?!ATH11K_REG_TYPE_CE)",
            r"\1ATH11K_REG_TYPE_CE + ", chunk)
        if n:
            s = s[:a] + new + s[b:]
            CHANGED.append("hw.c: ipq5018_regs -- tagged %d CE register values" % n)
            log("OK   hw.c: ipq5018_regs -- tagged %d CE register values" % n)
        else:
            FAILED.append("hw.c: ipq5018_regs has no untagged CE register values")
            log("FAIL hw.c: ipq5018_regs CE values already tagged or not found")

    span = table_span(s, "ath11k_ce_ie_addr_ipq5018")
    if span is None:
        log("WARN hw.c: ath11k_ce_ie_addr_ipq5018 not found (skipped)")
    else:
        a, b = span
        chunk = s[a:b]
        new, n = re.subn(r"(\.ie[123]_reg_addr\s*=\s*)(?!ATH11K_REG_TYPE_CE)",
                         r"\1ATH11K_REG_TYPE_CE + ", chunk)
        if n:
            s = s[:a] + new + s[b:]
            CHANGED.append("hw.c: ath11k_ce_ie_addr_ipq5018 -- tagged %d addresses" % n)
            log("OK   hw.c: ath11k_ce_ie_addr_ipq5018 -- tagged %d addresses" % n)
        else:
            log("WARN hw.c: ie_addr values already tagged")

    write(p, s)
else:
    FAILED.append("hw.c missing")

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
log()
log("--- summary ---")
log("changed: %d" % len(CHANGED))
for c in CHANGED:
    log("  + " + c)
log("failed : %d" % len(FAILED))
for f in FAILED:
    log("  ! " + f)

tags = 0
for name in ("hw.c",):
    q = os.path.join(ATH, name)
    if os.path.exists(q):
        tags += read(q).count("ATH11K_REG_TYPE_CE")
log("hw.c ATH11K_REG_TYPE_CE count: %d (expect 7: 4 regs + 3 ie addrs)" % tags)

if REPORT:
    try:
        with open(REPORT, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(LOG) + "\n")
    except Exception as e:  # noqa: BLE001
        print("WARN: could not write report %s: %r" % (REPORT, e))

sys.exit(1 if FAILED else 0)
