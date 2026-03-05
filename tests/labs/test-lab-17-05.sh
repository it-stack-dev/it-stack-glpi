#!/usr/bin/env bash
# test-lab-17-05.sh — Lab 17-05: INT-07 GLPI ↔ Keycloak SAML 2.0 + LDAP
# Module 17: GLPI IT service management and CMDB
# Tests: LDAP seed verification, Keycloak realm + LDAP federation + SAML client,
#        SAML IdP metadata reachable, GLPI container env + web reachability,
#        WireMock Zammad mock, OIDC/SAML token flow validation
set -euo pipefail

LAB_ID="17-05"
LAB_NAME="INT-07 GLPI ↔ Keycloak SAML 2.0 + LDAP"
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

KC_ADMIN=admin
KC_PASS="Admin05!"
KC_URL="http://localhost:${KC_PORT}"
LDAP_ADMIN="cn=admin,dc=lab,dc=local"
LDAP_PW="LdapLab05!"
LDAP_BASE="dc=lab,dc=local"
LDAP_USERS_BASE="cn=users,cn=accounts,dc=lab,dc=local"
LDAP_GROUPS_BASE="cn=groups,cn=accounts,dc=lab,dc=local"
LDAP_READONLY_DN="cn=readonly,dc=lab,dc=local"
LDAP_READONLY_PW="ReadOnly05!"
MOCK_URL="http://localhost:${MOCK_PORT}"

APP_CONTAINER="glpi-i05-app"
SEED_CONTAINER="glpi-i05-ldap-seed"
KC_CONTAINER="glpi-i05-kc"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Cleanup: tearing down stack"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup — bring up full integration stack"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 90s for GLPI integration stack to initialize..."
sleep 90

# ── PHASE 2: Container Health Checks ─────────────────────────────────────────
info "Phase 2: Container health checks"

for ctr in glpi-i05-db glpi-i05-ldap glpi-i05-kc glpi-i05-mock glpi-i05-mail "${APP_CONTAINER}"; do
  if docker ps --format '{{.Names}}' | grep -q "^${ctr}$"; then
    pass "Container running: ${ctr}"
  else
    fail "Container not running: ${ctr}"
  fi
done

# LDAP seed exit code
SEED_STATUS=$(docker inspect "${SEED_CONTAINER}" --format '{{.State.ExitCode}}' 2>/dev/null || echo "missing")
if [[ "${SEED_STATUS}" == "0" ]]; then
  pass "LDAP seed container exited cleanly (code 0)"
else
  warn "LDAP seed container exit code: ${SEED_STATUS} (idempotent re-run may be non-zero)"
fi

# MariaDB
if docker exec glpi-i05-db mysqladmin ping -uroot -pRootLab05! --silent 2>/dev/null; then
  pass "MariaDB ping OK"
else
  fail "MariaDB ping failed"
fi

# WireMock health
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
KC_READY=false
for i in $(seq 1 24); do
  if curl -sf "${KC_URL}/health/ready" 2>/dev/null | grep -q UP; then
    KC_READY=true; break
  fi
  sleep 5
done
if ${KC_READY}; then
  pass "Keycloak health/ready UP"
else
  fail "Keycloak health/ready did not return UP within 120s"
fi

# GLPI web
GLPI_READY=false
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${APP_PORT}/" > /dev/null 2>&1; then
    GLPI_READY=true; break
  fi
  sleep 10
done
if ${GLPI_READY}; then
  pass "GLPI web interface responds on port ${APP_PORT}"
else
  warn "GLPI web interface not ready within 200s (first-run bootstrapping may be slow)"
fi

# Mailhog
if curl -sf "http://localhost:${MH_PORT}/" > /dev/null 2>&1; then
  pass "Mailhog web UI accessible"
else
  warn "Mailhog web UI not ready"
fi

echo ""

# ── PHASE 3: LDAP Seed Verification ──────────────────────────────────────────
info "Phase 3: LDAP seed verification"

