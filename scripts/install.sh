#!/usr/bin/env bash
# Telegram VPS Monitor Mini App — one-command installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/adryndian/telegram-vps-monitor-terminal-ai-miniapp/main/scripts/install.sh | bash
#
# Run as the user that will own the service (NOT root).
# Tested on: Ubuntu 22.04 / 24.04, Debian 12

set -euo pipefail

# ────────────────────────────────────────────────────────────
# Config
# ────────────────────────────────────────────────────────────
REPO_URL="https://github.com/ErkinjonYusupov/vps-monitoring.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/telegram-vps-monitor-terminal-ai-miniapp}"
SERVICE_NAME="telegram-vps-monitor"
DEFAULT_PORT="${PORT:-8787}"
DEFAULT_HOST="${HOST:-127.0.0.1}"

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────
c_blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

step()  { echo; c_blue "▸ $*"; }
ok()    { c_green "  ✓ $*"; }
warn()  { c_yellow "  ⚠ $*"; }
err()   { c_red "  ✗ $*"; exit 1; }

ask() {
  local prompt="$1" var_name="$2" default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "  $prompt [$default]: " value
    value="${value:-$default}"
  else
    read -rp "  $prompt: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

ask_secret() {
  local prompt="$1" var_name="$2"
  local value
  read -rsp "  $prompt: " value
  echo
  printf -v "$var_name" '%s' "$value"
}

random_password() {
  openssl rand -base64 32 2>/dev/null | tr -d '/+=' | head -c 32
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1. Install it and retry."
}

# ────────────────────────────────────────────────────────────
# Pre-flight
# ────────────────────────────────────────────────────────────
step "Pre-flight checks"

if [[ "$EUID" -eq 0 ]]; then
  err "Don't run as root. Use a normal user (e.g. ubuntu) — sudo will be requested when needed."
fi

require_cmd git
require_cmd python3
require_cmd curl
require_cmd openssl

PYV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYV_MAJOR=$(echo "$PYV" | cut -d. -f1)
PYV_MINOR=$(echo "$PYV" | cut -d. -f2)
if [[ "$PYV_MAJOR" -lt 3 ]] || { [[ "$PYV_MAJOR" -eq 3 ]] && [[ "$PYV_MINOR" -lt 10 ]]; }; then
  err "Python >= 3.10 required, found $PYV"
fi
ok "Python $PYV"

if ! python3 -c 'import venv' 2>/dev/null; then
  warn "python3-venv missing, installing..."
  sudo apt-get update -qq && sudo apt-get install -y python3-venv >/dev/null
fi
ok "python3-venv available"

if ! sudo -n true 2>/dev/null; then
  warn "sudo will prompt for password during systemd setup"
fi

# ────────────────────────────────────────────────────────────
# Clone or update repo
# ────────────────────────────────────────────────────────────
step "Fetching code"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  ok "Repo already exists at $INSTALL_DIR — pulling latest"
  (cd "$INSTALL_DIR" && git pull --ff-only origin main >/dev/null)
else
  if [[ -e "$INSTALL_DIR" ]]; then
    err "$INSTALL_DIR exists but is not a git repo. Move it aside and retry."
  fi
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" >/dev/null
  ok "Cloned to $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ────────────────────────────────────────────────────────────
# Python venv + deps
# ────────────────────────────────────────────────────────────
step "Setting up Python environment"

if [[ ! -d ".venv" ]]; then
  python3 -m venv .venv
  ok "Created venv"
fi

# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip wheel
pip install --quiet -r requirements.txt
pip install --quiet gunicorn
ok "Dependencies installed"

# ────────────────────────────────────────────────────────────
# Configure .env
# ────────────────────────────────────────────────────────────
step "Configuring .env"

if [[ -f ".env" ]]; then
  warn ".env already exists — keeping it. Edit manually if needed: $INSTALL_DIR/.env"
else
  cp .env.example .env

  echo
  c_dim "Telegram bot setup:"
  c_dim "  1. Create a bot via @BotFather → get token"
  c_dim "  2. Message @userinfobot to get your numeric user ID"
  echo

  ask_secret "Telegram bot token (from @BotFather)" TG_TOKEN
  ask "Your Telegram numeric user ID" TG_USER_ID
  ask "Service host (bind address)" SVC_HOST "$DEFAULT_HOST"
  ask "Service port" SVC_PORT "$DEFAULT_PORT"

  DASH_PW=$(random_password)
  TERM_FALLBACK_PW=$(random_password)

  python3 - <<PY
import os, re
path = os.path.join("$INSTALL_DIR", ".env")
with open(path) as f:
    content = f.read()

updates = {
    "DASHBOARD_PASSWORD": "$DASH_PW",
    "ALLOWED_TG_USER_ID": "$TG_USER_ID",
    "TELEGRAM_BOT_TOKEN": "$TG_TOKEN",
    "TERMINAL_PASSWORD_FALLBACK": "$TERM_FALLBACK_PW",
    "HOST": "$SVC_HOST",
    "PORT": "$SVC_PORT",
}
for key, value in updates.items():
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if pattern.search(content):
        content = pattern.sub(f"{key}={value}", content)
    else:
        content += f"\n{key}={value}\n"

with open(path, "w") as f:
    f.write(content)
PY

  chmod 600 .env
  ok ".env written (mode 600)"
  c_dim "    DASHBOARD_PASSWORD: $(printf '%s' "$DASH_PW" | head -c 6)... (saved to .env)"
fi

# ────────────────────────────────────────────────────────────
# systemd service
# ────────────────────────────────────────────────────────────
step "Installing systemd service"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GUNICORN_BIN="$INSTALL_DIR/.venv/bin/gunicorn"
ENV_FILE="$INSTALL_DIR/.env"

ENV_PORT=$(grep -E '^PORT=' "$ENV_FILE" | head -1 | cut -d= -f2 | tr -d '"' || echo "$DEFAULT_PORT")
ENV_HOST=$(grep -E '^HOST=' "$ENV_FILE" | head -1 | cut -d= -f2 | tr -d '"' || echo "$DEFAULT_HOST")

sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Telegram VPS Monitor Mini App
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$GUNICORN_BIN -k gthread --threads 8 -b ${ENV_HOST}:${ENV_PORT} app:app
Restart=always
RestartSec=5
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl restart "$SERVICE_NAME"
ok "Service $SERVICE_NAME enabled + started"

# ────────────────────────────────────────────────────────────
# Verify app
# ────────────────────────────────────────────────────────────
step "Verifying"

sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "systemd: active"
else
  err "Service failed to start. Check: sudo journalctl -u $SERVICE_NAME -n 50 --no-pager"
fi

HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${ENV_HOST}:${ENV_PORT}/" || echo "000")
if [[ "$HEALTH_CODE" =~ ^(200|401)$ ]]; then
  ok "HTTP responsive (code: $HEALTH_CODE)"
else
  warn "Unexpected HTTP code: $HEALTH_CODE — check service logs"
fi

# ────────────────────────────────────────────────────────────
# HTTPS setup
# ────────────────────────────────────────────────────────────
step "HTTPS setup"

echo
c_dim "  Telegram Mini App requires public HTTPS. Choose a method:"
echo "  1) Nginx + Cloudflare Auto-SSL  ★ (domen + API token → tayyor, tavsiya)"
echo "  2) Cloudflare Tunnel            (port ochiq bo'lishi shart emas)"
echo "  3) Nginx + Let's Encrypt        (port 80/443 ochiq, CF proxy o'chiq bo'lishi kerak)"
echo "  4) Skip                         (keyinroq o'zingiz sozlaysiz)"
echo
read -rp "  Your choice [1/2/3/4]: " HTTPS_CHOICE
HTTPS_CHOICE="${HTTPS_CHOICE:-1}"

PUBLIC_URL=""

# ── Option 1: Nginx + Cloudflare DNS Auto-SSL ────────────────
if [[ "$HTTPS_CHOICE" == "1" ]]; then
  step "Nginx + Cloudflare Auto-SSL"

  echo
  c_dim "  Cloudflare API token olish:"
  c_dim "  dash.cloudflare.com → My Profile → API Tokens → Create Token"
  c_dim "  → 'Edit zone DNS' shablonini tanlang → domeningizni tanlang → Create"
  echo

  ask "Domeningiz (masalan: vps.example.com)" CF_AUTO_DOMAIN
  ask_secret "Cloudflare API Token" CF_API_TOKEN
  ask "Email (Let's Encrypt xabarlari uchun)" CF_EMAIL

  # Install nginx + certbot + cloudflare dns plugin
  sudo apt-get update -qq
  sudo apt-get install -y nginx certbot python3-certbot-dns-cloudflare >/dev/null
  ok "nginx + certbot + dns-cloudflare o'rnatildi"

  # Cloudflare credentials fayli
  mkdir -p "$HOME/.secrets/certbot"
  chmod 700 "$HOME/.secrets/certbot"
  cat > "$HOME/.secrets/certbot/cloudflare.ini" <<CFINI
dns_cloudflare_api_token = ${CF_API_TOKEN}
CFINI
  chmod 600 "$HOME/.secrets/certbot/cloudflare.ini"
  ok "Cloudflare credentials yozildi"

  # SSL sertifikat olish (DNS challenge — CF proxy yoqilgan bo'lsa ham ishlaydi)
  sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$HOME/.secrets/certbot/cloudflare.ini" \
    -d "$CF_AUTO_DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$CF_EMAIL"
  ok "SSL sertifikat olindi: $CF_AUTO_DOMAIN"

  # Nginx config (port 443 + 80→443 redirect)
  sudo tee "/etc/nginx/sites-available/${SERVICE_NAME}" >/dev/null <<NGEOF
server {
    listen 443 ssl http2;
    server_name ${CF_AUTO_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${CF_AUTO_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CF_AUTO_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://${ENV_HOST}:${ENV_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600;
    }
}

server {
    listen 80;
    server_name ${CF_AUTO_DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGEOF

  sudo ln -sf "/etc/nginx/sites-available/${SERVICE_NAME}" \
    "/etc/nginx/sites-enabled/${SERVICE_NAME}"
  sudo nginx -t
  sudo systemctl enable nginx
  sudo systemctl restart nginx
  ok "nginx ishga tushirildi"

  # Auto-renewal
  sudo systemctl enable certbot.timer 2>/dev/null || \
    sudo systemctl enable certbot-renew.timer 2>/dev/null || true
  ok "SSL auto-renewal yoqildi"

  PUBLIC_URL="https://${CF_AUTO_DOMAIN}"

# ── Option 2: Cloudflare Tunnel ──────────────────────────────
elif [[ "$HTTPS_CHOICE" == "2" ]]; then
  step "Cloudflare Tunnel o'rnatilmoqda"

  if ! command -v cloudflared >/dev/null 2>&1; then
    c_dim "  cloudflared yuklanmoqda..."
    sudo curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
    ok "cloudflared o'rnatildi"
  else
    ok "cloudflared mavjud ($(cloudflared --version 2>&1 | head -1))"
  fi

  ask "Domeningiz (masalan: vps.example.com)" CF_DOMAIN

  echo
  c_yellow "  ► Quyidagi URL ni brauzerda oching va Cloudflare ga kiring:"
  echo
  cloudflared tunnel login
  echo
  ok "Cloudflare login amalga oshdi"

  TUNNEL_NAME="vps-monitor"
  if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
    warn "Tunnel '$TUNNEL_NAME' mavjud — qayta ishlatilmoqda"
  else
    cloudflared tunnel create "$TUNNEL_NAME"
    ok "Tunnel '$TUNNEL_NAME' yaratildi"
  fi

  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null \
    | grep "$TUNNEL_NAME" \
    | awk '{print $1}' \
    | head -1)

  [[ -z "$TUNNEL_ID" ]] && err "Tunnel ID topilmadi. Tekshiring: cloudflared tunnel list"
  ok "Tunnel ID: $TUNNEL_ID"

  cloudflared tunnel route dns "$TUNNEL_NAME" "$CF_DOMAIN" 2>/dev/null || \
    warn "DNS route allaqachon mavjud — davom etilmoqda"
  ok "DNS ulandi: $CF_DOMAIN → tunnel"

  mkdir -p "$HOME/.cloudflared"
  cat > "$HOME/.cloudflared/config.yml" <<CFEOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${HOME}/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${CF_DOMAIN}
    service: http://${ENV_HOST}:${ENV_PORT}
  - service: http_status:404
CFEOF
  ok "config.yml yozildi"

  sudo cloudflared service install 2>/dev/null || true
  sudo systemctl enable cloudflared 2>/dev/null || true
  sudo systemctl restart cloudflared
  sleep 2
  systemctl is-active --quiet cloudflared && ok "cloudflared: active" || \
    warn "cloudflared ishlamayapti. Tekshiring: sudo journalctl -u cloudflared -n 30"

  PUBLIC_URL="https://${CF_DOMAIN}"

# ── Option 3: Nginx + Let's Encrypt ─────────────────────────
elif [[ "$HTTPS_CHOICE" == "3" ]]; then
  step "Nginx + Let's Encrypt"

  c_dim "  Cloudflare proxy (orange cloud) vaqtincha o'chirilgan bo'lishi kerak."
  c_dim "  Port 80 va 443 VPS firewall da ochiq bo'lishi kerak."
  echo
  ask "Domeningiz (masalan: vps.example.com)" LE_DOMAIN
  ask "Email (Let's Encrypt uchun)" LE_EMAIL

  sudo apt-get update -qq
  sudo apt-get install -y nginx certbot python3-certbot-nginx >/dev/null
  ok "nginx + certbot o'rnatildi"

  sudo tee "/etc/nginx/sites-available/${SERVICE_NAME}" >/dev/null <<NGEOF
server {
    listen 80;
    server_name ${LE_DOMAIN};

    location / {
        proxy_pass http://${ENV_HOST}:${ENV_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600;
    }
}
NGEOF

  sudo ln -sf "/etc/nginx/sites-available/${SERVICE_NAME}" \
    "/etc/nginx/sites-enabled/${SERVICE_NAME}"
  sudo nginx -t && sudo systemctl reload nginx
  ok "nginx sozlandi"

  sudo certbot --nginx -d "$LE_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
  ok "SSL sertifikat olindi: $LE_DOMAIN"

  sudo systemctl enable certbot.timer 2>/dev/null || \
    sudo systemctl enable certbot-renew.timer 2>/dev/null || true
  ok "Auto-renewal yoqildi"

  PUBLIC_URL="https://${LE_DOMAIN}"

# ── Option 4: Skip ───────────────────────────────────────────
else
  warn "HTTPS o'tkazib yuborildi. Telegram ga ulashdan oldin sozlang."
fi

# ────────────────────────────────────────────────────────────
# Telegram menu button
# ────────────────────────────────────────────────────────────
if [[ -n "$PUBLIC_URL" ]]; then
  step "Setting Telegram menu button"

  TG_BOT_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2 | tr -d '"' || echo "")

  if [[ -z "$TG_BOT_TOKEN" ]]; then
    warn "TELEGRAM_BOT_TOKEN not found in .env — skipping menu button setup"
  else
    TG_RESP=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/setChatMenuButton" \
      -H "Content-Type: application/json" \
      -d "{\"menu_button\":{\"type\":\"web_app\",\"text\":\"VPS\",\"web_app\":{\"url\":\"${PUBLIC_URL}\"}}}")

    if echo "$TG_RESP" | grep -q '"ok":true'; then
      ok "Telegram menu button set → $PUBLIC_URL"
    else
      warn "Telegram API response: $TG_RESP"
    fi
  fi
fi

# ────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────
echo
c_green "═══════════════════════════════════════════════════════════"
c_green "  ✓ Installation complete"
c_green "═══════════════════════════════════════════════════════════"
echo
echo "  Service:    $SERVICE_NAME  (systemctl status $SERVICE_NAME)"
echo "  Local URL:  http://${ENV_HOST}:${ENV_PORT}"
[[ -n "$PUBLIC_URL" ]] && echo "  Public URL: $PUBLIC_URL"
echo "  Install:    $INSTALL_DIR"
echo "  Logs:       sudo journalctl -u $SERVICE_NAME -f"
echo
if [[ -n "$PUBLIC_URL" ]]; then
  c_green "  ► Open Telegram → your bot → tap VPS button → done."
else
  c_yellow "  Next: expose via HTTPS, then set Telegram menu button:"
  echo "    curl -X POST \"https://api.telegram.org/bot\$BOT_TOKEN/setChatMenuButton\" \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{\"menu_button\":{\"type\":\"web_app\",\"text\":\"VPS\",\"web_app\":{\"url\":\"YOUR_HTTPS_URL\"}}}'"
fi
echo
c_dim "  Update later: cd $INSTALL_DIR && git pull && sudo systemctl restart $SERVICE_NAME"
echo
