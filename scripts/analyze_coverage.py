#!/usr/bin/env python3
"""Parses verilator_coverage's hierarchical report + annotated source (from
scripts/run_coverage.sh) and each block's lint report (from
scripts/run_lint.sh) into one consolidated JSON summary, consumed by the
HTML sign-off dashboard.

Run from the repo root:
    python3 scripts/analyze_coverage.py

This file is the generic engine: it auto-discovers which .v/.vh file
belongs to which block by scanning blocks/*/rtl/, so adding a block never
requires touching this file. The only project-specific knowledge (real FSM
state names, lint-finding triage, vendored-IP file labels) lives in
scripts/coverage_config.py -- see that file's docstring.

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

sys.path.insert(0, str(ROOT / "scripts"))
import coverage_config as cfg  # noqa: E402

CATEGORY_RULES = [(re.compile(pattern), category, note)
                   for pattern, category, note in cfg.CATEGORY_RULES]


def discover_file_to_block():
    """Auto-derives {filename: block} by scanning blocks/*/rtl/ -- a file
    is attributed to whichever block directory physically contains its
    real (non-symlink) copy, unless coverage_config.VENDORED_FILES
    overrides it with a pseudo-block label (for vendored third-party IP,
    e.g. a vendored CPU core).

    Symlinks are skipped when assigning ownership: a top-level block's
    rtl/ dir may be a set of symlinks into every other block's canonical
    source (one copy of each module on disk, see docs/phase_plan.md) --
    counting those would attribute every other block's files to the top
    level purely because it happens to be scanned last alphabetically.
    """
    mapping = {}
    for rtl_dir in sorted(ROOT.glob("blocks/*/rtl")):
        block = rtl_dir.parent.name
        for f in list(rtl_dir.glob("*.v")) + list(rtl_dir.glob("*.vh")):
            if f.is_symlink():
                continue
            mapping[f.name] = block
    mapping.update(cfg.VENDORED_FILES)
    return mapping


FILE_TO_BLOCK = discover_file_to_block()

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
    for fsm_name, spec in cfg.FSM_TABLES.items():
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


def categorize_lint_line(file, message):
    if file in cfg.VENDORED_FILES:
        return ("vendored",
                f"{file} is vendored unmodified (project policy) -- this finding is in the "
                "vendored IP itself, not this project's RTL.")
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


def per_file_line_coverage():
    """Computes line-coverage % directly per annotated source file (not
    per hierarchy instance, which double-counts shared sub-modules under
    every test that instantiates them). Only real .v module files
    discovered under blocks/*/rtl/ (per FILE_TO_BLOCK) are included --
    test-only harnesses (testtop.v tops, fake_* BFMs, shared tb/common/
    helpers) live outside blocks/*/rtl/ by convention, so they fall out of
    this table automatically without needing an exclude list. `.vh`
    headers are always excluded here even if they contain executable
    statements (e.g. shared combinational functions): Verilog-2001 has no
    package/import mechanism, so a `.vh` is meant to be `include`d
    (pasted) into whichever module body needs it -- reporting it as its
    own row would double-count/misattribute coverage that's really the
    including module's."""
    results = []
    for path in sorted(ANNOTATED.glob("*.v")):
        if path.name not in FILE_TO_BLOCK:
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
            "block": FILE_TO_BLOCK[path.name],
            "covered": covered, "total": total,
            "pct": round(100.0 * covered / total, 1),
        })
    return sorted(results, key=lambda r: (r["block"], r["file"]))


TOGGLE_WAIVERS_FILE = COV_DIR / "toggle_waivers.txt"
MERGED_DAT = COV_DIR / "merged.dat"

OUTER_RE = re.compile(r"^C '(.*)' (\d+)\s*$")


def load_toggle_waivers():
    """Reads reports/sign_off/coverage/toggle_waivers.txt: one rule per
    non-comment line, '<signal-regex><TAB><reason>'. Each rule is tested
    against both the bit-indexed signal name (e.g. 's_bresp[0]') and the
    base name with the index stripped (e.g. 's_bresp'), so a single file
    can hold both whole-signal rules and single-bit rules."""
    rules = []
    if not TOGGLE_WAIVERS_FILE.exists():
        return rules
    for raw in TOGGLE_WAIVERS_FILE.read_text(errors="replace").splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#") or "\t" not in line:
            continue
        pattern, reason = line.split("\t", 1)
        rules.append((re.compile(pattern.strip()), reason.strip()))
    return rules


def base_signal_name(sig):
    return re.sub(r"\[\d+\]$", "", sig)


def match_waiver(rules, full_signal, base_signal):
    for pattern, reason in rules:
        if pattern.match(full_signal) or pattern.match(base_signal):
            return reason
    return None


