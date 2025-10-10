# docker_mcp MCP Server

A Model Context Protocol (MCP) server that exposes Docker Engine functionality to MCP clients (e.g., Claude Desktop via MCP gateway).

## Purpose

This MCP server allows AI assistants to list/manage containers, images, networks, volumes, stream short logs/stats and events, and execute commands inside containers by communicating with the Docker Engine (via the docker socket).

## Features

Current Implementation (tools available):
- list_containers - List containers with optional filters
- create_container - Create a container with image, command, env, mounts, ports, name
- start_container - Start a container
- stop_container - Stop a container
- restart_container - Restart a container
- kill_container - Kill a container with a signal
- pause_container / unpause_container - Pause and unpause containers
- remove_container - Remove a container
- inspect_container - Inspect container configuration
- attach_container - Attach and capture a short stdout/stderr stream
- get_logs - Get container logs (tail/follow with short capture)
- get_stats - Get short stats samples (CPU, memory, network)
- exec_create / exec_start - Create and start exec sessions
- list_images / inspect_image - List and inspect images
- pull_image / push_image - Pull and push images (supports auth_config JSON)
- build_image - Build images from a host path
- tag_image / remove_image - Tag and remove images
- list_volumes - List volumes
- list_networks / create_network / inspect_network / remove_network - Network management
- connect_network / disconnect_network - Connect/disconnect containers from networks
- get_info / get_version / system_df / ping - System info endpoints
- events - Capture Docker events for a short duration

## Prerequisites

- Docker Desktop or Docker Engine running on the host.
- Docker socket available at `/var/run/docker.sock` (default).
- Docker MCP Toolkit or Claude Desktop MCP gateway to run as a tool, or run directly for testing.
- Python 3.11 (image includes this).

## Installation (quick)

Build the docker image and run with access to the Docker socket (see installation instructions provided separately).

## Usage Examples

From an MCP client (natural language examples):
- "List running containers"
- "Create a container using nginx image, expose port 80 to 8080"
- "Start container abc123"
- "Get last 200 lines of logs from container myapp and follow for 5 seconds"
- "Pull nginx:latest from Docker Hub"

Direct testing locally:
```bash
# Run directly (for testing)
export DOCKER_SOCKET=/var/run/docker.sock
python docker_mcp_server.py

# Example: tools/list is an MCP method; as a quick protocol test you can send:
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | python docker_mcp_server.py