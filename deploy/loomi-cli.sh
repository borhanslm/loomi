#!/usr/bin/env bash
# loomi — manage your Loomi Server from SSH.
#   loomi            interactive menu
#   loomi <command>  status | url | admin | pair | logs | restart | update | backup | help
# Installed to /usr/local/bin/loomi by get.sh. Works with both the Docker and the no-Docker install.
set -uo pipefail

DIR=/opt/loomi
MODE="$(cat "$DIR/.mode" 2>/dev/null || echo docker)"
REPO="${LOOMI_REPO:-borhanslm/loomi}"
BACKUPS="$DIR/backups"

# ── look ───────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  V=$'\e[38;2;160;140;255m'; C=$'\e[38;2;34;211;238m'; A=$'\e[38;2;255;181;71m'; G=$'\e[38;2;74;222;128m'
  R=$'\e[38;2;255;123;123m'; M=$'\e[38;2;169;163;201m'; B=$'\e[1m'; N=$'\e[0m'
else V=; C=; A=; G=; R=; M=; B=; N=; fi

logo() {
  local L1 L2 L3 L4 L5
  if [ -n "$N" ]; then  # violet → cyan letters
    L1=$'\e[1;38;2;150;120;255m'; L2=$'\e[1;38;2;125;140;255m'; L3=$'\e[1;38;2;100;165;250m'; L4=$'\e[1;38;2;70;190;245m'; L5=$'\e[1;38;2;34;211;238m'
  else L1=; L2=; L3=; L4=; L5=; fi
  printf '\n  %s◯%s%s◯%s %s✦%s   %sL%so%so%sm%si%s  %sserver%s\n' "$V" "$N" "$C" "$N" "$A" "$N" "$L1" "$L2" "$L3" "$L4" "$L5" "$N" "$M" "$N"
  printf '  %s──────────────────────────────%s\n\n' "$M" "$N"
}
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$A" "$N" "$*"; }
fail() { printf '  %s✖%s %s\n' "$R" "$N" "$*" >&2; }
need_root() { [ "$(id -u)" = 0 ] || { fail "این فرمان دسترسی root می‌خواهد:  sudo loomi $*"; exit 1; }; }

# ── helpers that hide Docker vs. native ─────────────────────────────────
compose() { docker compose -f "$DIR/deploy/docker-compose.yml" "$@"; }
cli() {
  if [ "$MODE" = docker ]; then compose exec -T server node dist/cli.js "$@" < /dev/null
  else (set -a; . /etc/loomi/loomi.env; set +a; sudo -E -u loomi node /opt/loomi-server/dist/cli.js "$@" < /dev/null); fi
}
public_url() {
  if [ "$MODE" = docker ]; then
    local d; d="$(grep -E '^LOOMI_DOMAIN=' "$DIR/deploy/.env" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$d" ]; then echo "https://$d"; else echo "http://$(curl -fsS -4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'):8787"; fi
  else grep -E '^LOOMI_PUBLIC_URL=' /etc/loomi/loomi.env | cut -d= -f2-; fi
}