def parse_toggle_bits():
    """Parses merged.dat directly instead of relying on verilator_coverage's
    own --report summary: that report counts the same underlying source-code
    toggle point once per hierarchy instantiation of a shared sub-module
    (e.g. a core instantiated in several different places across the merged
    suite), inflating the denominator without inflating actual stimulus
    diversity. This reads every raw toggle point, keyed by (file, line,
    signal), and keeps the max hit count seen for each 0->1/1->0 direction
    across ALL instances -- a bit counts as covered if ANY instance ever
    exercised both directions.

    merged.dat encodes each point as:
      C '\\x01<key1>\\x02<value1>\\x01<key2>\\x02<value2>...' <count>
    with keys possibly multi-character (e.g. 'page', not just 'f'/'l'/'t').
    """
    points = {}
    if not MERGED_DAT.exists():
        return points
    with open(MERGED_DAT, "rb") as f:
        for raw in f:
            line = raw.decode("utf-8", errors="replace")
            if not line.startswith("C '"):
                continue
            m = OUTER_RE.match(line.rstrip("\n"))
            if not m:
                continue
            body, count_s = m.group(1), m.group(2)
            count = int(count_s)
            fields = {}
            for chunk in body.split("\x01"):
                if not chunk or "\x02" not in chunk:
                    continue
                key, val = chunk.split("\x02", 1)
                fields[key] = val
            if fields.get("t") != "toggle":
                continue
            file = fields.get("f", "")
            # `.vh` headers are pasted via `include` into whichever module
            # needs them (see per_file_line_coverage's docstring) -- same
            # reasoning applies to toggle points recorded against them.
            if file.endswith(".vh") or any(s in file for s in cfg.TOGGLE_EXCLUDE_PATH_SUBSTR):
                continue
            lineno = int(fields.get("l", "0"))
            o = fields.get("o", "")
            if ":" not in o:
                continue
            signal, dirn = o.rsplit(":", 1)
            key = (file, lineno, signal)
            d = points.setdefault(key, {"0->1": 0, "1->0": 0})
            d[dirn] = max(d[dirn], count)
    return points


def build_toggle_waiver_report():
    """Computes deduplicated per-bit toggle coverage before and after
    applying reports/sign_off/coverage/toggle_waivers.txt. A waived bit is
    removed from BOTH numerator and denominator (it neither helps nor hurts
    the score) -- distinct from a plain uncovered bit, which still counts
    against the denominator and shows up in 'residual_gaps' for follow-up."""
    rules = load_toggle_waivers()
    bits = parse_toggle_bits()

    before_total = len(bits)
    before_covered = sum(1 for d in bits.values() if d["0->1"] > 0 and d["1->0"] > 0)

    waived_count = 0
    after_covered = 0
    after_total = 0
    by_reason = {}
    by_block_before = {}
    by_block_after = {}
    residual = []

    for (file, line, signal), d in bits.items():
        rel = file.split(ROOT.name + "/")[-1] if ROOT.name + "/" in file else file
        fname = Path(rel).name
        block = FILE_TO_BLOCK.get(fname, fname)
        covered = d["0->1"] > 0 and d["1->0"] > 0

        bb = by_block_before.setdefault(block, {"covered": 0, "total": 0})
        bb["total"] += 1
        if covered:
            bb["covered"] += 1

        reason = None if covered else match_waiver(rules, signal, base_signal_name(signal))

        if reason:
            waived_count += 1
            entry = by_reason.setdefault(reason, {"count": 0, "examples": []})
            entry["count"] += 1
            if len(entry["examples"]) < 3:
                entry["examples"].append(f"{rel}:{line} {signal}")
            continue

        after_total += 1
        ab = by_block_after.setdefault(block, {"covered": 0, "total": 0})
        ab["total"] += 1
        if covered:
            after_covered += 1
            ab["covered"] += 1
        else:
            residual.append({"file": rel, "line": line, "signal": signal, "block": block,
                              "hit_0to1": d["0->1"], "hit_1to0": d["1->0"]})

    def pct(c, t):
        return round(100.0 * c / t, 1) if t else 0.0

    return {
        "before": {"covered": before_covered, "total": before_total, "pct": pct(before_covered, before_total)},
        "after": {"covered": after_covered, "total": after_total, "pct": pct(after_covered, after_total)},
        "waived_bit_count": waived_count,
        "waiver_rule_count": len(rules),
        "by_reason": [
            {"reason": reason, "count": v["count"], "examples": v["examples"]}
            for reason, v in sorted(by_reason.items(), key=lambda kv: -kv[1]["count"])
        ],
        "by_block_before": {k: {**v, "pct": pct(v["covered"], v["total"])} for k, v in by_block_before.items()},
        "by_block_after": {k: {**v, "pct": pct(v["covered"], v["total"])} for k, v in by_block_after.items()},
        "residual_gaps": sorted(residual, key=lambda r: (r["block"], r["file"], r["line"])),
    }


def main():
    summary = {}
    summary["coverage_overall"] = parse_hier_report().get("TOP", {})
    summary["coverage_by_file"] = per_file_line_coverage()
    summary["fsm_coverage"] = build_fsm_coverage()
    summary["lint_findings"] = parse_lint_reports()
    summary["toggle_waiver_report"] = build_toggle_waiver_report()

    vendored_blocks = set(cfg.VENDORED_FILES.values())
    own_rtl = [f for f in summary["coverage_by_file"] if f["block"] not in vendored_blocks]
    covered = sum(f["covered"] for f in own_rtl)
    total = sum(f["total"] for f in own_rtl)
    summary["coverage_own_rtl_line_pct"] = round(100.0 * covered / total, 1) if total else 0.0

    out_path = COV_DIR.parent / "dashboard_data.json"
    out_path.write_text(json.dumps(summary, indent=2))
    print(f"Wrote {out_path}")
    print(f"  overall line/toggle/branch: {summary['coverage_overall']}")
    print(f"  FSMs analyzed: {len(summary['fsm_coverage'])}")
    print(f"  lint findings: {len(summary['lint_findings'])}")
    twr = summary["toggle_waiver_report"]
    print(f"  toggle (deduped, before waivers): {twr['before']['pct']}% "
          f"({twr['before']['covered']}/{twr['before']['total']} bits)")
    print(f"  toggle (deduped, after {twr['waiver_rule_count']} waiver rules, "
          f"{twr['waived_bit_count']} bits waived): {twr['after']['pct']}% "
          f"({twr['after']['covered']}/{twr['after']['total']} bits)")


if __name__ == "__main__":
    sys.exit(main())
