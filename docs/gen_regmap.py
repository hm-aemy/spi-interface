#!/usr/bin/env python3
"""Generate the register-map artifacts from docs/regs.yaml.

docs/regs.yaml is the single source of truth for the register map. This
script renders two artifacts from it:

  * docs/generated/registers_gen.md -- the register reference included by
    docs/registers.md. Regenerated on every Sphinx build (see conf.py) and
    deliberately not versioned.
  * sw/include/qspi_regs.h -- the C register/bit-field header used by
    software (e.g. the hatch SDK). This file IS versioned so that consumers
    do not need to run the generator; CI regenerates it and fails if the
    checked-in copy is stale.

Run from anywhere: paths are resolved relative to this file.
"""

from pathlib import Path

import yaml

HERE = Path(__file__).parent
SRC = HERE / "regs.yaml"
DST_MD = HERE / "generated" / "registers_gen.md"
DST_H = HERE.parent / "sw" / "include" / "qspi_regs.h"


def parse_bits(bits: str) -> tuple[int, int]:
    """'15:8' -> (15, 8); '0' -> (0, 0)."""
    if ":" in bits:
        hi, lo = bits.split(":")
        return int(hi), int(lo)
    return int(bits), int(bits)


def resolve_fields(data: dict) -> None:
    """Resolve fields_like references in place."""
    by_name = {r["name"]: r for r in data["registers"]}
    for reg in data["registers"]:
        if "fields_like" in reg:
            reg["fields"] = by_name[reg["fields_like"]]["fields"]


def gen_markdown(data: dict) -> str:
    out = []
    out.append("<!-- GENERATED from docs/regs.yaml - do not edit by hand -->\n")

    blk = data["block"]
    out.append(f"Base address: **{blk['base']}**\n")

    out.append("| Offset | Register | Reset | Description |")
    out.append("|---|---|---|---|")
    for reg in data["registers"]:
        reset = "—" if reg["reset"] is None else f"`0x{reg['reset']:08X}`"
        out.append(
            f"| `0x{reg['offset']:02X}` | [{reg['name']}](#reg-{reg['name'].lower()}) "
            f"| {reset} | {reg['description']} |"
        )
    out.append("")

    for reg in data["registers"]:
        out.append(f"(reg-{reg['name'].lower()})=")
        out.append(f"## {reg['name']} — offset `0x{reg['offset']:02X}`\n")
        out.append(f"{reg['description']}.")
        reset = "—" if reg["reset"] is None else f"`0x{reg['reset']:08X}`"
        out.append(f" Reset: {reset}\n")
        if "fields_note" in reg:
            out.append(f"{reg['fields_note']}\n")
        if "fields_like" in reg:
            out.append(f"Fields: see [{reg['fields_like']}](#reg-{reg['fields_like'].lower()}).")
            out.append("")
            continue
        out.append("| Bits | Field | Access | Description |")
        out.append("|---|---|---|---|")
        for f in reg["fields"]:
            out.append(
                f"| `{f['bits']}` | {f['name']} | {f['access']} | {f['desc']} |"
            )
        out.append("")

    return "\n".join(out) + "\n"


def gen_header(data: dict) -> str:
    out = []
    out.append("// Copyright 2026 University of Applied Sciences Munich")
    out.append("// Christopher Hinz <christopher.hinz@hm.edu>")
    out.append("// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1")
    out.append("//")
    out.append("// Generated from docs/regs.yaml by docs/gen_regmap.py -- DO NOT EDIT.")
    out.append("// Register byte offsets, bit fields and field encodings of the QSPI")
    out.append("// controller. The SoC-specific base address and register accessors")
    out.append("// live with the consuming SDK (e.g. hatch: software/sdk/include/qspi.h).")
    out.append("")
    out.append("#ifndef QSPI_REGS_H")
    out.append("#define QSPI_REGS_H")

    for reg in data["registers"]:
        name = reg["name"]
        out.append("")
        out.append(f"// {name}: {reg['description']}")
        out.append(f"#define QSPI_{name}_OFFSET  0x{reg['offset']:02X}u")
        if reg["reset"] is not None:
            out.append(f"#define QSPI_{name}_RESET   0x{reg['reset']:08X}u")
        if "fields_like" in reg:
            out.append(f"// Field layout identical to {reg['fields_like']}: "
                       f"use the QSPI_{reg['fields_like']}_* field macros.")
            continue
        for f in reg["fields"]:
            hi, lo = parse_bits(f["bits"])
            width = hi - lo + 1
            fname = f"QSPI_{name}_{f['name']}"
            if width == 1:
                out.append(f"#define {fname}  (1u << {lo})")
            elif width == 32:
                pass  # full-word field: access the register directly
            else:
                umask = (1 << width) - 1
                out.append(f"#define {fname}_SHIFT  {lo}u")
                out.append(f"#define {fname}_MASK   (0x{umask:X}u << {lo}u)")
                out.append(f"#define {fname}(v)     (((uint32_t)(v) & 0x{umask:X}u) << {lo}u)")
                out.append(f"#define {fname}_GET(r) (((uint32_t)(r) >> {lo}u) & 0x{umask:X}u)")

    for enum in data.get("enums", []):
        out.append("")
        out.append(f"// {enum['description']}")
        for v in enum["values"]:
            out.append(f"#define {enum['prefix']}_{v['name']}  {v['value']}u  // {v['desc']}")

    out.append("")
    out.append("#endif // QSPI_REGS_H")
    return "\n".join(out) + "\n"


def main() -> None:
    data = yaml.safe_load(SRC.read_text(encoding="utf-8"))
    resolve_fields(data)

    DST_MD.parent.mkdir(parents=True, exist_ok=True)
    DST_MD.write_text(gen_markdown(data), encoding="utf-8")
    print(f"[gen_regmap] wrote {DST_MD} ({len(data['registers'])} registers)")

    DST_H.parent.mkdir(parents=True, exist_ok=True)
    DST_H.write_text(gen_header(data), encoding="utf-8")
    print(f"[gen_regmap] wrote {DST_H}")


if __name__ == "__main__":
    main()
