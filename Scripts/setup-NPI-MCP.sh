#!/bin/bash
# =============================================================================
# NPI Registry MCP Server - Install & Start Script
# =============================================================================
set -e

MCP_PORT=3200
MCP_HOST=0.0.0.0
INSTALL_DIR="$HOME/npi-registry-mcp-server"
REPO_URL="https://github.com/eliotk/npi-registry-mcp-server.git"

# Strategy for resolving the fastmcp/mcp incompatibility.
# The upstream repo pins only "fastmcp>=0.2.0" (unbounded), so uv pulls fastmcp 2.9.x
# while mcp stays at 1.9.4 — and fastmcp 2.9 imports CreateMessageResultWithTools,
# which doesn't exist until mcp ~1.13. We constrain fastmcp back into its <2.0 era,
# which matches the code the repo was written against.
#
# Override at call time if you'd rather move mcp forward instead:
#   FASTMCP_CONSTRAINT="fastmcp>=2.9" MCP_EXTRA_PIN="mcp>=1.13.0" ./setup-NPI-MCP.sh
FASTMCP_CONSTRAINT="${FASTMCP_CONSTRAINT:-fastmcp<2.0}"
MCP_EXTRA_PIN="${MCP_EXTRA_PIN:-}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} NPI Registry MCP Server Installer${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# -----------------------------------------------------------------------------
# Detect host IP
# -----------------------------------------------------------------------------
HOST_IP=$(hostname -I | awk '{print $1}')
if [ -z "$HOST_IP" ]; then
  HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
fi
if [ -z "$HOST_IP" ]; then
  echo -e "${RED}ERROR: Could not detect host IP address.${NC}"
  exit 1
fi
MCP_URL="http://${HOST_IP}:${MCP_PORT}/mcp"

# -----------------------------------------------------------------------------
# Check dependencies
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[1/6] Checking dependencies...${NC}"
if ! command -v git &>/dev/null; then
  echo -e "${RED}ERROR: git is not installed. Run: apt install git${NC}"
  exit 1
fi
# Make sure the standard uv install location is on PATH for this session
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv &>/dev/null; then
  echo -e "${YELLOW} uv not found — installing...${NC}"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
# Resolve uv's absolute path — the proxy launches uv in a child process whose
# PATH may not include ~/.local/bin, which silently kills the stdio child.
UV_BIN="$(command -v uv)"
if [ -z "$UV_BIN" ]; then
  echo -e "${RED}ERROR: uv still not found after install attempt.${NC}"
  exit 1
fi
echo -e " Using uv at: ${UV_BIN}"
if ! command -v mcp-proxy &>/dev/null; then
  echo -e "${YELLOW} mcp-proxy not found — installing...${NC}"
  npm install -g mcp-proxy
fi
echo -e "${GREEN} Dependencies OK${NC}"

# -----------------------------------------------------------------------------
# Clone or update repo
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[2/6] Setting up repository...${NC}"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo -e " Repo exists — pulling latest..."
  git -C "$INSTALL_DIR" pull
else
  echo -e " Cloning from GitHub..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
echo -e "${GREEN} Repository ready at: $INSTALL_DIR${NC}"

# -----------------------------------------------------------------------------
# Pin fastmcp in pyproject.toml BEFORE installing.
#
# This is the durable fix: `uv run` re-resolves dependencies from pyproject.toml
# on every launch, so a post-install `uv pip install` pin gets silently reverted.
# Patching the manifest makes the constraint stick across re-syncs and re-runs.
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[3/6] Pinning fastmcp constraint in pyproject.toml...${NC}"
cd "$INSTALL_DIR"

# Back up once (don't clobber a good backup on re-runs)
[ -f pyproject.toml.orig ] || cp pyproject.toml pyproject.toml.orig

if grep -qE '"fastmcp[^"]*"' pyproject.toml; then
  # Replace whatever fastmcp constraint exists with our chosen one
  sed -i -E "s|\"fastmcp[^\"]*\"|\"${FASTMCP_CONSTRAINT}\"|g" pyproject.toml
  echo -e "${GREEN} fastmcp constraint set to: ${FASTMCP_CONSTRAINT}${NC}"
else
  echo -e "${YELLOW} No fastmcp line found in pyproject.toml — leaving manifest as-is${NC}"
fi
grep -E 'fastmcp|^\s*"mcp' pyproject.toml || true

# -----------------------------------------------------------------------------
# Install Python dependencies
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[4/6] Installing Python dependencies...${NC}"
"$UV_BIN" venv
source .venv/bin/activate
"$UV_BIN" pip install -e ".[dev]"

# Optional: also move mcp forward if the override was supplied
if [ -n "$MCP_EXTRA_PIN" ]; then
  echo -e " Applying extra mcp pin: ${MCP_EXTRA_PIN}"
  "$UV_BIN" pip install "$MCP_EXTRA_PIN"
fi
echo -e "${GREEN} Dependencies installed${NC}"

# -----------------------------------------------------------------------------
# Verify the import actually works before we try to launch
# -----------------------------------------------------------------------------
verify_import() {
  "$INSTALL_DIR/.venv/bin/python" -c "from npi_registry_mcp.server import main" >/dev/null 2>&1
}

