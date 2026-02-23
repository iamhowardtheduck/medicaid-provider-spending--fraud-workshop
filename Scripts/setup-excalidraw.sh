npm install -g mcp-proxy
docker pull ghcr.io/yctimlin/mcp_excalidraw-canvas:latest
docker run -d -p 3000:3000 --name mcp-excalidraw-canvas ghcr.io/yctimlin/mcp_excalidraw-canvas:latest
mcp-proxy --port 3100 -- docker run -i --rm --network host -e EXPRESS_SERVER_URL=http://localhost:3000 -e ENABLE_CANVAS_SYNC=true ghcr.io/yctimlin/mcp_excalidraw:latest
