# Architecture — IT-Stack GLPI

## Overview

GLPI provides IT service management (ITSM), CMDB, and software inventory, integrated with Zammad for ticket escalation.

## Role in IT-Stack

- **Category:** it-management
- **Phase:** 4
- **Server:** lab-mgmt1 (10.0.50.18)
- **Ports:** 80 (HTTP), 443 (HTTPS)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → glpi → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
