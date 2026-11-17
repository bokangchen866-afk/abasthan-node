#!/bin/sh
# Route A - runtime wrapper for PaaS panels that give a runtime + file upload.
# Downloads xray-core at startup from the official XTLS GitHub release only,
# generates config.json from environment variables, then execs xray.
#
# TLS note: VLESS + WebSocket + TLS, with TLS terminated by the platform
# gateway / reverse proxy (the usual PaaS HTTPS entry). Xray itself listens
# for plain WebSocket on the internal port; do NOT expose this port directly
# to the public internet without the platform TLS entry in front of it.
# Bind note: PaaS convention is 0.0.0.0:$PORT (the platform router is the
# only thing that can reach it and it forwards to the container IP). If your
# platform forwards to loopback only, set BIND_ADDR=127.0.0.1.
set -eu

# --- required env -----------------------------------------------------------
: "${PORT:?PORT is required (assigned by the platform, never hardcode it)}"
: "${UUID:?UUID is required (generate at deploy time, store only in credentials.txt)}"
: "${WS_PATH:?WS_PATH is required, e.g. /ws}"
XRAY_VERSION="${XRAY_VERSION:-v25.8.3}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
WORKDIR="${WORKDIR:-$(pwd)/.xray-runtime}"

# Validate shapes without ever printing the secret value.
case "$PORT" in
  ''|*[!0-9]*) echo "error: PORT must be numeric" >&2; exit 2 ;;
esac
case "$UUID" in
  ????????-????-????-????-????????????) : ;;
  *) echo "error: UUID does not look like a UUID (value not shown)" >&2; exit 2 ;;
esac
case "$WS_PATH" in
  /*) : ;;
  *) WS_PATH="/$WS_PATH" ;;
esac

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- download xray-core from the official source only ---------------------
if [ ! -x ./xray ]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) echo "error: unsupported architecture: $arch" >&2; exit 2 ;;
  esac
  # Single official source. Do not substitute mirrors or third-party builds.
  base="https://github.com/XTLS/Xray-core/releases/download"
  url="$base/$XRAY_VERSION/$asset"
  case "$url" in
    https://github.com/XTLS/Xray-core/releases/download/*) : ;;
    *) echo "error: download URL does not point at github.com/XTLS/Xray-core" >&2; exit 2 ;;
  esac
  echo "downloading xray-core $XRAY_VERSION ($arch) from github.com/XTLS/Xray-core"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o xray.zip "$url"
    # Digest file published alongside the same official release.
    curl -fL --retry 3 -o xray.zip.dgst "$url.dgst" || echo "warn: no .dgst file fetched, continuing without digest check" >&2
  elif command -v wget >/dev/null 2>&1; then
    wget -O xray.zip "$url"
  else
    echo "error: need curl or wget to download xray-core" >&2; exit 2
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -o xray.zip xray geoip.dat geosite.dat >/dev/null
  else
    python3 -m zipfile -e xray.zip .
  fi
  chmod +x ./xray
  rm -f xray.zip
fi

# --- generate config.json (secret values are not echoed) -------------------
# Written with a heredoc; values come only from the environment above.
# DNS: same fix as Route B - DoH (TCP/443) first, system resolver last;
# plain UDP/53 DNS was the failing step on Bitsreef. See route-b/entrypoint.sh.
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "localhost"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "listen": "$BIND_ADDR",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "$WS_PATH" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
chmod 600 config.json

# Validate before starting; "config ok" does not by itself prove connectivity
# (that is what ../verify.sh is for, from a separate machine).
./xray run -test -config config.json

echo "starting xray: VLESS+WS on $BIND_ADDR:$PORT path $WS_PATH (TLS terminated by platform)"
exec ./xray run -config config.json
