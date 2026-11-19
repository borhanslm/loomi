#!/usr/bin/env bash
# Loomi Server — one-line install (and update) for Ubuntu/Debian:
#
#   curl -fsSL https://raw.githubusercontent.com/borhanslm/loomi/main/deploy/get.sh | sudo bash
#
# It installs everything it needs, asks for your domain (optional), creates the secrets,
# starts Loomi with automatic HTTPS, and prints the admin panel link and a pairing code.
# Run it again any time to update; your data and keys are kept.
#
# Non-interactive:  LOOMI_DOMAIN=loomi.example.com LOOMI_MODE=docker|native bash get.sh
set -euo pipefail

REPO="${LOOMI_REPO:-borhanslm/loomi}"
BRANCH="${LOOMI_BRANCH:-main}"
DIR=/opt/loomi
say()  { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local q="$1" def="${2:-}" a=""; if [ -r /dev/tty ]; then read -r -p "$q " a < /dev/tty || true; fi; echo "${a:-$def}"; }

[ "$(id -u)" = 0 ] || die "با sudo اجرا کنید:  curl -fsSL …/get.sh | sudo bash"
command -v apt-get >/dev/null || die "فعلاً فقط Ubuntu و Debian پشتیبانی می‌شوند."
export DEBIAN_FRONTEND=noninteractive

say "پیش‌نیازها"
apt-get update -qq >/dev/null
apt-get install -y -qq curl git openssl ca-certificates dnsutils tar xz-utils >/dev/null
ok "آماده"

# ── domain ──────────────────────────────────────────────────────────────
PUBIP="$(curl -fsS -4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
DOMAIN="${LOOMI_DOMAIN:-}"
if [ -z "$DOMAIN" ] && [ -f "$DIR/deploy/.env" ]; then DOMAIN="$(grep -E '^LOOMI_DOMAIN=' "$DIR/deploy/.env" | cut -d= -f2- || true)"; fi
if [ -z "$DOMAIN" ]; then
  echo
  echo "اگر دامنه دارید (مثلاً loomi.example.com)، اول یک رکورد A به IP این سرور (${PUBIP:-?}) بسازید."
  DOMAIN="$(ask 'دامنه‌ی لومی (برای HTTPS؛ خالی = فقط با IP و بدون HTTPS):' '')"
fi
DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##')"
if [ -n "$DOMAIN" ]; then
  RES="$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | tail -1 || true)"
  if [ -n "$PUBIP" ] && [ "$RES" != "$PUBIP" ]; then
    echo "⚠ $DOMAIN الان به «${RES:-هیچ}» اشاره می‌کند، نه به این سرور ($PUBIP). تا درست نشود، گواهی HTTPS گرفته نمی‌شود."
  fi
fi

# ── docker or native ────────────────────────────────────────────────────
MODE="${LOOMI_MODE:-}"
if [ -z "$MODE" ]; then
  # Docker Hub answers 401 (needs a token) when reachable; a sanctions block gives 403 or no answer.
  HUB="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null || true)"
  if [ -f "$DIR/.mode" ]; then MODE="$(cat "$DIR/.mode")"
  elif command -v docker >/dev/null && [ -n "$(docker ps -q --filter label=com.docker.compose.project=deploy 2>/dev/null)" ]; then MODE=docker
  elif [ "$HUB" = 401 ] || [ "$HUB" = 200 ]; then MODE=docker
  else MODE=native; fi
fi
say "روش نصب: $([ "$MODE" = docker ] && echo 'Docker' || echo 'بدون Docker (Docker Hub در دسترس نیست)')"

# ── code ────────────────────────────────────────────────────────────────
say "دریافت لومی"
mkdir -p "$DIR"
if [ ! -d "$DIR/.git" ]; then
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "https://github.com/$REPO.git"
fi
git -C "$DIR" fetch -q --depth 1 origin "$BRANCH"
git -C "$DIR" reset -q --hard FETCH_HEAD   # keeps untracked files: deploy/.env and data
ok "نسخه: $(git -C "$DIR" log -1 --format='%h %cs')"

# ── secrets (created once, kept on updates) ─────────────────────────────
ENVF="$DIR/deploy/.env"
setv() { if grep -qE "^$1=" "$ENVF"; then sed -i "s#^$1=.*#$1=$2#" "$ENVF"; else echo "$1=$2" >> "$ENVF"; fi; }
umask 077
touch "$ENVF"
grep -qE '^POSTGRES_PASSWORD=.+' "$ENVF" || setv POSTGRES_PASSWORD "$(openssl rand -hex 24)"
grep -qE '^LOOMI_MASTER_KEY=[0-9a-f]{64}$' "$ENVF" || setv LOOMI_MASTER_KEY "$(openssl rand -hex 32)"
setv LOOMI_DOMAIN "$DOMAIN"
chmod 600 "$ENVF"
umask 022

