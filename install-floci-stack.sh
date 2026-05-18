#!/usr/bin/env bash
set -euo pipefail

# Fresh Ubuntu 24.04 bootstrap for:
# - Floci emulator on 127.0.0.1:4566
# - Floci UI API on 127.0.0.1:3001
# - Floci UI frontend on 127.0.0.1:3000
# - Caddy HTTPS:
#     https://$FLOCI_DASHBOARD_DOMAIN -> UI frontend
#     https://$FLOCI_API_DOMAIN       -> Floci AWS-compatible API
#
# Usage:
#   FLOCI_DASHBOARD_DOMAIN=floci.melcu.dev \
#   FLOCI_API_DOMAIN=api.floci.melcu.dev \
#   bash install-floci-stack.sh

FLOCI_DASHBOARD_DOMAIN="${FLOCI_DASHBOARD_DOMAIN:-floci.melcu.dev}"
FLOCI_API_DOMAIN="${FLOCI_API_DOMAIN:-api.floci.melcu.dev}"
FLOCI_REGION="${FLOCI_REGION:-us-east-1}"
FLOCI_USER="${FLOCI_USER:-ubuntu}"
FLOCI_HOME="${FLOCI_HOME:-/home/${FLOCI_USER}}"
FLOCI_DIR="${FLOCI_DIR:-${FLOCI_HOME}/floci}"
FLOCI_UI_DIR="${FLOCI_UI_DIR:-${FLOCI_HOME}/floci-ui}"

log() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo or as root." >&2
    exit 1
  fi
}

require_root

if ! id "$FLOCI_USER" >/dev/null 2>&1; then
  echo "User '$FLOCI_USER' does not exist. Set FLOCI_USER to the VM user." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating Ubuntu and installing base packages"
apt-get update
apt-get install -y ca-certificates curl gnupg git unzip ufw iptables-persistent

log "Creating swap if missing"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
elif ! swapon --show=NAME | grep -qx /swapfile; then
  swapon /swapfile || true
fi

log "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
. /etc/os-release
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$FLOCI_USER"
systemctl enable --now docker

log "Installing Caddy"
if [ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
fi
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
  >/etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy
systemctl enable --now caddy

log "Installing Node.js 22, pnpm, and Bun"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g pnpm
sudo -H -u "$FLOCI_USER" bash -lc 'curl -fsSL https://bun.sh/install | bash'
PNPM_BIN="$(command -v pnpm)"

log "Creating Floci docker-compose project"
install -d -o "$FLOCI_USER" -g "$FLOCI_USER" "$FLOCI_DIR"
cat >"${FLOCI_DIR}/docker-compose.yml" <<EOF
services:
  floci:
    image: floci/floci:latest
    container_name: floci
    restart: unless-stopped
    user: root
    ports:
      - "127.0.0.1:4566:4566"
    environment:
      FLOCI_BASE_URL: "https://${FLOCI_API_DOMAIN}"
      FLOCI_STORAGE_MODE: "hybrid"
      FLOCI_STORAGE_PERSISTENT_PATH: "/app/data"
    volumes:
      - ./data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
EOF
chown "$FLOCI_USER:$FLOCI_USER" "${FLOCI_DIR}/docker-compose.yml"
sudo -H -u "$FLOCI_USER" bash -lc "cd '$FLOCI_DIR' && docker compose up -d"

log "Cloning or updating Floci UI"
if [ -d "${FLOCI_UI_DIR}/.git" ]; then
  sudo -H -u "$FLOCI_USER" bash -lc "cd '$FLOCI_UI_DIR' && git pull --ff-only"
else
  sudo -H -u "$FLOCI_USER" git clone https://github.com/floci-io/floci-ui.git "$FLOCI_UI_DIR"
fi

log "Configuring Floci UI environment"
cat >"${FLOCI_UI_DIR}/.env" <<EOF
FLOCI_ENDPOINT=http://127.0.0.1:4566
VITE_MOCK_MODE=false
AWS_REGION=${FLOCI_REGION}
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
PORT=3001
EOF
chown "$FLOCI_USER:$FLOCI_USER" "${FLOCI_UI_DIR}/.env"

log "Patching Vite allowedHosts for ${FLOCI_DASHBOARD_DOMAIN}"
VITE_CONFIG="${FLOCI_UI_DIR}/packages/frontend/vite.config.ts"
if [ -f "$VITE_CONFIG" ] && ! grep -q "allowedHosts" "$VITE_CONFIG"; then
  python3 - "$VITE_CONFIG" "$FLOCI_DASHBOARD_DOMAIN" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
domain = sys.argv[2]
text = path.read_text()

marker = "server: {"
if marker not in text:
    raise SystemExit(f"Could not find {marker!r} in {path}")

text = text.replace(
    marker,
    f"server: {{\n      allowedHosts: ['{domain}'],",
    1,
)
path.write_text(text)
PY
  chown "$FLOCI_USER:$FLOCI_USER" "$VITE_CONFIG"
fi

log "Installing Floci UI dependencies"
sudo -H -u "$FLOCI_USER" bash -lc "cd '$FLOCI_UI_DIR' && pnpm install"

log "Creating systemd services"
cat >/etc/systemd/system/floci-ui-api.service <<EOF
[Unit]
Description=Floci UI API
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=${FLOCI_USER}
WorkingDirectory=${FLOCI_UI_DIR}
Environment=HOME=${FLOCI_HOME}
Environment=PATH=${FLOCI_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${PNPM_BIN} --filter @floci/api start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/floci-ui-frontend.service <<EOF
[Unit]
Description=Floci UI Frontend
After=network-online.target floci-ui-api.service
Wants=network-online.target
Requires=floci-ui-api.service

[Service]
Type=simple
User=${FLOCI_USER}
WorkingDirectory=${FLOCI_UI_DIR}
Environment=HOME=${FLOCI_HOME}
Environment=PATH=${FLOCI_HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin
Environment=API_TARGET=http://127.0.0.1:3001
ExecStart=${PNPM_BIN} --filter @floci/frontend dev -- --host 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now floci-ui-api
systemctl enable --now floci-ui-frontend

log "Writing Caddy config"
cat >/etc/caddy/Caddyfile <<EOF
${FLOCI_API_DOMAIN} {
    reverse_proxy 127.0.0.1:4566
}

${FLOCI_DASHBOARD_DOMAIN} {
    reverse_proxy 127.0.0.1:3000
}
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy

log "Opening firewall safely"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
iptables -I INPUT -p tcp --dport 22 -j ACCEPT || true
iptables -I INPUT -p tcp --dport 80 -j ACCEPT || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true
netfilter-persistent save || true

log "Smoke tests"
for url in http://127.0.0.1:4566 http://127.0.0.1:3000; do
  ok=0
  for _ in $(seq 1 30); do
    if curl -fsSI "$url" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    echo "Smoke test failed for $url" >&2
    systemctl status floci-ui-api floci-ui-frontend caddy --no-pager || true
    exit 1
  fi
done
curl -fsS http://127.0.0.1:3001 >/dev/null 2>&1 || true

cat <<EOF

Done.

Dashboard: https://${FLOCI_DASHBOARD_DOMAIN}
API:       https://${FLOCI_API_DOMAIN}

Useful checks:
  docker compose -f ${FLOCI_DIR}/docker-compose.yml ps
  systemctl status floci-ui-api floci-ui-frontend caddy
  journalctl -u floci-ui-api -f
  journalctl -u floci-ui-frontend -f

AWS CLI endpoint:
  aws --profile floci --endpoint-url https://${FLOCI_API_DOMAIN} sts get-caller-identity

EOF
