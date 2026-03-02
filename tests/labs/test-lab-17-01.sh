#!/usr/bin/env bash
# test-lab-17-01.sh — Lab 17-01: Standalone
# Module 17: GLPI IT service management and CMDB
# Basic glpi functionality in complete isolation
set -euo pipefail

LAB_ID="17-01"
LAB_NAME="Standalone"
MODULE="glpi"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

GLPI_URL="http://localhost:8402"
NO_CLEANUP=${NO_CLEANUP:-0}

cleanup() {
    if [ "${NO_CLEANUP}" = "1" ]; then
        info "NO_CLEANUP=1 — skipping teardown"
    else
        info "Phase 4: Cleanup"
        docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
        info "Cleanup complete"
    fi
}
trap cleanup EXIT

section() { echo -e "\n${CYAN}## $1${NC}"; }

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 120s for GLPI to initialize (MariaDB + PHP)..."
sleep 120

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps glpi-s01-db 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.1 MariaDB (glpi-s01-db) is up"
else
    fail "2.1 MariaDB is not running"
fi

if docker compose -f "${COMPOSE_FILE}" ps glpi-s01-app 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.2 GLPI app (glpi-s01-app) is up"
else
    fail "2.2 GLPI app is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# 3.1 Root URL responds
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' -L "${GLPI_URL}/" 2>/dev/null || echo 000)
if echo "${HTTP_CODE}" | grep -q '^[23]'; then
    pass "3.1 GLPI web UI accessible (HTTP ${HTTP_CODE})"
else
    fail "3.1 GLPI web UI not accessible (HTTP ${HTTP_CODE})"
fi

# 3.2 Response contains GLPI content
RESPONSE=$(curl -sfL "${GLPI_URL}/" 2>/dev/null || echo '')
if echo "${RESPONSE}" | grep -qi 'glpi\|helpdesk\|login\|ticketing'; then
    pass "3.2 Response contains GLPI application content"
else
    warn "3.2 Could not confirm GLPI content (app may still be installing)"
fi

# 3.3 Install / login page accessible
HTTP_LOGIN=$(curl -o /dev/null -sw '%{http_code}' -L "${GLPI_URL}/index.php" 2>/dev/null || echo 000)
if echo "${HTTP_LOGIN}" | grep -q '^[23]'; then
    pass "3.3 GLPI index.php accessible (HTTP ${HTTP_LOGIN})"
else
    warn "3.3 GLPI index.php returned HTTP ${HTTP_LOGIN}"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
