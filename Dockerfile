# Dockerfile — IT-Stack GLPI wrapper
# Module 17 | Category: it-management | Phase: 4
# Base image: diouxx/glpi:latest

FROM diouxx/glpi:latest

# Labels
LABEL org.opencontainers.image.title="it-stack-glpi" \
      org.opencontainers.image.description="GLPI IT service management and CMDB" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-glpi"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/glpi/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
