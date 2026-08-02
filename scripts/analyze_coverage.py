#!/usr/bin/env python3
"""Parses verilator_coverage's hierarchical report + annotated source (from
scripts/run_coverage.sh) and each block's lint report (from
scripts/run_lint.sh) into one consolidated JSON summary, consumed by the
HTML sign-off dashboard.

Run from the repo root:
    python3 scripts/analyze_coverage.py

FSM state coverage isn't a native Verilator coverage category for plain
Verilog-2001 case-based FSMs (see docs/project_retrospective.md) -- instead
this reads each FSM's per-state `case` arm hit count directly out of the
annotated source (every `STATE_NAME: begin` line already carries its own
line-coverage hit count), which is an exact "was this state ever entered"
signal, not an approximation.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COV_DIR = ROOT / "reports/sign_off/coverage"
ANNOTATED = COV_DIR / "annotated"

# ---- FSM state tables (state name -> as it appears as "NAME: begin" or
# "NAME:" in the case statement), one entry per module that has a real FSM.
# timer.v/watchdog.v are plain down-counters, not FSMs -- intentionally
# excluded.
FSM_TABLES = {
    "uart": {
        "file": "uart.v",
        "states": ["TX_IDLE", "TX_START", "TX_DATA", "TX_STOP"],
    },
    "i2c_master": {
        "file": "i2c_master.v",
        "states": ["ST_IDLE", "ST_START", "ST_ADDR", "ST_ADDR_ACK", "ST_WDATA",
                   "ST_WDATA_ACK", "ST_RDATA", "ST_RDATA_ACK", "ST_STOP"],
    },
    "spi_master": {
        "file": "spi_master.v",
        "states": ["IDLE", "RUN"],
    },
    "jtag_tap": {
        "file": "jtag_tap.v",
        "states": ["TEST_LOGIC_RESET", "RUN_TEST_IDLE", "SELECT_DR_SCAN",
                   "CAPTURE_DR", "SHIFT_DR", "EXIT1_DR", "PAUSE_DR", "EXIT2_DR",
                   "UPDATE_DR", "SELECT_IR_SCAN", "CAPTURE_IR", "SHIFT_IR",
                   "EXIT1_IR", "PAUSE_IR", "EXIT2_IR", "UPDATE_IR"],
    },
    "aes_core": {
        "file": "aes_core.v",
        "states": ["ST_IDLE", "ST_KEYEXP", "ST_ROUND", "ST_FINAL"],
    },
    "aes_chain": {
        "file": "aes_chain.v",
        "states": ["ST_IDLE", "ST_CORE"],
    },
    "axi_lite_xbar (write)": {
        "file": "axi_lite_xbar.v",
        "states": ["W_IDLE", "W_ISSUE", "W_WAIT_B", "W_RESP"],
    },
    "axi_lite_xbar (read)": {
        "file": "axi_lite_xbar.v",
        "states": ["R_IDLE", "R_ISSUE", "R_WAIT_R", "R_RESP"],
    },
    "dma_ram (write)": {
        "file": "dma_ram.v",
        "states": ["W_IDLE", "W_BURST"],
    },
    "dma_ram (read)": {
        "file": "dma_ram.v",
        "states": ["R_IDLE", "R_BURST"],
    },
    "dma_engine": {
        "file": "dma_engine.v",
        "states": ["ST_IDLE", "ST_RD_ADDR", "ST_RD_DATA", "ST_AES_GO",
                   "ST_AES_WAIT", "ST_WR_ADDR", "ST_WR_DATA", "ST_WR_RESP",
                   "ST_DONE"],
    },
}

# Verilator's --annotate output preserves 1:1 line correspondence with the
# original source (no line-number column) -- each line is prefixed with a
# 7-character coverage marker: either 7 spaces (not an instrumented point),
# or one marker char (' '/'~'/'%' -- point covered/a different point
# type/uncovered) followed immediately by a zero-padded 6-digit hit count.
LINE_RE = re.compile(r"^([~% ])(\d{6})(.*)$")


def parse_annotated_hits(filename):
    """Returns {trimmed_source_text: hit_count} for every coverage-
    instrumented line in an annotated file (good enough for unique
    state-arm labels like 'ST_IDLE: begin')."""
    path = ANNOTATED / filename
    hits = {}
    if not path.exists():
        return hits
    for raw in path.read_text(errors="replace").splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        count = int(m.group(2))
        key = m.group(3).strip()
        # keep the max count seen for this exact source text (a state arm's
        # header line only appears once per file, but be defensive)
        if key not in hits or count > hits[key]:
            hits[key] = count
    return hits


def state_hit_count(hits, state_name):
    # match "STATE: begin" or "STATE:" as the arm header
    for suffix in (f"{state_name}: begin", f"{state_name}:"):
        if suffix in hits:
            return hits[suffix]
    # fall back: any key that starts with "STATE_NAME:" (e.g. "STATE: begin // comment")
    for key, count in hits.items():
        if key.startswith(f"{state_name}:"):
            return count
    return None


def build_fsm_coverage():
    result = {}
    for fsm_name, spec in FSM_TABLES.items():
        hits = parse_annotated_hits(spec["file"])
        states = []
        for s in spec["states"]:
            count = state_hit_count(hits, s)
            states.append({"name": s, "hits": count if count is not None else 0,
                            "visited": bool(count)})
        visited_n = sum(1 for s in states if s["visited"])
        result[fsm_name] = {
            "file": spec["file"],
            "states": states,
            "visited": visited_n,
            "total": len(states),
            "pct": round(100.0 * visited_n / len(states), 1) if states else 0.0,
        }
    return result


HIER_LINE_RE = re.compile(r"^(\s*)(TOP(?:\.\S+)?)\s*$")
METRIC_RE = re.compile(r"^\s*(line|toggle|branch)\s*:\s*([\d.]+)%\s*\(\s*(\d+)/\s*(\d+)\)")


def parse_hier_report():
    """Parses `verilator_coverage --report summary,hier` output into a
    nested dict keyed by hierarchy path (e.g. 'TOP.aes.u_chain')."""
    text = subprocess.run(
        ["verilator_coverage", "--report", "summary,hier", str(COV_DIR / "merged.dat")],
        capture_output=True, text=True, check=True
    ).stdout

    modules = {}
    current = None
    for line in text.splitlines():
        m = HIER_LINE_RE.match(line)
        if m and line.strip().startswith("TOP"):
            current = line.strip()
            modules[current] = {}
            continue
        m2 = METRIC_RE.match(line)
        if m2 and current:
            kind, pct, num, den = m2.groups()
            modules[current][kind] = {"pct": float(pct), "covered": int(num), "total": int(den)}
    return modules


LINT_WARNING_RE = re.compile(r"^%Warning-([A-Z]+): (\S+):(\d+):\d+: (.*)$")

# Manual triage of every lint finding category still present after the
# dead-code fixes (see docs/project_retrospective.md's Phase 7 addendum).
CATEGORY_RULES = [
    (re.compile(r"Bits of signal are not used: 's_(aw|ar)addr'"), "benign-address-decode",
     "Upper address bits unused -- the crossbar already decodes/routes before presenting to this slave; only the local register-offset bits matter here."),
    (re.compile(r"Signal is not used: 's_wstrb'"), "benign-no-byte-strobe",
     "Byte-strobe writes aren't supported on control/status registers -- every register here is written as a full 32-bit word in practice."),
    (re.compile(r"Signal is not used: 's_bready'"), "documented-limitation-bready",
     "AXI response channel doesn't check BREADY before dropping BVALID -- works correctly against this project's own crossbar timing, not strictly AXI4-compliant in general. Documented in docs/architecture.md."),
    (re.compile(r"Signal is not used: 's_rready'"), "documented-limitation-rready",
     "AXI response channel doesn't check RREADY before dropping RVALID -- same as the BREADY case above."),
    (re.compile(r"Signal is not used: 'm_bresp'"), "documented-limitation-bresp",
     "dma_engine's own burst master doesn't check dma_ram's write response code -- same class of limitation as picorv32_axi not checking BRESP/RRESP."),
    (re.compile(r"Signal is not used: 'm_rresp'"), "documented-limitation-rresp",
     "dma_engine's own burst master doesn't check dma_ram's read response code."),
    (re.compile(r"Signal is not used: 's_(aw|ar)(size|burst)'"), "benign-burst-subset",
     "This project's AXI4 burst subset is INCR-only, fixed 4-byte beats (see rtl/include/axi4.vh) -- these fields are assumed constant by convention, not read at runtime."),
    (re.compile(r"Bits of function variable are not used: 'addr'"), "benign-decode-function",
     "The crossbar's decode_addr() function only inspects the specific bit ranges needed for region/peripheral selection."),
    (re.compile(r"Signal is not used: 's_awaddr'$|Signal is not used: 's_wdata'$"), "benign-readonly-ignores-write",
     "boot_rom is read-only (writes are rejected with SLVERR) -- it never needs the write address or data at all, not even partially."),
    (re.compile(r"Bits of signal are not used: 's_wdata'\[31:8\]"), "benign-narrow-register-width",
     "TXDATA is an 8-bit register (one UART byte) -- the upper 24 bits of a 32-bit AXI word are never meaningful here."),
    (re.compile(r"Parameter is not used: 'MODE_ECB'"), "benign-documentation-constant",
     "MODE_ECB documents aes_chain's mode encoding for aes.v's register interface; ECB itself is handled as the implicit default (not CBC, not CTR), so the constant is never directly compared."),
    (re.compile(r"Signal is not used: '(core|chain)_busy'"), "benign-unused-status-signal",
     "A busy/done status wire from the instantiated sub-block; the consuming FSM only needs the done pulse (busy is informational only, safe to leave unread)."),
]


def categorize_lint_line(file, message):
    if file == "picorv32.v":
        return ("vendored-picorv32-style",
                "PicoRV32 is vendored unmodified (project policy) -- this finding is in the "
                "vendored core itself, not this project's RTL. See rtl/core/lint/lint_report.txt "
                "for the full, unsuppressed picture.")
    for pattern, category, note in CATEGORY_RULES:
        if pattern.search(message):
            return category, note
    return "uncategorized", ""


def parse_lint_reports():
    findings = []
    for report in sorted((ROOT / "blocks").glob("*/lint/lint_report.txt")):
        block = report.parent.parent.name
        text = report.read_text(errors="replace")
        for line in text.splitlines():
            m = LINT_WARNING_RE.match(line)
            if not m:
                continue
            wtype, file, lineno, message = m.groups()
            category, note = categorize_lint_line(Path(file).name, message)
            findings.append({
                "block": block, "type": wtype, "file": Path(file).name,
                "line": int(lineno), "message": message,
                "category": category, "note": note,
            })
    return findings


FILE_TO_BLOCK = {
    "timer.v": "timer", "watchdog.v": "watchdog", "uart.v": "uart",
    "sram.v": "sram", "boot_rom.v": "boot_rom", "i2c_master.v": "i2c",
    "spi_master.v": "spi", "jtag_tap.v": "jtag", "jtag_dtm.v": "jtag",
    "jtag_axi_bridge.v": "jtag", "aes_key_expand.v": "aes", "aes_core.v": "aes",
    "aes_chain.v": "aes", "aes.v": "aes", "axi_lite_xbar.v": "axi_lite_xbar",
    "dma_ram.v": "dma", "dma_engine.v": "dma", "soc_top.v": "soc_top",
    "picorv32.v": "picorv32 (vendored)",
}

# Test-only harnesses excluded from the per-file RTL coverage table --
# real deliverable RTL only.
EXCLUDE_FILES = {
    "xbar_testtop.v", "spi_testtop.v", "i2c_testtop.v", "jtag_chain_testtop.v",
    "dma_engine_testtop.v", "fake_spi_slave.v", "fake_i2c_slave.v",
    "fake_axi_lite_slave.v", "aes_pkg.vh",
}


def per_file_line_coverage():
    """Computes line-coverage % directly per annotated source file (not
    per hierarchy instance, which double-counts shared sub-modules under
    every test that instantiates them)."""
    results = []
    for path in sorted(ANNOTATED.glob("*.v")) + sorted(ANNOTATED.glob("*.vh")):
        if path.name in EXCLUDE_FILES:
            continue
        covered = 0
        total = 0
        for raw in path.read_text(errors="replace").splitlines():
            m = LINE_RE.match(raw)
            if not m:
                continue
            total += 1
            if int(m.group(2)) > 0:
                covered += 1
        if total == 0:
            continue
        results.append({
            "file": path.name,
            "block": FILE_TO_BLOCK.get(path.name, "?"),
            "covered": covered, "total": total,
            "pct": round(100.0 * covered / total, 1),
        })
    return sorted(results, key=lambda r: (r["block"], r["file"]))


def main():
    summary = {}
    summary["coverage_overall"] = parse_hier_report().get("TOP", {})
    summary["coverage_by_file"] = per_file_line_coverage()
    summary["fsm_coverage"] = build_fsm_coverage()
    summary["lint_findings"] = parse_lint_reports()

    own_rtl = [f for f in summary["coverage_by_file"] if f["block"] != "picorv32 (vendored)"]
    covered = sum(f["covered"] for f in own_rtl)
    total = sum(f["total"] for f in own_rtl)
    summary["coverage_own_rtl_line_pct"] = round(100.0 * covered / total, 1) if total else 0.0

    out_path = COV_DIR.parent / "dashboard_data.json"
    out_path.write_text(json.dumps(summary, indent=2))
    print(f"Wrote {out_path}")
    print(f"  overall line/toggle/branch: {summary['coverage_overall']}")
    print(f"  FSMs analyzed: {len(summary['fsm_coverage'])}")
    print(f"  lint findings: {len(summary['lint_findings'])}")


if __name__ == "__main__":
    sys.exit(main())
