#!/bin/bash
# =============================================================================
# NPI Registry MCP Server - Install & Start Script
# =============================================================================

set -e

MCP_PORT=3200
INSTALL_DIR="$HOME/npi-registry-mcp-server"
REPO_URL="https://github.com/eliotk/npi-registry-mcp-server.git"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   NPI Registry MCP Server Installer${NC}"
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
echo -e "${YELLOW}[1/5] Checking dependencies...${NC}"

if ! command -v git &>/dev/null; then
  echo -e "${RED}ERROR: git is not installed. Run: apt install git${NC}"
  exit 1
fi

if ! command -v uv &>/dev/null; then
  echo -e "${YELLOW}      uv not found — installing...${NC}"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi

if ! command -v mcp-proxy &>/dev/null; then
  echo -e "${YELLOW}      mcp-proxy not found — installing...${NC}"
  npm install -g mcp-proxy
fi

echo -e "${GREEN}      Dependencies OK${NC}"

# -----------------------------------------------------------------------------
# Clone or update repo
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[2/5] Setting up repository...${NC}"

if [ -d "$INSTALL_DIR/.git" ]; then
  echo -e "      Repo exists — pulling latest..."
  git -C "$INSTALL_DIR" pull
else
  echo -e "      Cloning from GitHub..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo -e "${GREEN}      Repository ready at: $INSTALL_DIR${NC}"

# -----------------------------------------------------------------------------
# Install Python dependencies
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[3/5] Installing Python dependencies...${NC}"

cd "$INSTALL_DIR"
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"

echo -e "${GREEN}      Python dependencies installed${NC}"

# -----------------------------------------------------------------------------
# Open firewall port
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[4/5] Configuring firewall...${NC}"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$MCP_PORT" > /dev/null 2>&1 && \
    echo -e "${GREEN}      Port $MCP_PORT opened via ufw${NC}" || \
    echo -e "${YELLOW}      ufw rule skipped (may already exist)${NC}"
elif command -v firewall-cmd &>/dev/null; then
  sudo firewall-cmd --add-port="${MCP_PORT}/tcp" --permanent > /dev/null 2>&1
  sudo firewall-cmd --reload > /dev/null 2>&1
  echo -e "${GREEN}      Port $MCP_PORT opened via firewalld${NC}"
else
  echo -e "${YELLOW}      No firewall manager found — ensure port $MCP_PORT is open manually${NC}"
fi

# -----------------------------------------------------------------------------
# Start MCP proxy
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[5/5] Starting NPI Registry MCP server...${NC}"

# Kill any existing instance on this port
if lsof -ti:$MCP_PORT > /dev/null 2>&1; then
  echo -e "      Stopping existing process on port $MCP_PORT..."
  kill $(lsof -ti:$MCP_PORT) 2>/dev/null || true
  sleep 1
fi

# Start mcp-proxy in background
nohup mcp-proxy --port "$MCP_PORT" -- \
  uv --directory "$INSTALL_DIR" run npi-registry-mcp-server \
  > "$INSTALL_DIR/mcp-proxy.log" 2>&1 &

PROXY_PID=$!
echo -e "      MCP proxy started (PID: $PROXY_PID)"

# Wait for it to be ready
echo -n "      Waiting for server to be ready"
for i in {1..15}; do
  sleep 1
  echo -n "."
  if curl -s "http://localhost:${MCP_PORT}/mcp" > /dev/null 2>&1; then
    break
  fi
done
echo ""

# Verify
if curl -s "http://localhost:${MCP_PORT}/mcp" > /dev/null 2>&1; then
  echo -e "${GREEN}      Server is up and responding${NC}"
else
  echo -e "${YELLOW}      Server may still be starting — check logs if issues occur${NC}"
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
echo -e "${CYAN}   Installation Complete!${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  ${GREEN}MCP URL:${NC}      ${CYAN}${MCP_URL}${NC}"
echo -e "  ${GREEN}Host IP:${NC}      ${HOST_IP}"
echo -e "  ${GREEN}Port:${NC}         ${MCP_PORT}"
echo -e "  ${GREEN}Install Dir:${NC}  ${INSTALL_DIR}"
echo -e "  ${GREEN}Log File:${NC}     ${INSTALL_DIR}/mcp-proxy.log"
echo -e "  ${GREEN}PID File:${NC}     ${INSTALL_DIR}/mcp-proxy.pid"
echo ""
echo -e "  ${YELLOW}Add this URL as your MCP server URL:${NC}"
echo -e "  ${CYAN}Create connector → MCP → Server URL${NC}"
echo -e "  ${CYAN}${MCP_URL}${NC}"
echo ""
echo -e "  ${YELLOW}To stop the server:${NC}"
echo -e "  kill \$(cat ${INSTALL_DIR}/mcp-proxy.pid)"
echo ""
echo -e "  ${YELLOW}To view logs:${NC}"
echo -e "  tail -f ${INSTALL_DIR}/mcp-proxy.log"
echo ""
