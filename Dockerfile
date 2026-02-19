# syntax=docker/dockerfile:1
FROM alpine:3.21

# ══════════════════════════════════════════════════════════
#  Packages
# ══════════════════════════════════════════════════════════

RUN apk add --no-cache \
      postfix \
      rspamd rspamd-proxy rspamd-controller \
      redis \
      unbound \
      supervisor \
      openssl \
    && mkdir -p /etc/rspamd/local.d/maps \
    && mkdir -p /var/lib/rspamd \
    && mkdir -p /run/redis \
    && chown redis:redis /run/redis \
    && chown rspamd:rspamd /var/lib/rspamd

# ══════════════════════════════════════════════════════════
#  Postfix
# ══════════════════════════════════════════════════════════

COPY <<'EOF' /etc/postfix/main.cf
myhostname = mx.levinkeller.de
mydomain = levinkeller.de
myorigin = $mydomain
mydestination =
mynetworks = 127.0.0.0/8 172.16.0.0/12 10.0.0.0/8

relay_domains = levinkeller.de
transport_maps = lmdb:/etc/postfix/transport

smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332
milter_protocol = 6
milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}
milter_default_action = accept

smtp_tls_security_level = may
smtpd_tls_security_level = may
smtpd_tls_cert_file = /etc/postfix/smtpd.crt
smtpd_tls_key_file = /etc/postfix/smtpd.key
inet_protocols = all

smtpd_helo_required = yes
smtpd_recipient_restrictions =
    permit_mynetworks,
    reject_unauth_destination,
    reject_invalid_hostname,
    reject_non_fqdn_sender,
    reject_non_fqdn_recipient,
    reject_unknown_sender_domain

message_size_limit = 52428800
compatibility_level = 3.9
maillog_file = /dev/stdout
EOF

COPY <<'EOF' /etc/postfix/transport
levinkeller.de    smtp:[cp179.sp-server.net]:25
EOF

RUN postmap lmdb:/etc/postfix/transport \
    && newaliases \
    && openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
       -keyout /etc/postfix/smtpd.key -out /etc/postfix/smtpd.crt \
       -subj "/CN=mx.levinkeller.de"

# ══════════════════════════════════════════════════════════
#  rspamd
# ══════════════════════════════════════════════════════════

COPY <<'EOF' /etc/rspamd/local.d/worker-proxy.inc
bind_socket = "*:11332";
milter = yes;
timeout = 120s;
upstream "local" { self_scan = yes; }
EOF

COPY <<'EOF' /etc/rspamd/local.d/worker-normal.inc
enabled = false;
EOF

COPY <<'EOF' /etc/rspamd/local.d/worker-controller.inc
bind_socket = "*:11334";
EOF

COPY <<'EOF' /etc/rspamd/local.d/options.inc
dns {
  nameserver = "127.0.0.1:53";
}
EOF

COPY <<'EOF' /etc/rspamd/local.d/redis.conf
servers = "127.0.0.1:6379";
EOF

COPY <<'EOF' /etc/rspamd/local.d/actions.conf
reject = 15;
add_header = 6;
greylist = 4;
EOF

COPY <<'EOF' /etc/rspamd/local.d/classifier-bayes.conf
autolearn {
  spam_threshold = 7.0;
  ham_threshold = -0.5;
  check_balance = true;
  min_balance = 0.9;
}
EOF

COPY <<'EOF' /etc/rspamd/local.d/greylist.conf
enabled = true;
timeout = 5min;
expire = 30d;
EOF

COPY <<'EOF' /etc/rspamd/local.d/phishing.conf
openphish_enabled = true;
phishtank_enabled = true;
EOF

COPY <<'EOF' /etc/rspamd/local.d/milter_headers.conf
use = ["x-spamd-bar", "x-spam-level", "x-spam-status", "authentication-results"];
extended_spam_headers = true;
EOF

COPY <<'EOF' /etc/rspamd/local.d/multimap.conf
SPAM_LIST_ID {
  type = "header";
  header = "List-ID";
  map = "/etc/rspamd/local.d/maps/spam_list_ids.map";
  score = 10.0;
}
AUTO_REPLY_VIA_LIST {
  type = "header";
  header = "Auto-Submitted";
  regexp = true;
  map = "/etc/rspamd/local.d/maps/auto_submitted.map";
  score = 0.1;
}
SPAM_ENVELOPE_DOMAIN {
  type = "from";
  filter = "email:domain";
  map = "/etc/rspamd/local.d/maps/blocked_domains.map";
  score = 10.0;
}
EOF

COPY <<'EOF' /etc/rspamd/local.d/composites.conf
AUTO_REPLY_ON_MAILING_LIST {
  expression = "AUTO_REPLY_VIA_LIST & MAILLIST";
  score = 8.0;
}
EOF

# ── Blocklists (edit these, rebuild) ─────────────────────

COPY <<'EOF' /etc/rspamd/local.d/maps/spam_list_ids.map
bg.lgtsjs.com
EOF

COPY <<'EOF' /etc/rspamd/local.d/maps/auto_submitted.map
/auto-generated/i
/auto-replied/i
/auto-notified/i
EOF

COPY <<'EOF' /etc/rspamd/local.d/maps/blocked_domains.map
lgtsjs.com
ansturme.de
nikosale.makeup
devalser.hair
EOF

# ══════════════════════════════════════════════════════════
#  Unbound (recursive DNS for RBL lookups)
# ══════════════════════════════════════════════════════════

COPY <<'EOF' /etc/unbound/unbound.conf
server:
  interface: 127.0.0.1
  port: 53
  access-control: 127.0.0.0/8 allow
  do-ip6: no
  username: unbound
  directory: /var/lib/unbound
  pidfile: /run/unbound/unbound.pid
  auto-trust-anchor-file: /var/lib/unbound/root.key
  num-threads: 2
  msg-cache-size: 16m
  rrset-cache-size: 32m
  cache-min-ttl: 60
  cache-max-ttl: 86400
  hide-identity: yes
  hide-version: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
EOF

RUN mkdir -p /var/lib/unbound /run/unbound \
    && unbound-anchor -a /var/lib/unbound/root.key || true \
    && chown -R unbound:unbound /var/lib/unbound /run/unbound /etc/unbound

# ══════════════════════════════════════════════════════════
#  Supervisor
# ══════════════════════════════════════════════════════════

COPY <<'EOF' /etc/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:redis]
command=redis-server --daemonize no --loglevel warning --save 60 1 --dir /var/lib/redis --maxmemory 128mb --maxmemory-policy volatile-lru
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:unbound]
command=unbound -d -c /etc/unbound/unbound.conf
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:rspamd]
command=rspamd -f -u rspamd -g rspamd
autorestart=true
priority=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:postfix]
command=/usr/sbin/postfix start-fg
autorestart=true
priority=40
startsecs=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# ══════════════════════════════════════════════════════════

EXPOSE 25 11334

CMD ["supervisord", "-c", "/etc/supervisord.conf"]
