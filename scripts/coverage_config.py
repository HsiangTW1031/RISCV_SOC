"""Project-specific knowledge for scripts/analyze_coverage.py: which real
FSMs exist and what their states are called, how to explain away known
lint findings, and which vendored/generated files need special block
attribution. Everything else in analyze_coverage.py is generic (it
auto-discovers which .v/.vh file belongs to which block by scanning
blocks/*/rtl/, so a new project's own coverage_config.py can start empty
and grow one entry at a time as real FSMs/lint findings get triaged --
an unmatched lint finding just falls into "uncategorized", it doesn't
error out.
"""

# ---- FSM state tables (state name -> as it appears as "NAME: begin" or
# "NAME:" in the case statement), one entry per module that has a real FSM.
# Plain down-counters (no case-based state machine) are intentionally
# excluded -- not every sequential block is an FSM.
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

# Manual triage of lint findings that recur across the project, keyed by a
# regex over the Verilator warning message. The first matching rule wins;
# anything unmatched (and not vendored -- see VENDORED_FILES below) is
# reported as "uncategorized" rather than erroring out, so a new project
# can start this list empty and fill it in as real findings get reviewed.
CATEGORY_RULES = [
    (r"Bits of signal are not used: 's_(aw|ar)addr'", "benign-address-decode",
     "Upper address bits unused -- the crossbar already decodes/routes before presenting to this slave; only the local register-offset bits matter here."),
    (r"Signal is not used: 's_wstrb'", "benign-no-byte-strobe",
     "Byte-strobe writes aren't supported on control/status registers -- every register here is written as a full 32-bit word in practice."),
    (r"Signal is not used: 's_bready'", "documented-limitation-bready",
     "AXI response channel doesn't check BREADY before dropping BVALID -- works correctly against this project's own crossbar timing, not strictly AXI4-compliant in general. Documented in docs/architecture.md."),
    (r"Signal is not used: 's_rready'", "documented-limitation-rready",
     "AXI response channel doesn't check RREADY before dropping RVALID -- same as the BREADY case above."),
    (r"Signal is not used: 'm_bresp'", "documented-limitation-bresp",
     "dma_engine's own burst master doesn't check dma_ram's write response code -- same class of limitation as picorv32_axi not checking BRESP/RRESP."),
    (r"Signal is not used: 'm_rresp'", "documented-limitation-rresp",
     "dma_engine's own burst master doesn't check dma_ram's read response code."),
    (r"Signal is not used: 's_(aw|ar)(size|burst)'", "benign-burst-subset",
     "This project's AXI4 burst subset is INCR-only, fixed 4-byte beats (see rtl/include/axi4.vh) -- these fields are assumed constant by convention, not read at runtime."),
    (r"Bits of function variable are not used: 'addr'", "benign-decode-function",
     "The crossbar's decode_addr() function only inspects the specific bit ranges needed for region/peripheral selection."),
    (r"Signal is not used: 's_awaddr'$|Signal is not used: 's_wdata'$", "benign-readonly-ignores-write",
     "boot_rom is read-only (writes are rejected with SLVERR) -- it never needs the write address or data at all, not even partially."),
    (r"Bits of signal are not used: 's_wdata'\[31:8\]", "benign-narrow-register-width",
     "TXDATA is an 8-bit register (one UART byte) -- the upper 24 bits of a 32-bit AXI word are never meaningful here."),
    (r"Parameter is not used: 'MODE_ECB'", "benign-documentation-constant",
     "MODE_ECB documents aes_chain's mode encoding for aes.v's register interface; ECB itself is handled as the implicit default (not CBC, not CTR), so the constant is never directly compared."),
    (r"Signal is not used: '(core|chain)_busy'", "benign-unused-status-signal",
     "A busy/done status wire from the instantiated sub-block; the consuming FSM only needs the done pulse (busy is informational only, safe to leave unread)."),
]

# Files that are vendored third-party IP (not this project's own RTL) --
# reported as their own pseudo-block in the coverage/lint tables instead of
# whatever blocks/<name> physically contains them, and any lint finding in
# them is auto-categorized as "vendored" without needing a CATEGORY_RULES
# entry. Empty by default; add an entry when a project vendors an IP.
VENDORED_FILES = {
    "picorv32.v": "picorv32 (vendored)",
}

# Substrings matched against merged.dat's recorded file path: toggle points
# in vendored IP or test-only harnesses are excluded from this project's
# own toggle coverage numbers. Derived from VENDORED_FILES plus generic
# testbench-file naming conventions (a "testtop.v" top or a "fake_*"
# bus-functional stand-in is never real deliverable RTL).
TOGGLE_EXCLUDE_PATH_SUBSTR = list(VENDORED_FILES.keys()) + ["testtop.v", "fake_"]
