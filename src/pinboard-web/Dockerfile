# syntax=docker/dockerfile:1
# Pinboard web — static files served by nginx, /api/ proxied to the API.
# nginx:<ver>-alpine ships an entrypoint that renders *.template files from
# /etc/nginx/templates with envsubst, so API_URL is a plain environment variable.
FROM nginx:1.28-alpine

LABEL org.opencontainers.image.title="pinboard-web" \
      org.opencontainers.image.description="Pinboard web UI — Containers & Kubernetes course sample"

# Default values; override with -e / environment: / ConfigMap.
ENV API_URL=http://api:8080 \
    NGINX_ENTRYPOINT_QUIET_LOGS=1

RUN rm /etc/nginx/conf.d/default.conf
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --chmod=0755 nginx/10-resolver.envsh /docker-entrypoint.d/10-resolver.envsh
COPY html/ /usr/share/nginx/html/

# Run as the unprivileged nginx user: listen on 8080 (not 80) and make the
# directories nginx writes to owned by that user.
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx/conf.d \
 && touch /var/run/nginx.pid && chown nginx:nginx /var/run/nginx.pid
USER 101:101

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=2s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
