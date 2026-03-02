#!/usr/bin/env bash
# test-lab-17-06.sh — Lab 17-06: Production Deployment
# Module 17: GLPI IT service management and CMDB
# glpi in production-grade HA configuration with monitoring
set -euo pipefail

LAB_ID="17-06"
LAB_NAME="Production Deployment"
MODULE="glpi"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

# ── Colors ─────────────────────────────────────────────────────────────────────
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

# ── PHASE 1: Setup ─────────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 75s for ${MODULE} production stack to initialize..."
sleep 75

# ── PHASE 2: Health Checks ─────────────────────────────────────────────────────────
info "Phase 2: Container Health Checks"

for svc in glpi-p06-db glpi-p06-ldap glpi-p06-kc glpi-p06-mail glpi-p06-app glpi-p06-cron; do
  if docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null | grep -q running; then
    pass "$svc is running"
  else
    fail "$svc is NOT running"
  fi
done

# DB check
if docker exec glpi-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MariaDB is ready"
else
  fail "MariaDB not ready"
fi

# KC check
if curl -sf http://localhost:8562/realms/master | grep -q realm; then
  pass "Keycloak accessible on port 8562"
else
  fail "Keycloak not accessible on port 8562"
fi

# App check
if curl -sf http://localhost:8462/ | grep -q -i 'glpi\|html'; then
  pass "GLPI accessible on port 8462"
else
  fail "GLPI not accessible on port 8462"
fi

# ── PHASE 3: Production Checks ───────────────────────────────────────────────────
info "Phase 3a: Compose config validation"
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Production compose config is valid"
else
  fail "Production compose config validation failed"
fi

info "Phase 3b: Resource limits applied"
MEM=$(docker inspect --format '{{.HostConfig.Memory}}' glpi-p06-app 2>/dev/null || echo 0)
if [ "${MEM}" -gt 0 ] 2>/dev/null; then
  pass "Resource memory limit applied on glpi-p06-app (${MEM} bytes)"
else
  fail "No memory limit found on glpi-p06-app"
fi

info "Phase 3c: Restart policy check"
POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' glpi-p06-app 2>/dev/null || echo none)
if [ "${POLICY}" = "unless-stopped" ]; then
  pass "Restart policy is unless-stopped on glpi-p06-app"
else
  fail "Restart policy is '${POLICY}' (expected unless-stopped)"
fi

info "Phase 3d: Production environment variables"
IT_ENV=$(docker exec glpi-p06-app env 2>/dev/null | grep IT_STACK_ENV= | cut -d= -f2 || echo "")
if [ "${IT_ENV}" = "production" ]; then
  pass "IT_STACK_ENV=production set on glpi-p06-app"
else
  fail "IT_STACK_ENV not set to production (got: ${IT_ENV})"
fi

if docker exec glpi-p06-app env 2>/dev/null | grep -q KEYCLOAK_URL; then
  pass "KEYCLOAK_URL set on glpi-p06-app"
else
  fail "KEYCLOAK_URL not set"
fi

info "Phase 3e: MySQL database backup test"
if docker exec glpi-p06-db mysqldump -uroot -pRootProd06! glpi > /dev/null 2>&1; then
  pass "mysqldump backup of glpi database succeeded"
else
  fail "mysqldump backup failed"
fi

info "Phase 3f: LDAP bind and search test"
if docker exec glpi-p06-ldap ldapsearch -x -H ldap://localhost \
  -b dc=lab,dc=local -D cn=admin,dc=lab,dc=local -w LdapProd06! \
  cn=admin > /dev/null 2>&1; then
  pass "LDAP bind and search successful"
else
  fail "LDAP bind or search failed"
fi

info "Phase 3g: Keycloak admin API token acquisition"
KC_TOKEN=$(curl -sf -X POST http://localhost:8562/realms/master/protocol/openid-connect/token \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin API token acquired"
else
  fail "Failed to acquire Keycloak admin API token"
fi

info "Phase 3h: GLPI cron container running"
if docker inspect --format '{{.State.Status}}' glpi-p06-cron 2>/dev/null | grep -q running; then
  pass "GLPI cron container is running"
else
  fail "GLPI cron container is NOT running"
fi

info "Phase 3i: DB restart resilience test"
docker restart glpi-p06-db > /dev/null 2>&1
info "Waiting 20s for MariaDB to recover..."
sleep 20
if docker exec glpi-p06-db mysqladmin ping -uroot -pRootProd06! --silent 2>/dev/null; then
  pass "MariaDB recovered after container restart"
else
  fail "MariaDB did NOT recover after container restart"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
if [ "${CLEANUP}" = true ]; then
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
  info "Cleanup complete"
else
  warn "Cleanup skipped (--no-cleanup flag set)"
fi

# ── Results ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
set -euo pipefail

LAB_ID="17-06"
LAB_NAME="Production Deployment"
MODULE="glpi"
COMPOSE_FILE="docker/docker-compose.production.yml"
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
info "Phase 3: Functional Tests (Lab 06 — Production Deployment)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 17-06 pending implementation"

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
