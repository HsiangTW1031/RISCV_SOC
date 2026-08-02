# Project-level settings sourced by scripts/collect_soc_reports.sh,
# scripts/reproduce_all.sh, scripts/build_dashboard.py (via env vars) and
# scripts/build_firmware.sh. This is the one file a new project (or a copy
# of this skeleton) needs to edit -- nothing else in scripts/ should have
# a project name or block name hardcoded.
PROJECT_NAME="RISCV_SOC"
PROJECT_REPO_URL="https://github.com/HsiangTW1031/RISCV_SOC"

# Which blocks/<name> is the whole-chip top level -- this is what
# scripts/collect_soc_reports.sh synthesizes/STAs as "the whole design",
# and what scripts/build_firmware.sh copies firmware.hex into (for
# projects with an embedded CPU).
TOP_BLOCK="soc_top"