if [ -n "$DOMAIN" ]; then URL="https://$DOMAIN"; else URL="http://${PUBIP:-$(hostname -I | awk '{print $1}')}:8787"; fi

# ── start ───────────────────────────────────────────────────────────────
if [ "$MODE" = docker ]; then
  if ! command -v docker >/dev/null; then
    say "نصب Docker"
    curl -fsSL https://get.docker.com | sh < /dev/null >/tmp/loomi-docker.log 2>&1 || { tail -20 /tmp/loomi-docker.log; die "نصب Docker ناموفق بود."; }
  fi
  if [ "$(free -m | awk '/Mem/{print $2}')" -lt 3000 ] && ! swapon --show | grep -q .; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  say "ساخت و اجرای لومی (چند دقیقه)"
  cd "$DIR/deploy"
  if [ -n "$DOMAIN" ]; then
    docker compose up -d --build < /dev/null >/tmp/loomi-up.log 2>&1 || { tail -30 /tmp/loomi-up.log; die "اجرا ناموفق بود."; }
  else
    LOOMI_PUBLIC_URL="$URL" docker compose -f docker-compose.yml -f docker-compose.ip.yml up -d --build server db < /dev/null >/tmp/loomi-up.log 2>&1 || { tail -30 /tmp/loomi-up.log; die "اجرا ناموفق بود."; }
  fi
  run_cli() { docker compose -f "$DIR/deploy/docker-compose.yml" exec -T server node dist/cli.js "$@" < /dev/null; }
  echo docker > "$DIR/.mode"
else
  say "نصب بدون Docker"
  TMPB="$(mktemp -d)"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/loomi-server.tar.gz" -o "$TMPB/s.tgz" || die "بسته‌ی سرور از GitHub دانلود نشد."
  tar -xzf "$TMPB/s.tgz" -C "$TMPB"
  LOOMI_PUBLIC_URL="$URL" LOOMI_MASTER_KEY="$(grep ^LOOMI_MASTER_KEY= "$ENVF" | cut -d= -f2)" \
    LOOMI_HOST="$([ -n "$DOMAIN" ] && echo 127.0.0.1 || echo 0.0.0.0)" bash "$TMPB/loomi-server/install.sh" < /dev/null
  rm -rf "$TMPB"
  if [ -n "$DOMAIN" ]; then
    if ! command -v caddy >/dev/null; then
      say "نصب Caddy (HTTPS خودکار)"
      CV="2.10.2"; ARCH="$(dpkg --print-architecture)"
      curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v$CV/caddy_${CV}_linux_${ARCH}.tar.gz" | tar -xz -C /usr/local/bin caddy
      id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
      cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
After=network-online.target
[Service]
User=caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    fi
    mkdir -p /etc/caddy
    printf '%s {\n\tencode zstd gzip\n\treverse_proxy 127.0.0.1:8787\n}\n' "$DOMAIN" > /etc/caddy/Caddyfile
    systemctl daemon-reload && systemctl enable --now caddy >/dev/null 2>&1 && systemctl restart caddy
  fi
  run_cli() { set -a; . /etc/loomi/loomi.env; set +a; sudo -E -u loomi node /opt/loomi-server/dist/cli.js "$@" < /dev/null; }
  echo native > "$DIR/.mode"
fi

# ── done ────────────────────────────────────────────────────────────────
say "بررسی سلامت"
for i in $(seq 1 60); do
  curl -fsS --max-time 3 "$URL/v1/health" >/dev/null 2>&1 && break
  [ "$i" = 60 ] && echo "⚠ هنوز از $URL جواب نمی‌آید (اگر دامنه تازه است، چند دقیقه صبر کنید)."
  sleep 3
done

install -m 755 "$DIR/deploy/loomi-cli.sh" /usr/local/bin/loomi

echo
ok "لومی نصب شد: $URL"
echo "   برای مدیریت سرور هر وقت خواستید بزنید:  loomi"
echo
echo "۱) پنل ادمین — این لینک یک‌بارمصرف را (۳۰ دقیقه) باز کنید و رمز بگذارید:"
run_cli admin 2>/dev/null | tail -1 || true
echo
echo "۲) جفت کردن گوشی و دسکتاپ — از پنل ادمین (بخش دستگاه‌ها) یا این کد:"
run_cli pair 2>/dev/null | tail -2 || true
echo
echo "اپ‌ها: https://github.com/$REPO/releases/latest"
echo "⚠ از فایل $ENVF یک نسخه‌ی امن نگه دارید (کلید رمزنگاری کلیدهای API داخلش است)."
