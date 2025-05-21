ARG CADDY_VERSION=2
# Use the official Caddy image as the base image
FROM caddy:${CADDY_VERSION}

ARG TARGETARCH
LABEL org.opencontainers.image.title='DomainPilot'
LABEL org.opencontainers.image.description='A Caddy reverse proxy server for multi-domain development. Nginx-proxy style with host routing'
LABEL org.opencontainers.image.vendor='Phillarmonic Software <www.phillarmonic.com>'
LABEL org.opencontainers.image.authors='Monkey Jobs Phillarmonkey <phillarmonicsoftware@outlook.com>'

# Install Docker CLI, and utilities used by Caddy
# Added inotify-tools for watching file changes
RUN apk add --no-cache docker-cli jq figlet bash nss nss-tools nano curl wget inotify-tools iputils

# Add your custom script to the container
ADD docker/caddy-json-config.sh /usr/local/bin/domainpilot
RUN chmod +x /usr/local/bin/domainpilot

# Optional: Copy any additional files your script depends on
COPY docker/includes.sh /opt/includes.sh

# Set extra host.docker.internal to point to the host
ENTRYPOINT ["domainpilot"]

# Caddy will run on ports 80 and 443
EXPOSE 80 443