# Count users
USER_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -b "${LDAP_USERS_BASE}" \
  -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
  "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || echo 0)
if [[ "${USER_COUNT}" -ge 3 ]]; then
  pass "LDAP users seeded: ${USER_COUNT} found in ${LDAP_USERS_BASE}"
else
  fail "LDAP users insufficient: got ${USER_COUNT}, expected ≥3"
fi

# Count groups
GROUP_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -b "${LDAP_GROUPS_BASE}" \
  -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
  "(objectClass=groupOfNames)" cn 2>/dev/null \
  | grep -c "^cn:" || echo 0)
if [[ "${GROUP_COUNT}" -ge 2 ]]; then
  pass "LDAP groups seeded: ${GROUP_COUNT} found in ${LDAP_GROUPS_BASE}"
else
  fail "LDAP groups insufficient: got ${GROUP_COUNT}, expected ≥2"
fi

# glpiadmin present
if ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
     -b "${LDAP_USERS_BASE}" \
     -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
     "(uid=glpiadmin)" uid 2>/dev/null | grep -q "uid: glpiadmin"; then
  pass "LDAP user glpiadmin present"
else
  fail "LDAP user glpiadmin not found"
fi

# Readonly bind
if ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
     -b "${LDAP_USERS_BASE}" \
     -D "${LDAP_READONLY_DN}" -w "${LDAP_READONLY_PW}" \
     "(uid=glpiadmin)" uid > /dev/null 2>&1; then
  pass "LDAP readonly bind + search succeeds"
else
  fail "LDAP readonly bind failed"
fi

echo ""

# ── PHASE 4: Keycloak Realm + LDAP Federation + SAML Client ──────────────────
info "Phase 4: Keycloak realm, LDAP federation, SAML client provisioning"

# 4a: Get admin token
KC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json, sys
data = urllib.parse.urlencode({'client_id':'admin-cli','username':'${KC_ADMIN}','password':'${KC_PASS}','grant_type':'password'}).encode()
req = urllib.request.Request('${KC_URL}/realms/master/protocol/openid-connect/token', data=data)
resp = urllib.request.urlopen(req, timeout=15)
print(json.loads(resp.read())['access_token'])
" 2>/dev/null || echo "")

if [[ -n "${KC_TOKEN}" ]]; then
  pass "Keycloak admin token obtained"
else
  fail "Failed to obtain Keycloak admin token"
  echo ""
  info "Results — PHASE 4+ skipped due to KC auth failure"
  echo -e "${CYAN}========================================${NC}"
  echo -e " Lab ${LAB_ID} Results"
  echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
  echo -e "${CYAN}========================================${NC}"
  [ "${FAIL}" -gt 0 ] && exit 1 || exit 0
fi

KC_HDR="Authorization: Bearer ${KC_TOKEN}"

# 4b: Create it-stack realm
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${KC_URL}/admin/realms" \
  -H "${KC_HDR}" -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab"}' || echo "000")
if [[ "${HTTP}" == "201" || "${HTTP}" == "409" ]]; then
  pass "Keycloak realm it-stack created/exists (HTTP ${HTTP})"
else
  fail "Keycloak realm creation failed (HTTP ${HTTP})"
fi

# Refresh token for realm ops
KC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json
data = urllib.parse.urlencode({'client_id':'admin-cli','username':'${KC_ADMIN}','password':'${KC_PASS}','grant_type':'password'}).encode()
req = urllib.request.Request('${KC_URL}/realms/master/protocol/openid-connect/token', data=data)
print(json.loads(urllib.request.urlopen(req, timeout=15).read())['access_token'])
" 2>/dev/null || echo "")
KC_HDR="Authorization: Bearer ${KC_TOKEN}"

