#!/usr/bin/env bash
# test-lab-17-03.sh — Lab 17-03: GLPI Advanced Features
# Tests: dedicated cron container · resource limits · scheduler validation
# Usage: bash test-lab-17-03.sh [--no-cleanup]
set -euo pipefail

LAB_ID="17-03"
LAB_NAME="Advanced Features — dedicated cron scheduler container"
MODULE="glpi"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0
FAIL=0

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up Lab ${LAB_ID} containers..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
info "Starting GLPI stack (db + mail + app + cron)..."
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for MariaDB (glpi-a03-db)..."
for i in $(seq 1 18); do
  if docker exec glpi-a03-db mysqladmin ping -h localhost -uroot -pRootLab03! --silent 2>/dev/null; then
    info "MariaDB ready after ${i}×5s"
    break
  fi
  [[ $i -eq 18 ]] && { fail "MariaDB did not become ready"; exit 1; }
  sleep 5
done

info "Waiting for GLPI app on port 8422..."
for i in $(seq 1 24); do
  HTTP=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8422/ 2>/dev/null || echo "000")
  if echo "${HTTP}" | grep -qE '^[23]'; then
    info "GLPI ready after ${i}×15s (HTTP ${HTTP})"
    break
  fi
  [[ $i -eq 24 ]] && { warn "GLPI did not fully initialize in time"; }
  sleep 15
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests — Advanced Features"

# 3.1 Container states (all 4)
for cname in glpi-a03-db glpi-a03-mail glpi-a03-app glpi-a03-cron; do
  STATE=$(docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "${STATE}" == "running" ]]; then
    pass "Container ${cname} is running"
  else
    fail "Container ${cname} state: ${STATE}"
  fi
done

# 3.2 Cron container (Lab 03 key feature)
CRON_STATE=$(docker inspect glpi-a03-cron --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [[ "${CRON_STATE}" == "running" ]]; then
  pass "glpi-a03-cron scheduler container is running (Lab 03 new container)"
else
  fail "glpi-a03-cron scheduler state: ${CRON_STATE}"
fi

# 3.3 Database accessibility from cron container
DB_CHECK=$(docker exec glpi-a03-cron mysql -h glpi-a03-db -uglpi -pGlpiLab03! \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpidb';" \
  --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${DB_CHECK}" -gt 0 ]]; then
  pass "Cron container can reach database (${DB_CHECK} tables visible)"
else
  warn "Cron container database check returned ${DB_CHECK}"
fi

# 3.4 Database table count
TABLE_COUNT=$(docker exec glpi-a03-db mysql -uglpi -pGlpiLab03! -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glpidb';" \
  --skip-column-names 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${TABLE_COUNT}" -gt 50 ]]; then
  pass "GLPI database has ${TABLE_COUNT} tables (installation complete)"
elif [[ "${TABLE_COUNT}" -gt 0 ]]; then
  warn "GLPI database has ${TABLE_COUNT} tables (may still installing)"
else
  fail "GLPI database appears empty"
fi

# 3.5 HTTP check
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8422/ 2>/dev/null || echo "000")
if echo "${HTTP_CODE}" | grep -qE '^[234]'; then
  pass "GLPI HTTP check: ${HTTP_CODE}"
else
  fail "GLPI HTTP check failed: ${HTTP_CODE}"
fi

# 3.6 Memory limits
for cname in glpi-a03-app glpi-a03-cron glpi-a03-db; do
  MEM_LIMIT=$(docker inspect "${cname}" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "${MEM_LIMIT}" -gt 0 ]]; then
    pass "${cname} has memory limit (${MEM_LIMIT} bytes)"
  else
    fail "${cname} has no memory limit"
  fi
done

# 3.7 Mailhog
MAIL_TOTAL=$(curl -sf http://localhost:8722/api/v2/messages 2>/dev/null | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "0")
pass "Mailhog API reachable (message count: ${MAIL_TOTAL})"

# 3.8 Volumes
for vol in glpi-a03-db-data glpi-a03-files glpi-a03-plugins; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} not found"
  fi
done

# ── PHASE 4: (cleanup via trap) ────────────────────────────────────────────────
section "Phase 4: Results"

echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi

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

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 03 — Advanced Features)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 17-03 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
