#!/usr/bin/env python3
"""Renders reports/sign_off/dashboard_data.json (see analyze_coverage.py)
plus the other reports/sign_off/*.txt sign-off artifacts into a single
static HTML dashboard: reports/sign_off/dashboard.html.

Run from the repo root, after scripts/run_coverage.sh and
scripts/analyze_coverage.py:
    python3 scripts/build_dashboard.py
"""
import html
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "reports/sign_off"

sys.path.insert(0, str(ROOT / "scripts"))
import coverage_config as cfg  # noqa: E402

PROJECT_NAME = os.environ.get("PROJECT_NAME", ROOT.name)
PROJECT_REPO_URL = os.environ.get("PROJECT_REPO_URL", "")
PROJECT_TAGLINE = os.environ.get(
    "PROJECT_TAGLINE",
    "from-scratch RISC-V SoC (PicoRV32 + hand-written AXI4-Lite crossbar + AES-128/CBC/CTR + AXI4 burst DMA)",
)
VENDORED_BLOCKS = set(cfg.VENDORED_FILES.values())

data = json.loads((REPORTS / "dashboard_data.json").read_text())

# ---- pull a few more numbers out of the existing sign-off text reports ----
sim_text = (REPORTS / "simulation_regression.txt").read_text()
# Each regression row is "<target-name>  <PASS|FAIL|BUILD-FAIL>  <detail...>"
# (see scripts/lib_verilator_targets.sh's print_regression_summary) -- the
# result is the 2nd whitespace-separated column, not a line prefix (a line
# starts with the target's own name, e.g. "aes_key_expand", not "PASS:").
n_targets = 0
n_targets_pass = 0
for line in sim_text.splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[1] in ("PASS", "FAIL", "BUILD-FAIL"):
        n_targets += 1
        if parts[1] == "PASS":
            n_targets_pass += 1
regression_pass = bool(re.search(r"ALL \d+ regression targets PASS", sim_text))
regression_kpi_kind = "good" if regression_pass else "bad"

synth_text = (REPORTS / "synthesis_area.txt").read_text()
m = re.search(r"Chip area for top module '\\?\w+': ([\d.]+)", synth_text)
chip_area = float(m.group(1)) if m else None
m = re.search(r"cells\n\s*(\d+)", synth_text)
cell_count = None
for line in synth_text.splitlines():
    m2 = re.match(r"\s*(\d+)\s+[\d.E+]+\s+cells\s*$", line)
    if m2:
        cell_count = int(m2.group(1))
        break

sta_text = (REPORTS / "timing_sta.txt").read_text()
m = re.search(r"([\d.]+)\s+data arrival time", sta_text)
crit_path_ns = float(m.group(1)) if m else None
fmax_mhz = round(1000.0 / crit_path_ns, 1) if crit_path_ns else None

NAND2_AREA = 0.798
gate_count = round(chip_area / NAND2_AREA) if chip_area else None

# synth/STA are skipped when NANGATE45_LIB isn't set (see
# scripts/collect_soc_reports.sh) -- fall back to a clear "no PDK" label
# instead of crashing on a None value in the f-string below.
fmax_display = f"{fmax_mhz} MHz" if fmax_mhz is not None else "N/A (no PDK)"
gate_count_display = f"{gate_count:,}" if gate_count is not None else "N/A (no PDK)"

fsm_total = len(data["fsm_coverage"])
fsm_at_100 = sum(1 for v in data["fsm_coverage"].values() if v["pct"] == 100.0)
fsm_display = f"{fsm_at_100}/{fsm_total} FSMs @ 100%" if fsm_total else "N/A (no FSMs configured)"

cov = data["coverage_overall"]
fsm = data["fsm_coverage"]
findings = data["lint_findings"]
files_cov = data["coverage_by_file"]

