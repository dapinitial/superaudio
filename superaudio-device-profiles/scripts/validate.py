#!/usr/bin/env python3
# MIT licensed — part of superaudio-device-profiles. See LICENSE.
"""
Validate every profile in profiles/ against schema.json.

This is the CI gate for the superaudio-device-profiles repo: every contributed
profile (including those drafted by SuperAudio's /onboard-audio-device Claude
Skill) is validated on PR before merge. Zero dependencies — no `jsonschema`
package required; it checks the high-value subset the schema enforces plus the
repo's honesty norms (verifiedBy requires a date; match needs a real key).

Usage:
    python3 scripts/validate.py            # validate all profiles/*.json
    python3 scripts/validate.py <file>...  # validate specific files

Exit 0 = all valid, 1 = one or more invalid (reasons on stderr).
"""

import glob
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_PATH = os.path.join(REPO, "schema.json")


def enum_of(node, *path):
    for p in path:
        node = node.get(p, {})
    return node.get("enum")


def validate(path, schema):
    defs = schema.get("$defs", {})
    sink_props = defs.get("sinkRole", {}).get("properties", {})
    codec_props = sink_props.get("codec", {}).get("properties", {})
    enc_props = sink_props.get("encryption", {}).get("properties", {})
    vol_props = sink_props.get("volumeScale", {}).get("properties", {})

    errors = []
    try:
        with open(path) as f:
            p = json.load(f)
    except json.JSONDecodeError as e:
        return [f"not valid JSON — {e}"]

    for key in schema.get("required", []):
        if key not in p:
            errors.append(f"missing required top-level field '{key}'")

    if p.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")

    id_pat = schema["properties"]["id"]["pattern"]
    if "id" in p and not re.match(id_pat, str(p["id"])):
        errors.append(f"id '{p.get('id')}' must match {id_pat}")

    # Filename should equal '<id>.json' so the loader's id-keying lines up.
    if "id" in p:
        expected = f"{p['id']}.json"
        if os.path.basename(path) != expected:
            errors.append(f"filename should be '{expected}' to match id")

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

    if p.get("verifiedBy") and not p.get("verifiedDate"):
        errors.append("verifiedBy is non-empty but verifiedDate is null")
    match = p.get("match", {})
    if not match.get("modelHints") and not match.get("macOUI"):
        errors.append("match has neither modelHints nor macOUI — would match every "
                      "device of its protocol")

    return errors


def main():
    if not os.path.isfile(SCHEMA_PATH):
        sys.stderr.write(f"error: schema.json not found at {SCHEMA_PATH}\n")
        sys.exit(2)
    with open(SCHEMA_PATH) as f:
        schema = json.load(f)

    files = sys.argv[1:] or sorted(glob.glob(os.path.join(REPO, "profiles", "*.json")))
    if not files:
        sys.stderr.write("error: no profiles found to validate\n")
        sys.exit(2)

    failed = 0
    for path in files:
        errs = validate(path, schema)
        name = os.path.relpath(path, REPO)
        if errs:
            failed += 1
            sys.stderr.write(f"FAIL: {name}\n")
            for e in errs:
                sys.stderr.write(f"  - {e}\n")
        else:
            sys.stdout.write(f"PASS: {name}\n")

    if failed:
        sys.stderr.write(f"\n{failed} profile(s) failed validation.\n")
        sys.exit(1)
    sys.stdout.write(f"\nAll {len(files)} profile(s) valid.\n")


if __name__ == "__main__":
    main()
