# syntax=docker/dockerfile:1
FROM alpine:3.21

RUN apk add --no-cache \
      postfix \
      rspamd rspamd-proxy rspamd-controller \
      redis \
      unbound \
      supervisor \
      openssl \
    && mkdir -p \
       /etc/rspamd/local.d/maps \
       /var/lib/rspamd \
       /var/lib/unbound \
       /run/redis \
       /run/unbound \
    && chown redis:redis /run/redis \
    && chown rspamd:rspamd /var/lib/rspamd \
    && unbound-anchor -a /var/lib/unbound/root.key || true \
    && chown -R unbound:unbound /var/lib/unbound /run/unbound /etc/unbound

COPY <<'ENTRYPOINT' /entrypoint.sh
#!/bin/sh
set -e
postmap lmdb:/etc/postfix/transport
newaliases
if [ ! -f /etc/postfix/smtpd.crt ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/postfix/smtpd.key -out /etc/postfix/smtpd.crt \
    -subj "/CN=mx.levinkeller.de"
fi
exec "$@"
ENTRYPOINT
RUN chmod +x /entrypoint.sh

EXPOSE 25 11334

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
