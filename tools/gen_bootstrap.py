#!/usr/bin/env python3
"""Rebuild install-wireguard2home.sh by refreshing each embedded sub-script
in place. Robust: only the heredoc bodies between the ____W2H_*____ markers
are replaced; the bootstrap's own logic (HEADER/MIDDLE) is left untouched.
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOOT = os.path.join(REPO, "install-wireguard2home.sh")

# delimiter -> source filename (order irrelevant for in-place replace)
# Nur diese drei Scripts werden im Bootstrap eingebettet. Wireguard2Home.sh ist
# autark (Client-Manager, Dashboard, Backup/Restore sind inline) — die frueheren
# Standalone-Scripts (create-wg-client.sh, wireguard-dashboard.sh, backup-/
# restore-wireguard2home.sh, runtime-paths.sh) wurden entfernt.
EMBEDS = {
    "____W2H_INSTALL_VPS____": "install-vps.sh",
    "____W2H_INSTALL_GATEWAY____": "install-gateway-host.sh",
    "____W2H_MAIN_SCRIPT____": "Wireguard2Home.sh",
}


def read(name):
    with open(os.path.join(REPO, name)) as f:
        return f.read()


def main():
    boot = read("install-wireguard2home.sh")

    for delim, fname in EMBEDS.items():
        content = read(fname)
        if delim in content:
            raise ValueError(f"Delimiter {delim!r} appears inside {fname}!")
        if not content.endswith("\n"):
            content += "\n"

        start = f"  cat > \"$1\" <<'{delim}'\n"
        si = boot.find(start)
        if si == -1:
            raise ValueError(f"Start marker for {delim} not found in bootstrap")
        si += len(start)

        end = f"{delim}\n  chmod 700"
        ei = boot.find(end, si)
        if ei == -1:
            raise ValueError(f"End marker for {delim} not found in bootstrap")

        boot = boot[:si] + content + boot[ei:]

    with open(BOOT, "w") as f:
        f.write(boot)

    n = boot.count("\n")
    print(f"Rebuilt {BOOT}")
    print(f"Lines: {n}")


if __name__ == "__main__":
    main()
