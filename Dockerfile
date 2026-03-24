FROM sandreas/m4b-tool:latest

# Install minimal extras for permission handling and shell scripting
RUN apk add --no-cache bash su-exec shadow

# Environment defaults
ENV PUID=99 \
    PGID=100 \
    SLEEPTIME=5m \
    CPU_CORES=0 \
    MAKE_BACKUP=N \
    AUDIO_BITRATE=auto \
    AUDIO_CODEC=libfdk_aac

# Create user/group (IDs adjusted at runtime by entrypoint)
RUN addgroup -g 100 abc 2>/dev/null || true && \
    adduser -D -u 99 -G abc -s /bin/bash -h /config abc 2>/dev/null || true

# Create directory structure
RUN mkdir -p /input /output /config/logs /temp/merge /backup

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/m4b-audiobook-converter.sh /usr/local/bin/m4b-audiobook-converter.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/m4b-audiobook-converter.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD pgrep -f m4b-audiobook-converter.sh > /dev/null || exit 1

VOLUME ["/input", "/output", "/config"]