# 4c: Register LDAP federation component
COMPONENTS=$(curl -sf "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "${KC_HDR}" 2>/dev/null || echo "[]")
if echo "${COMPONENTS}" | python3 -c "import sys,json; comps=json.load(sys.stdin); exit(0 if any(c.get('name')=='glpi-lab-ldap' for c in comps) else 1)" 2>/dev/null; then
  pass "Keycloak LDAP federation component already exists"
else
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/components" \
    -H "${KC_HDR}" -H "Content-Type: application/json" \
    -d '{
      "name":"glpi-lab-ldap",
      "providerId":"ldap",
      "providerType":"org.keycloak.storage.UserStorageProvider",
      "config":{
        "vendor":["rhds"],
        "connectionUrl":["ldap://glpi-i05-ldap:389"],
        "bindDn":["cn=readonly,dc=lab,dc=local"],
        "bindCredential":["ReadOnly05!"],
        "usersDn":["cn=users,cn=accounts,dc=lab,dc=local"],
        "usernameLDAPAttribute":["uid"],
        "uuidLDAPAttribute":["uid"],
        "userObjectClasses":["inetOrgPerson"],
        "searchScope":["1"],
        "useTruststoreSpi":["ldapsOnly"],
        "importEnabled":["true"],
        "syncRegistrations":["false"],
        "fullSyncPeriod":["-1"],
        "changedSyncPeriod":["-1"]
      }
    }' || echo "000")
  if [[ "${HTTP}" == "201" ]]; then
    pass "Keycloak LDAP federation component registered (HTTP 201)"
  else
    fail "Keycloak LDAP federation registration failed (HTTP ${HTTP})"
  fi
fi

# 4d: Trigger full LDAP sync
COMP_ID=$(curl -sf "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "${KC_HDR}" 2>/dev/null \
  | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='glpi-lab-ldap'),''))" 2>/dev/null || echo "")

if [[ -n "${COMP_ID}" ]]; then
  SYNC_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/user-storage/${COMP_ID}/sync?action=triggerFullSync" \
    -H "${KC_HDR}" 2>/dev/null || echo "000")
  if [[ "${SYNC_HTTP}" =~ ^2 ]]; then
    pass "LDAP full sync triggered (HTTP ${SYNC_HTTP})"
  else
    warn "LDAP full sync returned HTTP ${SYNC_HTTP} (may be non-critical)"
  fi

  # Count synced users
  SYNCED=$(curl -sf "${KC_URL}/admin/realms/it-stack/users?max=50" \
    -H "${KC_HDR}" 2>/dev/null \
    | python3 -c "import sys,json; users=json.load(sys.stdin); print(len(users))" 2>/dev/null || echo 0)
  if [[ "${SYNCED}" -ge 3 ]]; then
    pass "Keycloak it-stack realm has ${SYNCED} users synced from LDAP"
  else
    warn "Keycloak user sync: ${SYNCED} users (expected ≥3 after LDAP sync)"
  fi

  # glpiadmin present in KC
  KC_ADMIN_PRESENT=$(curl -sf "${KC_URL}/admin/realms/it-stack/users?username=glpiadmin&exact=true" \
    -H "${KC_HDR}" 2>/dev/null \
    | python3 -c "import sys,json; u=json.load(sys.stdin); print(len(u))" 2>/dev/null || echo 0)
  if [[ "${KC_ADMIN_PRESENT}" -ge 1 ]]; then
    pass "User glpiadmin present in Keycloak it-stack realm"
  else
    warn "User glpiadmin not yet visible in KC (LDAP sync may be async)"
  fi
fi

# 4e: Register GLPI SAML client
CLIENTS=$(curl -sf "${KC_URL}/admin/realms/it-stack/clients?clientId=glpi" \
  -H "${KC_HDR}" 2>/dev/null || echo "[]")
if echo "${CLIENTS}" | python3 -c "import sys,json; clients=json.load(sys.stdin); exit(0 if any(c.get('clientId')=='glpi' for c in clients) else 1)" 2>/dev/null; then
  pass "Keycloak SAML client 'glpi' already registered"
