#!/usr/bin/env python3
# SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.
"""
Validate a drafted device-profile JSON against superaudio-device-profiles/schema.json.

Zero-dependency (no `jsonschema` package required). It checks the high-value
subset the schema enforces — required fields, the schemaVersion const, the id
pattern, role presence, and the enums we actually populate when drafting. It is
intentionally stricter to fail-loud than to pass-silently: a profile that
passes here will load in the SuperAudio app and validate in the repo's CI.

Usage:
    validate-profile.py <profile.json> [--schema <schema.json>]

Exit code 0 = valid, 1 = invalid (reasons printed to stderr), 2 = usage error.
"""

import json
import os
import re
import sys


def find_schema(start):
    """Walk upward from `start` looking for superaudio-device-profiles/schema.json."""
    d = os.path.abspath(start)
    while True:
        cand = os.path.join(d, "superaudio-device-profiles", "schema.json")
        if os.path.isfile(cand):
            return cand
        cand2 = os.path.join(d, "schema.json")
        if os.path.isfile(cand2):
            return cand2
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def enum_of(schema, *path):
    node = schema
    for p in path:
        node = node.get(p, {})
    return node.get("enum")


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__)
        sys.exit(2)
    profile_path = args[0]
    schema_path = None
    if "--schema" in args:
        schema_path = args[args.index("--schema") + 1]
    if not schema_path:
        schema_path = find_schema(os.path.dirname(os.path.abspath(profile_path)))
    if not schema_path:
        schema_path = find_schema(os.getcwd())
    if not schema_path or not os.path.isfile(schema_path):
        sys.stderr.write("error: could not locate schema.json (pass --schema)\n")
        sys.exit(2)

    with open(schema_path) as f:
        schema = json.load(f)
    defs = schema.get("$defs", {})
    sink_props = defs.get("sinkRole", {}).get("properties", {})
    codec_props = sink_props.get("codec", {}).get("properties", {})
    enc_props = sink_props.get("encryption", {}).get("properties", {})
    vol_props = sink_props.get("volumeScale", {}).get("properties", {})

    try:
        with open(profile_path) as f:
            p = json.load(f)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"FAIL: not valid JSON — {e}\n")
        sys.exit(1)

    errors = []

    # Top-level required fields (from schema.required).
    for key in schema.get("required", []):
        if key not in p:
            errors.append(f"missing required top-level field '{key}'")

    if p.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")

    id_pat = schema["properties"]["id"]["pattern"]
    if "id" in p and not re.match(id_pat, str(p["id"])):
        errors.append(f"id '{p.get('id')}' must match {id_pat} "
                      "(convention: '<manufacturer-slug>-<model-slug>')")

    roles = p.get("roles", {})
    if not isinstance(roles, dict) or (
        roles.get("sink") is None and roles.get("control") is None
    ):
        errors.append("roles must define at least one of sink / control (non-null)")

    sink = roles.get("sink") if isinstance(roles, dict) else None
    if isinstance(sink, dict):
        proto = sink.get("protocol")
        proto_enum = enum_of(sink_props, "protocol")
        if proto is None:
            errors.append("sink.protocol is required")
        elif proto_enum and proto not in proto_enum:
            errors.append(f"sink.protocol '{proto}' not in {proto_enum}")

        codec = sink.get("codec")
        if not isinstance(codec, dict):
            errors.append("sink.codec is required")
        else:
            for req in defs["sinkRole"]["properties"]["codec"].get("required", []):
                if req not in codec:
                    errors.append(f"sink.codec missing required '{req}'")
            for field in ("format", "sampleRate"):
                en = enum_of(codec_props, field)
                if field in codec and en and codec[field] not in en:
                    errors.append(f"sink.codec.{field} '{codec[field]}' not in {en}")

        enc = sink.get("encryption")
        if isinstance(enc, dict) and "et" in enc:
            en = enum_of(enc_props, "et")
            if en and enc["et"] not in en:
                errors.append(f"sink.encryption.et '{enc['et']}' not in {en}")

        vol = sink.get("volumeScale")
        if isinstance(vol, dict) and "type" in vol:
            en = enum_of(vol_props, "type")
            if en and vol["type"] not in en:
                errors.append(f"sink.volumeScale.type '{vol['type']}' not in {en}")

    # Honesty checks the schema can't express but the repo norms require.
    if p.get("verifiedBy") and not p.get("verifiedDate"):
        errors.append("verifiedBy is non-empty but verifiedDate is null — "
                      "set the date you tested on hardware, or clear verifiedBy")
    if not p.get("match", {}).get("modelHints") and not p.get("match", {}).get("macOUI"):
        errors.append("match has neither modelHints nor macOUI — the app would "
                      "match this profile against every device of its protocol")

    if errors:
        sys.stderr.write(f"FAIL: {profile_path}\n")
        for e in errors:
            sys.stderr.write(f"  - {e}\n")
        sys.exit(1)

    sys.stdout.write(f"PASS: {profile_path} (validated against {schema_path})\n")


if __name__ == "__main__":
    main()