echo -n " Verifying server import... "
if verify_import; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAILED${NC}"
  echo -e "${RED}Server still fails to import. Installed versions:${NC}"
  "$UV_BIN" pip show fastmcp mcp | grep -E 'Name|Version' || true
  echo ""
  echo -e "${YELLOW}Show the real traceback with:${NC}"
  echo -e "   cd $INSTALL_DIR && .venv/bin/python -c 'from npi_registry_mcp.server import main'"
  echo ""
  echo -e "${YELLOW}Or try moving mcp forward instead of fastmcp back:${NC}"
  echo -e "   FASTMCP_CONSTRAINT=\"fastmcp>=2.9\" MCP_EXTRA_PIN=\"mcp>=1.13.0\" $0"
  exit 1
fi
"$UV_BIN" pip show fastmcp mcp | grep -E 'Name|Version'

# -----------------------------------------------------------------------------
# Open firewall port
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[5/6] Configuring firewall...${NC}"
if command -v ufw &>/dev/null; then
  sudo ufw allow "$MCP_PORT" > /dev/null 2>&1 && \
    echo -e "${GREEN} Port $MCP_PORT opened via ufw${NC}" || \
    echo -e "${YELLOW} ufw rule skipped (may already exist)${NC}"
elif command -v firewall-cmd &>/dev/null; then
  sudo firewall-cmd --add-port="${MCP_PORT}/tcp" --permanent > /dev/null 2>&1
  sudo firewall-cmd --reload > /dev/null 2>&1
  echo -e "${GREEN} Port $MCP_PORT opened via firewalld${NC}"
else
  echo -e "${YELLOW} No firewall manager found — ensure port $MCP_PORT is open manually${NC}"
fi

# -----------------------------------------------------------------------------
# Start MCP proxy
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[6/6] Starting NPI Registry MCP server...${NC}"

# Kill any existing instance on this port
if lsof -ti:$MCP_PORT > /dev/null 2>&1; then
  echo -e " Stopping existing process on port $MCP_PORT..."
  kill $(lsof -ti:$MCP_PORT) 2>/dev/null || true
  sleep 1
fi

# Start mcp-proxy in background, bound to all interfaces so the connector can reach it
# Start mcp-proxy in background, bound to all interfaces so the connector can reach it.
# Launch the venv's console-script directly (NOT `uv run`, which re-resolves deps
# from pyproject.toml on every start and can reintroduce the version mismatch).
nohup mcp-proxy --host "$MCP_HOST" --port "$MCP_PORT" -- \
  "$INSTALL_DIR/.venv/bin/npi-registry-mcp-server" \
  > "$INSTALL_DIR/mcp-proxy.log" 2>&1 &
PROXY_PID=$!
echo -e " MCP proxy started (PID: $PROXY_PID)"

# Wait for it to be ready — check the process is alive AND the port is listening
echo -n " Waiting for server to be ready"
READY=0
for i in {1..15}; do
  sleep 1
  echo -n "."
  # Proxy process must still be alive
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo ""
    echo -e "${RED} Proxy process exited early — check the log:${NC}"
    tail -30 "$INSTALL_DIR/mcp-proxy.log"
    exit 1
  fi
  # A live streamable-HTTP endpoint answers (often 400/406 to a bare GET, not 000)
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${MCP_PORT}/mcp" 2>/dev/null || echo 000)
  if [ "$CODE" != "000" ]; then
    READY=1
    break
  fi
done
echo ""

if [ "$READY" -eq 1 ]; then
  echo -e "${GREEN} Server is up and responding (HTTP ${CODE})${NC}"
else
  echo -e "${YELLOW} Server not responding yet — check ${INSTALL_DIR}/mcp-proxy.log${NC}"
fi

# -----------------------------------------------------------------------------
# Save PID for later management
# -----------------------------------------------------------------------------
echo "$PROXY_PID" > "$INSTALL_DIR/mcp-proxy.pid"

# -----------------------------------------------------------------------------
# Print summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} Installation Complete!${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e " ${GREEN}MCP URL:${NC} ${CYAN}${MCP_URL}${NC}"
echo -e " ${GREEN}Host IP:${NC} ${HOST_IP}"
echo -e " ${GREEN}Bind:${NC} ${MCP_HOST}:${MCP_PORT}"
echo -e " ${GREEN}Install Dir:${NC} ${INSTALL_DIR}"
echo -e " ${GREEN}Log File:${NC} ${INSTALL_DIR}/mcp-proxy.log"
echo -e " ${GREEN}PID File:${NC} ${INSTALL_DIR}/mcp-proxy.pid"
echo ""
echo -e " ${YELLOW}Add this URL as your MCP server URL:${NC}"
echo -e " ${CYAN}Create connector → MCP → Server URL${NC}"
echo -e " ${CYAN}${MCP_URL}${NC}"
echo ""
echo -e " ${YELLOW}To stop the server:${NC}"
echo -e " kill \$(cat ${INSTALL_DIR}/mcp-proxy.pid)"
echo ""
echo -e " ${YELLOW}To view logs:${NC}"
echo -e " tail -f ${INSTALL_DIR}/mcp-proxy.log"
echo ""
