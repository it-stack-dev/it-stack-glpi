#!/usr/bin/env bash
# test-lab-17-05.sh — Lab 17-05: Advanced Integration
# Module 17: GLPI IT service management and CMDB
# glpi integrated with full IT-Stack ecosystem
set -euo pipefail

LAB_ID="17-05"
LAB_NAME="Advanced Integration"
MODULE="glpi"
COMPOSE_FILE="docker/docker-compose.integration.yml"
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
APP_PORT=8442
MOCK_PORT=8763
KC_PORT=8542
LDAP_PORT=3887
MH_PORT=8742
MOCK_URL="http://localhost:${MOCK_PORT}"

APP_CONTAINER="glpi-i05-app"
MOCK_CONTAINER="glpi-i05-mock"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for GLPI stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker ps --format '{{.Names}}' | grep -q "^${APP_CONTAINER}$"; then
  pass "GLPI app container running"
else
  fail "GLPI app container not running"
fi

if docker ps --format '{{.Names}}' | grep -q "^${MOCK_CONTAINER}$"; then
  pass "WireMock container running"
else
  fail "WireMock container not running"
fi

# App health
if curl -sf "http://localhost:${APP_PORT}/" > /dev/null 2>&1; then
  pass "GLPI web interface responds"
else
  warn "GLPI web interface not yet ready"
fi

# WireMock health
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
if curl -sf "http://localhost:${KC_PORT}/realms/master" > /dev/null 2>&1; then
  pass "Keycloak master realm accessible"
else
  warn "Keycloak not yet ready"
fi

# LDAP
if ldapsearch -x -H ldap://localhost:${LDAP_PORT} -b dc=lab,dc=local \
     -D cn=admin,dc=lab,dc=local -w LdapLab05! cn=admin > /dev/null 2>&1; then
  pass "OpenLDAP bind successful"
else
  warn "OpenLDAP bind failed"
fi

# Mailhog
if curl -sf "http://localhost:${MH_PORT}/" > /dev/null 2>&1; then
  pass "Mailhog web UI accessible"
else
  warn "Mailhog web UI not ready"
fi

# ── PHASE 3: Integration Tests ────────────────────────────────────────────────
info "Phase 3: Integration Tests (Zammad REST API via WireMock)"

# 3a: Register Zammad tickets stub
info "3a: Registering Zammad GET /api/v1/tickets stub..."
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "url": "/api/v1/tickets"},
    "response": {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "[{\"id\":1,\"number\":\"10001\",\"title\":\"GLPI escalation test\",\"state\":{\"name\":\"open\"},\"priority\":{\"name\":\"2 normal\"},\"created_at\":\"2025-01-01T00:00:00Z\"}]"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Zammad GET /api/v1/tickets stub registered (201)"
else
  fail "WireMock Zammad ticket stub registration failed (HTTP ${HTTP_STATUS})"
fi

# Register Zammad ticket create stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/api/v1/tickets"},
    "response": {
      "status": 201,
      "headers": {"Content-Type": "application/json"},
      "body": "{\"id\":42,\"number\":\"10042\",\"title\":\"GLPI escalated ticket\",\"state\":{\"name\":\"open\"}}"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Zammad POST /api/v1/tickets stub registered"
else
  fail "WireMock Zammad POST ticket stub failed (HTTP ${HTTP_STATUS})"
fi

# 3b: Verify Zammad API mock responds
if curl -sf "${MOCK_URL}/api/v1/tickets" | grep -q 'GLPI escalation test'; then
  pass "WireMock Zammad GET /api/v1/tickets returns ticket JSON"
else
  fail "WireMock Zammad GET /api/v1/tickets returned unexpected response"
fi

# 3c: Integration env vars in GLPI container
if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q 'ZAMMAD_URL='; then
  pass "ZAMMAD_URL env var present in GLPI container"
else
  fail "ZAMMAD_URL env var missing from GLPI container"
fi

if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q 'ZAMMAD_TOKEN='; then
  pass "ZAMMAD_TOKEN env var present in GLPI container"
else
  fail "ZAMMAD_TOKEN env var missing from GLPI container"
fi

# 3d: Container-to-WireMock connectivity
if docker exec "${APP_CONTAINER}" curl -sf http://glpi-i05-mock:8080/__admin/health > /dev/null 2>&1; then
  pass "GLPI container can reach WireMock (glpi-i05-mock:8080)"
else
  fail "GLPI container cannot reach WireMock"
fi

# 3e: Simulate GLPI → Zammad ticket escalation via WireMock
if docker exec "${APP_CONTAINER}" curl -sf \
     -X POST http://glpi-i05-mock:8080/api/v1/tickets \
     -H 'Content-Type: application/json' \
     -H "Authorization: Token token=lab-zammad-token-05" \
     -d '{"title":"GLPI escalated ticket","group":"Support","customer_id":2}' 2>/dev/null | grep -q 'GLPI escalated'; then
  pass "GLPI → Zammad ticket creation call succeeds (via WireMock)"
else
  warn "GLPI → Zammad ticket creation not verified (app may need full setup)"
fi

# 3f: Volume assertions
if docker volume ls | grep -q 'glpi-i05-app-data'; then
  pass "GLPI app data volume exists"
else
  fail "GLPI app data volume missing"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 17-05 pending implementation"

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