# ── commands ────────────────────────────────────────────────────────────
cmd_status() {
  logo
  local url; url="$(public_url)"
  printf '  %sآدرس%s      %s\n' "$M" "$N" "$url"
  printf '  %sروش نصب%s   %s\n' "$M" "$N" "$([ "$MODE" = docker ] && echo Docker || echo 'بدون Docker')"
  printf '  %sنسخه%s      %s  (%s)\n' "$M" "$N" "$(cat "$DIR/.version" 2>/dev/null || echo '?')" "$(git -C "$DIR" log -1 --format='%h  %cs' 2>/dev/null || echo '?')"
  printf '  %sبه‌روزرسانی خودکار%s  %s\n' "$M" "$N" "$([ -f /etc/cron.d/loomi-update ] && echo 'روشن (هر شب)' || echo 'خاموش')"
  if curl -fsS --max-time 5 "$url/v1/health" >/dev/null 2>&1 || curl -fsS --max-time 3 http://127.0.0.1:8787/v1/health >/dev/null 2>&1; then
    printf '  %sوضعیت%s     %s● سالم%s\n' "$M" "$N" "$G" "$N"
  else
    printf '  %sوضعیت%s     %s● جواب نمی‌دهد%s  (loomi logs)\n' "$M" "$N" "$R" "$N"
  fi
  if [ "$MODE" = docker ]; then
    printf '\n'; compose ps --format '  {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null
  else
    printf '\n  loomi   %s\n' "$(systemctl is-active loomi)"
    command -v caddy >/dev/null && printf '  caddy   %s\n' "$(systemctl is-active caddy)"
  fi
  printf '\n  %sدیسک%s %s   %sرم%s %s\n\n' "$M" "$N" "$(df -h / | awk 'NR==2{print $3" / "$2}')" "$M" "$N" "$(free -h | awk '/Mem/{print $3" / "$2}')"
}
cmd_url()     { public_url; echo "$(public_url)/admin"; }
cmd_admin()   { printf '\n  لینک یک‌بارمصرف رمز پنل ادمین (۳۰ دقیقه):\n\n  %s%s%s\n\n' "$C" "$(cli admin | tail -1)" "$N"; }
cmd_pair()    { printf '\n'; cli pair; printf '\n'; }
cmd_logs() {
  if [ "$MODE" = docker ]; then compose logs -f --tail 100 server
  else journalctl -u loomi -f -n 100; fi
}
cmd_restart() {
  need_root restart
  if [ "$MODE" = docker ]; then compose restart server >/dev/null; else systemctl restart loomi; fi
  ok "لومی دوباره راه‌اندازی شد."
}
latest_release() { curl -fsSL --max-time 15 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4; }
cmd_update() {
  need_root update
  local latest current
  latest="$(latest_release)"; current="$(cat "$DIR/.version" 2>/dev/null || echo '?')"
  if [ "${1:-}" = "--if-newer" ]; then
    [ -n "$latest" ] || { echo "$(date -Is) GitHub در دسترس نیست"; return 0; }
    if [ "$latest" = "$current" ]; then echo "$(date -Is) به‌روز است ($current)"; return 0; fi
    echo "$(date -Is) به‌روزرسانی $current → $latest"
  fi
  curl -fsSL "https://raw.githubusercontent.com/$REPO/${latest:-main}/deploy/get.sh" | LOOMI_REF="${latest:-main}" bash
}
cmd_auto_update() {
  need_root auto-update
  case "${1:-status}" in
    on)
      printf '%s\n' '# Loomi: install a newer release every night' '17 4 * * * root /usr/local/bin/loomi update --if-newer >> /var/log/loomi-update.log 2>&1' > /etc/cron.d/loomi-update
      chmod 644 /etc/cron.d/loomi-update; rm -f "$DIR/.no-auto-update"
      ok "به‌روزرسانی خودکار روشن شد (هر شب ساعت ۴)." ;;
    off)
      rm -f /etc/cron.d/loomi-update; touch "$DIR/.no-auto-update"
      ok "به‌روزرسانی خودکار خاموش شد." ;;
    *)
      if [ -f /etc/cron.d/loomi-update ]; then ok "به‌روزرسانی خودکار: روشن (هر شب ساعت ۴)"; else warn "به‌روزرسانی خودکار: خاموش"; fi
      printf '  نسخه‌ی نصب‌شده: %s   ·   آخرین نسخه: %s\n' "$(cat "$DIR/.version" 2>/dev/null || echo '?')" "$(latest_release || echo '?')" ;;
  esac
}
cmd_backup() {
  need_root backup
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  local f; f="$BACKUPS/loomi-$(date +%Y%m%d-%H%M%S).tar.gz"
  local tmp; tmp="$(mktemp -d)"
  if [ "$MODE" = docker ]; then
    compose exec -T db pg_dump -U loomi loomi < /dev/null > "$tmp/db.sql" || { fail "پشتیبان پایگاه داده ناموفق بود."; rm -rf "$tmp"; return 1; }
    cp "$DIR/deploy/.env" "$tmp/env"
  else
    systemctl stop loomi; cp -a /var/lib/loomi "$tmp/data"; systemctl start loomi
    cp /etc/loomi/loomi.env "$tmp/env"
  fi
  (umask 077; tar -czf "$f" -C "$tmp" .); rm -rf "$tmp"
  ok "پشتیبان ساخته شد: $f"
  warn "این فایل کلید رمزنگاری را هم دارد؛ آن را امن نگه دارید و جایی منتشر نکنید."
}
cmd_help() {
  logo
  cat <<EOF
  ${B}loomi${N}            منوی مدیریت
  ${B}loomi status${N}     وضعیت سرور
  ${B}loomi url${N}        آدرس سرور و پنل ادمین
  ${B}loomi admin${N}      لینک ساختن یا عوض کردن رمز پنل ادمین
  ${B}loomi pair${N}       کد و QR جفت کردن دستگاه تازه
  ${B}loomi logs${N}       دیدن لاگ‌ها (خروج: Ctrl+C)
  ${B}loomi restart${N}    راه‌اندازی دوباره
  ${B}loomi update${N}     به‌روزرسانی به آخرین نسخه
  ${B}loomi auto-update${N} on|off   به‌روزرسانی خودکار شبانه
  ${B}loomi backup${N}     پشتیبان از داده‌ها و کلیدها

EOF
}

menu() {
  while true; do
    clear 2>/dev/null || true
    logo
    printf '  %s1%s  وضعیت سرور\n'                "$V" "$N"
    printf '  %s2%s  لینک رمز پنل ادمین\n'        "$V" "$N"
    printf '  %s3%s  جفت کردن دستگاه تازه (QR)\n' "$V" "$N"
    printf '  %s4%s  دیدن لاگ‌ها\n'               "$V" "$N"
    printf '  %s5%s  راه‌اندازی دوباره\n'          "$V" "$N"
    printf '  %s6%s  به‌روزرسانی\n'                "$V" "$N"
    printf '  %s7%s  پشتیبان‌گیری\n'               "$V" "$N"
    printf '  %s8%s  آدرس‌ها\n'                    "$V" "$N"
    printf '  %s0%s  خروج\n\n'                      "$M" "$N"
    read -r -p "  ${C}›${N} " choice || exit 0
    case "$choice" in
      1) cmd_status ;; 2) cmd_admin ;; 3) cmd_pair ;; 4) cmd_logs ;; 5) cmd_restart ;;
      6) cmd_update ;; 7) cmd_backup ;; 8) printf '\n'; cmd_url; printf '\n' ;;
      0|q|exit) exit 0 ;; *) continue ;;
    esac
    read -r -p "  ${M}Enter برای برگشت به منو…${N} " _ || exit 0
  done
}

case "${1:-}" in
  "") menu ;;
  status) cmd_status ;; url) cmd_url ;; admin) cmd_admin ;; pair) cmd_pair ;; logs) cmd_logs ;;
  restart) cmd_restart ;; update) cmd_update "${2:-}" ;; auto-update) cmd_auto_update "${2:-status}" ;; backup) cmd_backup ;; help|-h|--help) cmd_help ;;
  *) fail "فرمان ناشناخته: $1"; cmd_help; exit 2 ;;
esac
