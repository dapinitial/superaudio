#!/usr/bin/env python3
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
"""
Probe the LAN for AirPlay 1 (RAOP) receivers and emit a clean JSON description
of each — the input the onboarding skill reasons over to draft a device profile.

NETWORK DISCLOSURE: this runs `dns-sd` (Apple's built-in mDNS/Bonjour browser)
to list `_raop._tcp` services and resolve each one's host/port + TXT record.
It is passive LAN discovery — no packets are sent to the speakers themselves,
nothing leaves the local network, nothing is written to disk.

Usage:
    probe-raop.py [--browse-seconds 4] [--resolve-seconds 3]

Output (stdout): JSON list of objects:
    {
      "serviceName": "B8FF6126D4F2@Spacelab Audio",   # {MAC}@{owner-given name}
      "mac": "B8FF6126D4F2",
      "displayName": "Spacelab Audio",                # the part the app matches on
      "host": "Spacelab-Audio.local.",
      "port": 5000,
      "txt": { "am": "A5", "et": "0,4", "cn": "0,1", ... }
    }

The `displayName` here is derived identically to the SuperAudio app
(`AirPlay1Discoverer.makeDescriptor` — split on '@', take the suffix), so a
profile whose match.modelHints fit this string will resolve in the app too.
The `txt["am"]` field is the stable, owner-independent model identifier — prefer
it for portable match hints (see SKILL.md "Draft phase").
"""

import json
import re
import subprocess
import sys
import time


def run_bounded(args, seconds):
    """Run a streaming command for `seconds`, then terminate. Returns stdout."""
    try:
        proc = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
    except FileNotFoundError:
        sys.stderr.write(f"error: '{args[0]}' not found (need macOS dns-sd)\n")
        sys.exit(2)
    time.sleep(seconds)
    proc.terminate()
    try:
        out, _ = proc.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
    return out or ""


def browse(seconds):
    """Return the set of `_raop._tcp` service instance names on the LAN."""
    out = run_bounded(["dns-sd", "-B", "_raop._tcp"], seconds)
    names = set()
    for line in out.splitlines():
        # Columns: <ts> Add/Rmv <flags> <if> <domain> _raop._tcp. <Instance Name>
        # The instance name can contain spaces, so split on the service-type token.
        if "Add" not in line.split():
            continue
        marker = "_raop._tcp."
        idx = line.find(marker)
        if idx == -1:
            continue
        name = line[idx + len(marker):].strip()
        if name:
            names.add(name)
    return sorted(names)


def resolve(instance, seconds):
    """Resolve one instance to host/port + TXT dict via `dns-sd -L`."""
    out = run_bounded(["dns-sd", "-L", instance, "_raop._tcp", "local"], seconds)
    host, port, txt = None, None, {}
    for line in out.splitlines():
        m = re.search(r"can be reached at\s+(\S+):(\d+)", line)
        if m:
            host = m.group(1)
            port = int(m.group(2))
            continue
        # TXT line: leading whitespace then space-separated key=value tokens.
        if line.startswith((" ", "\t")) and "=" in line:
            for tok in line.strip().split(" "):
                if "=" in tok:
                    k, _, v = tok.partition("=")
                    k = k.strip()
                    if k:
                        txt[k] = v.strip()
    return host, port, txt


def split_name(service_name):
    """{MAC}@{DisplayName} -> (mac, displayName). Mirrors the app's logic."""
    if "@" in service_name:
        mac, _, display = service_name.partition("@")
        return mac, display
    return None, service_name


_COMPUTER_AM = re.compile(r"^(i?mac|macbook|macmini|macpro)", re.IGNORECASE)


def classify(txt):
    """Non-authoritative heuristic to help the skill pick a real AP1 sink.

    The `_raop._tcp` service is advertised by classic AirPlay-1 speakers AND by
    Macs (as AirPlay receivers) AND by AirPlay-2 devices (Sonos, HomePods). Only
    the first is onboardable in this alpha. Returns one of:
      - 'computer'           : am is a Mac model (iMac20,1, MacBookPro…) — skip.
      - 'airplay2-likely'    : has a `pk` public key (AP2 pairing) — needs the
                               AP2/MFi path, out of scope; skip.
      - 'airplay1-receiver'  : classic RAOP speaker — the onboarding target.
    The skill must still confirm via identification; this only steers it.
    """
    am = txt.get("am", "")
    if _COMPUTER_AM.match(am):
        return "computer"
    if txt.get("pk"):
        return "airplay2-likely"
    return "airplay1-receiver"


def main():
    browse_seconds = 4
    resolve_seconds = 3
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--browse-seconds" and i + 1 < len(args):
            browse_seconds = float(args[i + 1])
        if a == "--resolve-seconds" and i + 1 < len(args):
            resolve_seconds = float(args[i + 1])

    sys.stderr.write(
        f"Browsing _raop._tcp for {browse_seconds:g}s "
        "(passive LAN discovery, nothing sent to speakers)...\n"
    )
    instances = browse(browse_seconds)
    sys.stderr.write(f"Found {len(instances)} RAOP service(s); resolving...\n")

    devices = []
    for inst in instances:
        host, port, txt = resolve(inst, resolve_seconds)
        mac, display = split_name(inst)
        devices.append({
            "serviceName": inst,
            "mac": mac,
            "displayName": display,
            "host": host,
            "port": port if port is not None else 5000,
            "likelyKind": classify(txt),
            "txt": txt,
        })

    json.dump(devices, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