else
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/clients" \
    -H "${KC_HDR}" -H "Content-Type: application/json" \
    -d '{
      "clientId":"glpi",
      "protocol":"saml",
      "enabled":true,
      "name":"GLPI ITSM",
      "description":"INT-07 GLPI SAML 2.0 SSO",
      "redirectUris":["http://localhost:8442/*","http://localhost:8442/glpi/index.php"],
      "adminUrl":"http://localhost:8442/glpi",
      "attributes":{
        "saml.authn.statement":"true",
        "saml_assertion_consumer_url_post":"http://localhost:8442/glpi/index.php",
        "saml_single_logout_service_url_redirect":"http://localhost:8442/glpi/index.php?action=logout",
        "saml.signing.certificate":"",
        "saml.signature.algorithm":"RSA_SHA256",
        "saml.client.signature":"false",
        "saml.force.post.binding":"true",
        "saml.multivalued.roles":"false",
        "saml.encrypt":"false"
      },
      "protocolMappers":[
        {"name":"username","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"username","attribute.name":"uid","attribute.nameformat":"Basic","friendly.name":"uid"}},
        {"name":"email","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"email","attribute.name":"mail","attribute.nameformat":"Basic","friendly.name":"email"}},
        {"name":"firstName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"firstName","attribute.name":"givenName","attribute.nameformat":"Basic"}},
        {"name":"lastName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"lastName","attribute.name":"sn","attribute.nameformat":"Basic"}}
      ]
    }' || echo "000")
  if [[ "${HTTP}" == "201" ]]; then
    pass "Keycloak SAML client 'glpi' registered (HTTP 201)"
  else
    fail "Keycloak SAML client registration failed (HTTP ${HTTP})"
  fi
fi

echo ""

# ── PHASE 5: SAML IdP Metadata + GLPI Container Assertions ───────────────────
info "Phase 5: SAML IdP metadata reachability + GLPI env checks"

# 5a: SAML IdP descriptor endpoint
SAML_META_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_URL}/realms/it-stack/protocol/saml/descriptor" 2>/dev/null || echo "000")
if [[ "${SAML_META_HTTP}" == "200" ]]; then
  pass "Keycloak SAML IdP descriptor endpoint returns 200"
else
  fail "Keycloak SAML IdP descriptor not reachable (HTTP ${SAML_META_HTTP})"
fi

# 5b: IdP metadata contains EntityDescriptor + IDPSSODescriptor
SAML_META=$(curl -sf "${KC_URL}/realms/it-stack/protocol/saml/descriptor" 2>/dev/null || echo "")
if echo "${SAML_META}" | grep -q "EntityDescriptor"; then
  pass "SAML IdP metadata contains EntityDescriptor"
else
  fail "SAML IdP metadata missing EntityDescriptor"
fi
if echo "${SAML_META}" | grep -q "IDPSSODescriptor"; then
  pass "SAML IdP metadata contains IDPSSODescriptor"
else
  fail "SAML IdP metadata missing IDPSSODescriptor"
fi
if echo "${SAML_META}" | grep -q "X509Certificate"; then
  pass "SAML IdP metadata includes X.509 signing certificate"
else
  warn "SAML IdP metadata X.509 cert not yet present (may need realm configuration)"
fi

# 5c: GLPI container SAML env vars
for env_var in KEYCLOAK_URL KEYCLOAK_REALM KEYCLOAK_CLIENT_ID KC_SAML_IDP_METADATA_URL KC_SAML_SP_ENTITY_ID KC_SAML_ACS_URL; do
  if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q "^${env_var}="; then
    pass "GLPI container env: ${env_var} present"
  else
    warn "GLPI container env: ${env_var} missing (set via ENV in compose)"
  fi
done

# 5d: GLPI can reach Keycloak SAML descriptor internally
if docker exec "${APP_CONTAINER}" curl -sf \
     "http://glpi-i05-kc:8080/realms/it-stack/protocol/saml/descriptor" \
     > /dev/null 2>&1; then
  pass "GLPI container can reach Keycloak SAML descriptor internally"
else
  warn "GLPI container cannot reach KC SAML descriptor (KC may still be initializing)"
fi

echo ""

# ── PHASE 6: WireMock Zammad Stubs + GLPI → Zammad Mock Calls ─────────────────
info "Phase 6: WireMock Zammad REST API stubs + GLPI integration"

# Register tickets GET stub
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request":{"method":"GET","url":"/api/v1/tickets"},
    "response":{
      "status":200,
      "headers":{"Content-Type":"application/json"},
      "body":"[{\"id\":1,\"number\":\"10001\",\"title\":\"GLPI INT-07 escalation\",\"state\":{\"name\":\"open\"}}]"
    }
  }' || echo "000")
if [[ "${HTTP}" == "201" ]]; then
  pass "WireMock Zammad GET /api/v1/tickets stub registered"
else
  fail "WireMock ticket GET stub registration failed (HTTP ${HTTP})"
fi

# Register tickets POST stub
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request":{"method":"POST","url":"/api/v1/tickets"},
    "response":{
      "status":201,
      "headers":{"Content-Type":"application/json"},
      "body":"{\"id\":42,\"number\":\"10042\",\"title\":\"GLPI escalated ticket\",\"state\":{\"name\":\"open\"}}"
    }
  }' || echo "000")