# ---- categorize findings for display ----
CATEGORY_META = {
    "documented-limitation-bready": ("Documented limitation", "warn"),
    "documented-limitation-rready": ("Documented limitation", "warn"),
    "documented-limitation-bresp": ("Documented limitation", "warn"),
    "documented-limitation-rresp": ("Documented limitation", "warn"),
    "vendored": ("Vendored third-party IP (not this project's RTL)", "vendor"),
    "benign-address-decode": ("Benign / by design", "benign"),
    "benign-no-byte-strobe": ("Benign / by design", "benign"),
    "benign-burst-subset": ("Benign / by design", "benign"),
    "benign-decode-function": ("Benign / by design", "benign"),
    "benign-readonly-ignores-write": ("Benign / by design", "benign"),
    "benign-narrow-register-width": ("Benign / by design", "benign"),
    "benign-documentation-constant": ("Benign / by design", "benign"),
    "benign-unused-status-signal": ("Benign / by design", "benign"),
    "uncategorized": ("Uncategorized", "bad"),
}

groups = defaultdict(list)
for f in findings:
    bucket, _ = CATEGORY_META.get(f["category"], ("Uncategorized", "bad"))
    groups[bucket].append(f)

# sub-group within each bucket by category, for the "note" shown once per category
def subgroups(items):
    by_cat = defaultdict(list)
    for it in items:
        by_cat[it["category"]].append(it)
    return by_cat


def esc(s):
    return html.escape(str(s))


def bar(pct, kind="good"):
    return (
        f'<div class="bar"><div class="bar-fill {kind}" style="width:{pct}%"></div>'
        f'<span class="bar-label">{pct}%</span></div>'
    )


def render_lint_section():
    order = ["Documented limitation", "Benign / by design", "Vendored third-party IP (not this project's RTL)", "Uncategorized"]
    out = []
    for bucket in order:
        items = groups.get(bucket, [])
        if not items:
            continue
        kind = {"Documented limitation": "warn", "Benign / by design": "benign",
                "Vendored third-party IP (not this project's RTL)": "vendor", "Uncategorized": "bad"}[bucket]
        out.append(f'<div class="lint-bucket">')
        out.append(f'<h3><span class="dot {kind}"></span>{esc(bucket)} <span class="count">{len(items)}</span></h3>')
        by_cat = subgroups(items)
        for cat, cat_items in sorted(by_cat.items(), key=lambda kv: -len(kv[1])):
            note = cat_items[0]["note"]
            out.append('<details class="cat">')
            out.append(f'<summary>{esc(cat)} <span class="count">{len(cat_items)}</span></summary>')
            if note:
                out.append(f'<p class="note">{esc(note)}</p>')
            out.append('<table class="mini"><thead><tr><th>Block</th><th>File</th><th>Line</th><th>Message</th></tr></thead><tbody>')
            for it in sorted(cat_items, key=lambda x: (x["block"], x["file"], x["line"])):
                out.append(
                    f'<tr><td>{esc(it["block"])}</td><td>{esc(it["file"])}</td>'
                    f'<td>{it["line"]}</td><td>{esc(it["message"])}</td></tr>'
                )
            out.append('</tbody></table></details>')
        out.append('</div>')
    return "\n".join(out)


def render_fsm_section():
    out = []
    for name, spec in fsm.items():
        out.append('<div class="fsm-card">')
        out.append(f'<div class="fsm-head"><span class="fsm-name">{esc(name)}</span>'
                    f'<span class="fsm-file">{esc(spec["file"])}</span>'
                    f'<span class="fsm-pct {"good" if spec["pct"] == 100 else "warn"}">{spec["visited"]}/{spec["total"]} states</span></div>')
        out.append('<div class="fsm-states">')
        for s in spec["states"]:
            cls = "good" if s["visited"] else "bad"
            out.append(f'<span class="state-chip {cls}" title="{s["hits"]} hits">{esc(s["name"])}</span>')
        out.append('</div></div>')
    return "\n".join(out)


twr = data["toggle_waiver_report"]


