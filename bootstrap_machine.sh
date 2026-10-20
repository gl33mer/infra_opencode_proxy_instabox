#!/usr/bin/env bash
#
# bootstrap_machine.sh -- turn a fresh Ubuntu/Debian VM into an OpenCode + proxy research node.
#
# Steps, in order:
#   1. System packages, plus Docker Engine and Node.js >= 20 when missing.
#   2. OpenCode.
#   3. opencode-unlimited-proxy (accepting Cloudflare WARP's terms) and starts it.
#   4. ~/.config/opencode/opencode.json pointing at the local proxy.
#   5. Python venv for the SH-1 project with numpy/scipy/pyyaml/pandas/pytest.
#
# Idempotent: reuses existing checkouts, preserves non-empty values in the
# proxy's .env, and reruns cleanly after a failure.
#
# Overridable environment variables:
#   PROXY_DIR                 default: $HOME/opencode-unlimited-proxy
#   PROXY_API_KEY             default: local-test-key
#   PROXY_MODEL               default: deepseek-v4.1-flash-free
#   SH1_ROOT                  default: $HOME/sh1
#
# Usage:
#   ./bootstrap_machine.sh

set -euo pipefail

trap 'rc=$?; echo "ERROR: bootstrap failed at line $LINENO (exit $rc)" >&2' ERR

PROXY_DIR="${PROXY_DIR:-$HOME/opencode-unlimited-proxy}"
PROXY_STACK="$PROXY_DIR/stack"
PROXY_API_KEY="${PROXY_API_KEY:-local-test-key}"
PROXY_MODEL="${PROXY_MODEL:-deepseek-v4.1-flash-free}"
SH1_ROOT="${SH1_ROOT:-$HOME/sh1}"

step() { printf '\n==> %s\n' "$*"; }

# --- 1. System dependencies -------------------------------------------------
step "1/5 Installing system dependencies"
sudo apt-get update
sudo apt-get install -y git curl unzip ca-certificates ripgrep tmux htop jq python3-venv

step "1/5 Ensuring Docker and Node.js >= 20 are available"
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"

need_node=0
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    need_node=1
else
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if (( node_major < 20 )); then
        need_node=1
    fi
fi
if (( need_node )); then
    echo "    installing Node.js 22.x"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

DOCKER=(docker)
if ! command -v docker >/dev/null 2>&1; then
    echo "    installing Docker Engine"
    curl -fsSL https://get.docker.com | sudo sh
fi
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
else
    sudo service docker start >/dev/null 2>&1 || true
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "    installing the Docker Compose plugin"
    curl -fsSL https://get.docker.com | sudo sh
fi
if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
        echo "    current user cannot access Docker; using sudo for this run"
        sudo usermod -aG docker "$USER" >/dev/null 2>&1 || true
        DOCKER=(sudo docker)
    else
        echo "ERROR: Docker daemon is not reachable" >&2
        exit 1
    fi
fi

# --- 2. OpenCode ------------------------------------------------------------
step "2/5 Installing OpenCode"
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
if command -v opencode >/dev/null 2>&1; then
    echo "    already installed: $(opencode --version 2>/dev/null || echo unknown)"
else
    curl -fsSL https://opencode.ai/install | bash
    echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> ~/.bashrc
    export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
    hash -r
fi
if ! command -v opencode >/dev/null 2>&1; then
    echo "ERROR: opencode is not on PATH after installation" >&2
    exit 1
fi

# --- 3. Proxy ---------------------------------------------------------------
step "3/5 Cloning and starting opencode-unlimited-proxy"
if [[ -d "$PROXY_DIR/.git" ]]; then
    echo "    reusing existing checkout at $PROXY_DIR"
else
    git clone https://github.com/ebouther/opencode-unlimited-proxy.git "$PROXY_DIR"
fi

cd "$PROXY_STACK"
if [[ ! -f .env ]]; then
    cp .env.example .env
fi
sed -i 's/WARP_ACCEPT_TOS=0/WARP_ACCEPT_TOS=1/' .env
if ! grep -q '^WARP_ACCEPT_TOS=1$' .env; then
    printf '\nWARP_ACCEPT_TOS=1\n' >> .env
fi
"${DOCKER[@]}" compose up -d --build

step "3/5 Waiting for the proxy API"
proxy_ready=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null \
        -H "Authorization: Bearer $PROXY_API_KEY" \
        http://127.0.0.1:8080/v1/models; then
        proxy_ready=1
        break
    fi
    sleep 3
done
if (( ! proxy_ready )); then
    echo "ERROR: proxy API did not become ready at http://127.0.0.1:8080/v1" >&2
    "${DOCKER[@]}" compose ps >&2 || true
    "${DOCKER[@]}" compose logs --tail=50 >&2 || true
    exit 1
fi

# --- 4. OpenCode config -----------------------------------------------------
step "4/5 Writing ~/.config/opencode/opencode.json"
mkdir -p "$HOME/.config/opencode"
cat > "$HOME/.config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "unlimited-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Unlimited Proxy",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKey": "$PROXY_API_KEY"
      },
      "models": {
        "$PROXY_MODEL": { "name": "$PROXY_MODEL" }
      }
    }
  },
  "model": "unlimited-proxy/$PROXY_MODEL"
}
JSON

# --- 5. SH-1 project environment --------------------------------------------
step "5/5 Setting up the SH-1 project environment at $SH1_ROOT"
mkdir -p "$SH1_ROOT/spec" "$SH1_ROOT/fixtures" "$SH1_ROOT/configs" \
         "$SH1_ROOT/results/smoke" "$SH1_ROOT/sh1" "$SH1_ROOT/tests"
cd "$SH1_ROOT"
if [[ ! -d .venv ]]; then
    python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet numpy scipy pyyaml pandas pytest

step "Bootstrap complete"
echo "    OpenCode: $(opencode --version)"
echo "    Proxy:    http://127.0.0.1:8080/v1  (model: $PROXY_MODEL)"
echo "    SH-1:     $SH1_ROOT  (source .venv/bin/activate)"