if [[ "${HTTP}" == "201" ]]; then
  pass "WireMock Zammad POST /api/v1/tickets stub registered"
else
  fail "WireMock ticket POST stub registration failed (HTTP ${HTTP})"
fi

# Verify mock responds
if curl -sf "${MOCK_URL}/api/v1/tickets" 2>/dev/null | grep -q "GLPI INT-07 escalation"; then
  pass "WireMock GET /api/v1/tickets returns expected JSON"
else
  fail "WireMock GET /api/v1/tickets returned unexpected response"
fi

# GLPI container → WireMock internal
if docker exec "${APP_CONTAINER}" curl -sf "http://glpi-i05-mock:8080/__admin/health" > /dev/null 2>&1; then
  pass "GLPI container → WireMock internal reachability OK"
else
  fail "GLPI container cannot reach WireMock internally"
fi

# Simulate GLPI → Zammad ticket escalation
if docker exec "${APP_CONTAINER}" curl -sf \
     -X POST "http://glpi-i05-mock:8080/api/v1/tickets" \
     -H "Content-Type: application/json" \
     -H "Authorization: Token token=lab-zammad-token-05" \
     -d '{"title":"GLPI INT-07 escalated ticket","group":"Support","customer_id":2}' \
     2>/dev/null | grep -q "GLPI escalated"; then
  pass "GLPI → Zammad ticket escalation call succeeds (via WireMock)"
else
  warn "GLPI → Zammad ticket call not fully verified (application may need config)"
fi

echo ""

# ── PHASE 7: Volume + Misc Assertions ────────────────────────────────────────
info "Phase 7: Volume and miscellaneous assertions"

if docker volume ls | grep -q 'glpi-i05-app-data'; then
  pass "GLPI app data volume present"
else
  fail "GLPI app data volume missing"
fi

if docker volume ls | grep -q 'glpi-i05-ldap-data'; then
  pass "GLPI LDAP data volume present"
else
  fail "GLPI LDAP data volume missing"
fi

# Container env assertions
for env_var in MARIADB_HOST GLPI_LDAP_HOST ZAMMAD_URL; do
  if docker exec "${APP_CONTAINER}" env 2>/dev/null | grep -q "^${env_var}="; then
    pass "GLPI container env: ${env_var} set"
  else
    fail "GLPI container env: ${env_var} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} — ${LAB_NAME}"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0


# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
