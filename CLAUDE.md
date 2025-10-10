# CLAUDE.md
name: docker-mcp
version: 1.0.0
description: |
  MCP server that exposes Docker Engine API as tools for managing containers, images,
  networks, and volumes directly from Claude Desktop. Supports live logs, stats, and
  exec streaming over the Docker socket.

command: ["python3", "docker_mcp_server.py"]

docker:
  image: docker_mcp-server:latest
  mount_socket: true

env:
  - name: DOCKER_SOCKET
    description: Path to Docker socket (default: /var/run/docker.sock)
    required: false

  - name: DOCKER_HOST
    description: Optional Docker TCP endpoint (e.g., tcp://localhost:2375)
    required: false

  - name: MCP_API_TOKEN
    description: Optional token for simple authentication between Claude and the MCP server
    required: false

permissions:
  - docker:read
  - docker:write

secrets:
  - name: DOCKER_REGISTRY_AUTH
    description: |
      Docker registry credentials (base64 JSON or auth token) used for image pull/push.
      Optional if already logged in via Docker CLI.

capabilities:
  - containers.list
  - containers.inspect
  - containers.create
  - containers.start
  - containers.stop
  - containers.remove
  - containers.logs
  - containers.stats
  - containers.exec
  - images.list
  - images.pull
  - images.push
  - images.build
  - networks.list
  - volumes.list
  - system.info
  - system.events