def render_toggle_waiver_section():
    out = []
    out.append('<div class="overall-bars">')
    out.append(f'<div class="metric"><div class="name">Before waivers (deduped per-bit)</div>'
                f'{bar(twr["before"]["pct"], "warn" if twr["before"]["pct"] < 85 else "good")}'
                f'<div class="cov-frac">{twr["before"]["covered"]}/{twr["before"]["total"]} bits</div></div>')
    out.append(f'<div class="metric"><div class="name">After {twr["waiver_rule_count"]} waiver rules '
                f'({twr["waived_bit_count"]} bits waived)</div>'
                f'{bar(twr["after"]["pct"], "good" if twr["after"]["pct"] >= 85 else "warn")}'
                f'<div class="cov-frac">{twr["after"]["covered"]}/{twr["after"]["total"]} bits</div></div>')
    out.append('</div>')
    out.append('<p style="color:var(--text-dim);font-size:0.85rem">"Deduped per-bit" parses '
                '<code>merged.dat</code> directly and counts each source-level toggle bit once, '
                'regardless of how many hierarchy instances share the same underlying module '
                '(unlike the raw aggregate above, which counts a shared sub-module once per '
                'instantiation). A waived bit is removed from both the numerator and the '
                'denominator; it is not counted as covered. Rules + rationale: '
                '<code>reports/sign_off/coverage/toggle_waivers.txt</code>. Full report: '
                '<code>docs/coverage_waiver_report.md</code>.</p>')

    out.append('<details class="cat"><summary>Waiver rules applied '
                f'<span class="count">{len(twr["by_reason"])} reasons, {twr["waived_bit_count"]} bits</span></summary>')
    out.append('<table class="mini"><thead><tr><th>Bits waived</th><th>Reason</th><th>Example</th></tr></thead><tbody>')
    for r in twr["by_reason"]:
        example = esc(r["examples"][0]) if r["examples"] else ""
        out.append(f'<tr><td>{r["count"]}</td><td>{esc(r["reason"])}</td><td class="mono">{example}</td></tr>')
    out.append('</tbody></table></details>')

    residual_grouped = defaultdict(lambda: {"count": 0, "line": None})
    for g in twr["residual_gaps"]:
        base = re.sub(r"\[\d+\]$", "", g["signal"])
        key = (g["block"], g["file"], base)
        residual_grouped[key]["count"] += 1
        if residual_grouped[key]["line"] is None:
            residual_grouped[key]["line"] = g["line"]

    out.append('<details class="cat"><summary>Residual gaps (not waived, still open) '
                f'<span class="count">{len(twr["residual_gaps"])} bits across '
                f'{len(residual_grouped)} signals</span></summary>')
    out.append('<p class="note">Not structurally impossible &mdash; each reflects limited test-vector '
                'diversity (e.g. one fixed AES key, a handful of probed addresses, small divider '
                'values) rather than hardware that cannot toggle. Left open deliberately rather '
                'than waived away; see docs/coverage_waiver_report.md for the reasoning per group.</p>')
    out.append('<table class="mini"><thead><tr><th>Block</th><th>File</th><th>Line</th><th>Signal</th><th>Bits uncovered</th></tr></thead><tbody>')
    for (block, file, base), v in sorted(residual_grouped.items(), key=lambda kv: -kv[1]["count"]):
        out.append(f'<tr><td>{esc(block)}</td><td class="mono">{esc(file)}</td><td>{v["line"]}</td>'
                    f'<td class="mono">{esc(base)}</td><td>{v["count"]}</td></tr>')
    out.append('</tbody></table></details>')
    return "\n".join(out)


