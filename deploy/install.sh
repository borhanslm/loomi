#!/usr/bin/env bash
# Install Loomi Server on Ubuntu/Debian WITHOUT Docker (e.g. when Docker Hub is unreachable).
# Run from the unpacked bundle folder:   sudo bash install.sh
# Re-running it upgrades Loomi and keeps your data and keys.
set -euo pipefail

PORT="${LOOMI_PORT:-8787}"
APP=/opt/loomi
DATA=/var/lib/loomi
ETC=/etc/loomi
NODE_MIN=20
NODE_VER="${NODE_VER:-v22.12.0}"

[ "$(id -u)" = 0 ] || { echo "با sudo اجرا کنید: sudo bash install.sh"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/dist/main.js" ] || { echo "این اسکریپت را از داخل پوشه‌ی بسته‌ی لومی اجرا کنید (dist/main.js پیدا نشد)."; exit 1; }

# 1) Node.js (official build from nodejs.org if missing or too old)
need_node=1
if command -v node >/dev/null; then
  [ "$(node -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MIN" ] && need_node=0
fi
if [ "$need_node" = 1 ]; then
  arch=$(uname -m); case "$arch" in x86_64) arch=x64;; aarch64) arch=arm64;; esac
  echo "نصب Node.js $NODE_VER …"
  curl -fsSL "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-$arch.tar.xz" -o /tmp/node.tar.xz
  mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1 && rm /tmp/node.tar.xz
  ln -sf /opt/node/bin/node /usr/local/bin/node
fi
NODE_BIN="$(command -v node)"
echo "Node: $($NODE_BIN -v)"

# 2) System user and folders
id loomi >/dev/null 2>&1 || useradd --system --home "$DATA" --shell /usr/sbin/nologin loomi
mkdir -p "$APP" "$DATA" "$ETC"
rm -rf "$APP/dist" "$APP/node_modules"
cp -r "$HERE/dist" "$HERE/node_modules" "$HERE/package.json" "$APP/"
chown -R loomi:loomi "$DATA"

# 3) Settings (created once; never overwritten, so keys survive upgrades)
if [ ! -f "$ETC/loomi.env" ]; then
  ip=$(hostname -I | awk '{print $1}')
  umask 077
  cat > "$ETC/loomi.env" <<EOF
LOOMI_PORT=$PORT
LOOMI_HOST=0.0.0.0
LOOMI_DATA_DIR=$DATA/db
LOOMI_PUBLIC_URL=http://$ip:$PORT
LOOMI_MASTER_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
EOF
  chown root:loomi "$ETC/loomi.env"; chmod 640 "$ETC/loomi.env"
  echo "تنظیمات ساخته شد: $ETC/loomi.env — از LOOMI_MASTER_KEY یک نسخه‌ی امن نگه دارید."
fi

# 4) Always-on service
cat > /etc/systemd/system/loomi.service <<EOF
[Unit]
Description=Loomi Server
After=network-online.target
Wants=network-online.target

[Service]
User=loomi
EnvironmentFile=$ETC/loomi.env
WorkingDirectory=$APP
ExecStart=$NODE_BIN $APP/dist/main.js
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DATA
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now loomi
systemctl restart loomi

# 5) Pairing helper
cat > /usr/local/bin/loomi-pair <<EOF
#!/bin/sh
# New one-time pairing code (stop/start not needed)
set -a; . $ETC/loomi.env; set +a
exec sudo -E -u loomi $NODE_BIN $APP/dist/cli.js pair
EOF
chmod 755 /usr/local/bin/loomi-pair

sleep 3
if curl -fsS "http://127.0.0.1:$PORT/v1/health" >/dev/null; then
  url=$(grep ^LOOMI_PUBLIC_URL "$ETC/loomi.env" | cut -d= -f2)
  echo
  echo "✅ لومی اجرا شد: $url"
  echo "برای جفت کردن گوشی:  sudo loomi-pair"
  echo "لاگ‌ها:              journalctl -u loomi -f"
else
  echo "❌ لومی بالا نیامد. لاگ را ببینید: journalctl -u loomi -n 50 --no-pager"; exit 1
fi
