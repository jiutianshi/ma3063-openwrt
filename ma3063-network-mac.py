#!/usr/bin/env python3
"""Inject the MA3063 network/MAC setup into ipq50xx's 02_network.

Runs in CI against the *source tree* file
    openwrt/target/linux/ipq50xx/base-files/etc/board.d/02_network
which is base-files, NOT a package build dir -- so an in-place edit is safe here
(there is no Build/Prepare that would wipe it).

What it adds for `ruijie,rg-ma3063`:
  1. ucidef_set_interfaces_lan_wan "eth0" "eth1"   -> eth1 becomes the WAN port
  2. ipq50xx_setup_macs(): LAN mac  = ART+0
                           WAN mac  = ART+0 + 1
so a freshly flashed image has the factory MACs and a working WAN port without
any manual `uci set`.

NOTE (verified 2026-09-23): the *wireless* MAC cannot be fixed here.
ath11k's ahb.c has no of_get_mac_address(); it takes the MAC from the BDF via
ath11k_hw_get_mac_from_pdev_id().  Wireless MACs stay a uci-level setting
(option macaddr on the wifi-iface), which persists across reboot/sysupgrade.
"""
import io
import os
import re
import sys

# Indentation follows the existing file: `case $board in` sits at one tab, case
# labels at two, their bodies at three.  Written as the *final* two-tab form; the
# injector re-indents it to whatever the siblings actually use.
MACS_FN = """\
ipq50xx_setup_macs()
{
\tlocal board="$1"
\tlocal lan_mac wan_mac

\tcase $board in
\t\truijie,rg-ma3063)
\t\t\tlan_mac=$(mtd_get_mac_binary "0:ART" 0)
\t\t\twan_mac=$(macaddr_add "$lan_mac" 1)
\t\t\t[ -n "$lan_mac" ] && ucidef_set_interface_macaddr "lan" "$lan_mac"
\t\t\t[ -n "$wan_mac" ] && ucidef_set_interface_macaddr "wan" "$wan_mac"
\t\t\t;;
\tesac
}
"""

IFACE_BLOCK = """\
\t\truijie,rg-ma3063)
\t\t\tucidef_set_interfaces_lan_wan "eth0" "eth1"
\t\t\t;;
"""


def log(s):
    print(s, flush=True)


def main():
    if len(sys.argv) < 2:
        log("usage: ma3063-network-mac.py <02_network path> [report]")
        return 2
    path = sys.argv[1]
    report = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.isfile(path):
        log("ERROR: %s not found" % path)
        return 1

    s = io.open(path, encoding="utf-8", errors="replace", newline="").read()
    orig = s
    crlf = "\r\n" in s
    nl = "\r\n" if crlf else "\n"

    changed = []
    failed = []

    if "ruijie,rg-ma3063" in s:
        log("already patched (ruijie,rg-ma3063 present) -- skip")
        if report:
            io.open(report, "w", encoding="utf-8", newline="").write(
                "already patched, nothing to do\n")
        return 0

    # 1) make sure macaddr_add / mtd_get_mac_binary are available
    if "/lib/functions/system.sh" not in s:
        s = s.replace(". /lib/functions/uci-defaults.sh" + nl,
                      ". /lib/functions/uci-defaults.sh" + nl +
                      ". /lib/functions/system.sh" + nl, 1)
        if "/lib/functions/system.sh" in s:
            changed.append("sourced /lib/functions/system.sh")
        else:
            failed.append("could not add '. /lib/functions/system.sh'")
    else:
        log("system.sh already sourced")

    # 2) add the interface case for ruijie inside ipq50xx_setup_interfaces
    m = re.search(r"(ipq50xx_setup_interfaces\(\).*?case \$board in\n)(.*?)(\n\t*esac)",
                  s, re.S)
    if m:
        body = m.group(2)
        # figure out the indentation used by existing cases from the first entry
        ind = re.search(r"\n(\s*)\S.*?\)", body)
        indent = ind.group(1) if ind else "\t\t"
        block = IFACE_BLOCK
        if indent != "\t\t":
            block = block.replace("\t\t", indent)
        s = s[:m.end(2)] + nl + block.rstrip(nl) + s[m.end(2):]
        changed.append("interfaces: ucidef_set_interfaces_lan_wan eth0 eth1")
    else:
        failed.append("ipq50xx_setup_interfaces() case block not found")

    # 3) add ipq50xx_setup_macs() right after ipq50xx_setup_interfaces()
    m2 = re.search(r"\n\}\n", s[s.index("ipq50xx_setup_interfaces()"):])
    if m2 and "ipq50xx_setup_macs" not in s:
        pos = s.index("ipq50xx_setup_interfaces()") + m2.end()
        # keep a blank line on both sides, like the rest of the file
        s = s[:pos] + nl + MACS_FN.rstrip(nl) + nl + s[pos:]
        changed.append("added ipq50xx_setup_macs()")
    elif "ipq50xx_setup_macs" in s:
        log("ipq50xx_setup_macs() already present")
    else:
        failed.append("could not locate end of ipq50xx_setup_interfaces()")

    # 4) call it before board_config_flush
    if "ipq50xx_setup_macs $board" not in s:
        if "board_config_flush" in s:
            s = s.replace("board_config_flush",
                          "ipq50xx_setup_macs $board" + nl + "board_config_flush", 1)
            changed.append("call ipq50xx_setup_macs $board")
        else:
            failed.append("board_config_flush not found")
    else:
        log("ipq50xx_setup_macs already called")

    if failed:
        for f in failed:
            log("FAIL: %s" % f)
        return 1

    io.open(path, "w", encoding="utf-8", newline="").write(s)

    lines = []
    lines.append("=== MA3063 02_network injection ===")
    lines.append("file: %s" % path)
    lines.append("line endings: %s (preserved)" % ("CRLF" if crlf else "LF"))
    lines.append("")
    lines.append("--- summary ---")
    for c in changed:
        lines.append("  + %s" % c)
    lines.append("changed: %d" % len(changed))
    lines.append("failed : %d" % len(failed))
    lines.append("")
    lines.append("--- result ---")
    lines.append(s)

    out = "\n".join(lines) + "\n"
    log(out)
    if report:
        io.open(report, "w", encoding="utf-8", newline="").write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