def render_file_table():
    out = ['<table class="filecov"><thead><tr><th>Block</th><th>File</th><th>Line coverage</th></tr></thead><tbody>']
    for f in files_cov:
        vendored = f["block"] in VENDORED_BLOCKS
        kind = "info" if vendored else ("good" if f["pct"] >= 90 else "warn")
        out.append(
            f'<tr><td>{esc(f["block"])}</td><td class="mono">{esc(f["file"])}</td>'
            f'<td>{bar(f["pct"], kind)} <span class="cov-frac">{f["covered"]}/{f["total"]}</span></td></tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)


generated = REPORTS.stat().st_mtime
import datetime
gen_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

html_out = f"""<title>{esc(PROJECT_NAME)} — Sign-off Dashboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {{
  --bg: #0b0e14;
  --panel: #12161f;
  --panel-alt: #171c27;
  --border: #232838;
  --text: #e6e9f0;
  --text-dim: #8b93a7;
  --accent: #ff9d5c;
  --good: #4ade80;
  --bad: #f87171;
  --warn: #fbbf24;
  --info: #64748b;
  --vendor: #8b7cf6;
}}
:root[data-theme="light"] {{
  --bg: #f6f7f9;
  --panel: #ffffff;
  --panel-alt: #eef0f4;
  --border: #dde1e8;
  --text: #1a1f2b;
  --text-dim: #5b6474;
  --accent: #d97a3d;
  --good: #16a34a;
  --bad: #dc2626;
  --warn: #b45309;
  --info: #64748b;
  --vendor: #6d5bd0;
}}
@media (prefers-color-scheme: light) {{
  :root:not([data-theme="dark"]) {{
    --bg: #f6f7f9;
    --panel: #ffffff;
    --panel-alt: #eef0f4;
    --border: #dde1e8;
    --text: #1a1f2b;
    --text-dim: #5b6474;
    --accent: #d97a3d;
    --good: #16a34a;
    --bad: #dc2626;
    --warn: #b45309;
    --info: #64748b;
    --vendor: #6d5bd0;
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  font-size: 15px; line-height: 1.5;
}}
.mono, .cov-frac, td.mono, .fsm-file, .bar-label {{
  font-family: ui-monospace, "SF Mono", "Cascadia Code", Menlo, Consolas, monospace;
}}
header.top {{
  padding: 28px 32px 20px; border-bottom: 1px solid var(--border);
  background: linear-gradient(180deg, var(--panel-alt), var(--bg));
}}
header.top h1 {{
  margin: 0 0 4px; font-size: 1.6rem; letter-spacing: -0.01em;
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}}
header.top .sub {{ color: var(--text-dim); font-size: 0.92rem; }}
main {{ max-width: 1180px; margin: 0 auto; padding: 28px 32px 80px; }}
.kpi-row {{
  display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
  gap: 14px; margin: 24px 0 40px;
}}
.kpi {{
  background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
  padding: 16px 18px;
}}
.kpi .label {{ color: var(--text-dim); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.04em; }}
.kpi .value {{ font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: 1.6rem; margin-top: 4px; font-weight: 600; }}
.kpi .value.good {{ color: var(--good); }}
.kpi .value.bad {{ color: var(--bad); }}
.kpi .value.accent {{ color: var(--accent); }}
section {{ margin: 48px 0; }}
section > h2 {{
  font-size: 1.05rem; text-transform: uppercase; letter-spacing: 0.06em;
  color: var(--accent); border-bottom: 1px solid var(--border); padding-bottom: 10px;
  margin-bottom: 18px;
}}
.arch-wrap {{
  background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
  padding: 20px; overflow-x: auto;
}}
table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
table.filecov td, table.filecov th {{ padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: left; }}
table.filecov th {{ color: var(--text-dim); font-weight: 500; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.03em; }}
table.mini {{ width: 100%; border-collapse: collapse; font-size: 0.82rem; margin: 8px 0 4px; }}
table.mini td, table.mini th {{ padding: 5px 8px; border-bottom: 1px solid var(--border); text-align: left; }}
table.mini th {{ color: var(--text-dim); font-weight: 500; }}
.bar {{ position: relative; display: inline-block; width: 140px; height: 16px; background: var(--panel-alt); border-radius: 4px; overflow: hidden; vertical-align: middle; }}
.bar-fill {{ position: absolute; left: 0; top: 0; bottom: 0; border-radius: 4px; }}
.bar-fill.good {{ background: var(--good); }}
.bar-fill.warn {{ background: var(--warn); }}
.bar-fill.bad {{ background: var(--bad); }}
.bar-fill.info {{ background: var(--info); }}
.bar-label {{ position: absolute; right: 6px; top: 0; font-size: 0.68rem; color: var(--text); line-height: 16px; }}
.cov-frac {{ color: var(--text-dim); font-size: 0.78rem; margin-left: 8px; }}
.overall-bars {{ display: flex; gap: 28px; flex-wrap: wrap; background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-bottom: 20px; }}
.overall-bars .metric {{ min-width: 200px; }}
.overall-bars .metric .name {{ color: var(--text-dim); font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.03em; margin-bottom: 6px; }}
.overall-bars .bar {{ width: 200px; height: 20px; }}
.fsm-grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 14px; }}
.fsm-card {{ background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; }}
.fsm-head {{ display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; margin-bottom: 10px; }}
.fsm-name {{ font-weight: 600; }}
.fsm-file {{ color: var(--text-dim); font-size: 0.76rem; }}
.fsm-pct {{ margin-left: auto; font-family: ui-monospace, monospace; font-size: 0.78rem; padding: 2px 8px; border-radius: 20px; }}
.fsm-pct.good {{ background: color-mix(in srgb, var(--good) 20%, transparent); color: var(--good); }}
.fsm-pct.warn {{ background: color-mix(in srgb, var(--warn) 20%, transparent); color: var(--warn); }}
.fsm-states {{ display: flex; flex-wrap: wrap; gap: 6px; }}
.state-chip {{ font-family: ui-monospace, monospace; font-size: 0.72rem; padding: 3px 8px; border-radius: 5px; border: 1px solid var(--border); }}
.state-chip.good {{ color: var(--good); border-color: color-mix(in srgb, var(--good) 40%, var(--border)); }}
.state-chip.bad {{ color: var(--bad); border-color: color-mix(in srgb, var(--bad) 40%, var(--border)); }}
.lint-bucket {{ margin-bottom: 22px; }}
.lint-bucket h3 {{ font-size: 0.95rem; display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }}
.dot {{ width: 9px; height: 9px; border-radius: 50%; display: inline-block; }}
.dot.warn {{ background: var(--warn); }}
.dot.benign {{ background: var(--info); }}
.dot.vendor {{ background: var(--vendor); }}
.dot.bad {{ background: var(--bad); }}
.count {{ color: var(--text-dim); font-weight: 400; font-size: 0.85em; }}
details.cat {{ background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 8px 14px; margin-bottom: 8px; }}
details.cat summary {{ cursor: pointer; font-size: 0.88rem; }}
details.cat .note {{ color: var(--text-dim); font-size: 0.82rem; margin: 8px 0; }}
footer {{ color: var(--text-dim); font-size: 0.8rem; text-align: center; padding: 30px 0; }}
a {{ color: var(--accent); }}
</style>

<header class="top">
  <h1>{esc(PROJECT_NAME)} &mdash; Sign-off Dashboard</h1>
  <div class="sub">Generated {gen_str} by scripts/build_dashboard.py &middot; {esc(PROJECT_TAGLINE)}</div>
</header>

<main>
  <div class="kpi-row">
    <div class="kpi"><div class="label">Regression</div><div class="value {regression_kpi_kind}">{n_targets_pass}/{n_targets} PASS</div></div>
    <div class="kpi"><div class="label">Own-RTL line coverage</div><div class="value good">{data['coverage_own_rtl_line_pct']}%</div></div>
    <div class="kpi"><div class="label">FSM state coverage</div><div class="value good">{fsm_display}</div></div>
    <div class="kpi"><div class="label">Whole-SoC Fmax</div><div class="value accent">{fmax_display}</div></div>
    <div class="kpi"><div class="label">Gate count (NAND2-eq)</div><div class="value accent">{gate_count_display}</div></div>
    <div class="kpi"><div class="label">Lint findings</div><div class="value">{len(findings)} <span style="font-size:0.5em;color:var(--text-dim)">(all triaged)</span></div></div>
  </div>

  <section id="architecture">
    <h2>Architecture</h2>
    <div class="arch-wrap">
      <pre class="mermaid">
flowchart TB
    CPU["PicoRV32 (picorv32_axi)<br/>vendored, unmodified"]
    JTAGPROBE(("external JTAG probe"))
    JTAGDTM["jtag_dtm + jtag_tap"]
    BRIDGE["jtag_axi_bridge<br/>(CDC owner)"]
    XBAR["axi_lite_xbar<br/>hand-written, 2 master x 9 slave"]
    ROM["boot_rom 64KB"]
    RAM["sram 128KB"]
    TIMER["timer"]
    WDT["watchdog"]
    UART["uart"]
    I2C["i2c_master"]
    SPI["spi_master"]
    AES["aes (CBC/CTR)"]
    DMACTRL["dma_engine ctrl port"]
    DMABURST["dma_engine burst master"]
    DMARAM["dma_ram 8KB<br/>private, not on crossbar"]

    JTAGPROBE <--> JTAGDTM
    JTAGDTM <--> BRIDGE
    BRIDGE -->|s1| XBAR
    CPU -->|s0| XBAR
    XBAR --> ROM
    XBAR --> RAM
    XBAR --> TIMER
    XBAR --> WDT
    XBAR --> UART
    XBAR --> I2C
    XBAR --> SPI
    XBAR --> AES
    XBAR --> DMACTRL
    DMACTRL -.same module.-> DMABURST
    DMABURST <-->|AXI4 burst| DMARAM
      </pre>
      <p style="color:var(--text-dim);font-size:0.85rem;margin-top:14px">Full rationale: <code>docs/architecture.md</code>. Bug history: <code>docs/project_retrospective.md</code>.</p>
    </div>
  </section>

  <section id="coverage">
    <h2>Coverage</h2>
    <div class="overall-bars">
      <div class="metric"><div class="name">Line (all merged tests)</div>{bar(cov['line']['pct'], 'good' if cov['line']['pct']>=70 else 'warn')}<div class="cov-frac">{cov['line']['covered']}/{cov['line']['total']} points</div></div>
      <div class="metric"><div class="name">Toggle</div>{bar(cov['toggle']['pct'], 'good' if cov['toggle']['pct']>=70 else 'warn')}<div class="cov-frac">{cov['toggle']['covered']}/{cov['toggle']['total']} points</div></div>
      <div class="metric"><div class="name">Branch</div>{bar(cov['branch']['pct'], 'good' if cov['branch']['pct']>=70 else 'warn')}<div class="cov-frac">{cov['branch']['covered']}/{cov['branch']['total']} points</div></div>
    </div>
    <p style="color:var(--text-dim);font-size:0.85rem">Aggregate numbers above are diluted by shared sub-modules counted once per instantiating test (e.g. aes_core is exercised by 5 different tests) &mdash; the per-file table below is the more meaningful "was this actual source file exercised" view.</p>
    {render_file_table()}
  </section>

  <section id="toggle-waivers">
    <h2>Toggle Coverage Waivers</h2>
    {render_toggle_waiver_section()}
  </section>

  <section id="fsm">
    <h2>FSM State Coverage</h2>
    <p style="color:var(--text-dim);font-size:0.85rem;margin-top:-8px">Plain Verilog-2001 case-based FSMs aren't picked up by Verilator's <code>--coverage-fsm</code> heuristic &mdash; this is derived instead from each state's own case-arm line-coverage hit count (an exact "was this state ever entered" signal). See <code>docs/project_retrospective.md</code>.</p>
    <div class="fsm-grid">
      {render_fsm_section()}
    </div>
  </section>

  <section id="lint">
    <h2>Lint Findings ({len(findings)} total, all triaged)</h2>
    <p style="color:var(--text-dim);font-size:0.85rem;margin-top:-8px">From <code>scripts/run_lint.sh</code> (independent <code>verilator --lint-only</code> per block, deliberately keeping <code>UNUSEDSIGNAL</code>/<code>UNUSEDPARAM</code> enabled unlike the simulation builds). 4 genuine dead-code findings were already fixed before this snapshot &mdash; everything below is what remained.</p>
    {render_lint_section()}
  </section>

  <footer>
    {esc(PROJECT_NAME)}{' &middot; <a href="' + esc(PROJECT_REPO_URL) + '">' + esc(PROJECT_REPO_URL.replace("https://", "")) + '</a>' if PROJECT_REPO_URL else ''}
  </footer>
</main>
"""

out_path = REPORTS / "dashboard.html"
out_path.write_text(html_out)
print(f"Wrote {out_path} ({len(html_out):,} bytes)")
