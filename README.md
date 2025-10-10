# SECTION 1: FILES TO CREATE

Create exactly these 5 files with the exact content below.

---

## File 1 — `Dockerfile`

```dockerfile
# Use Python slim image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Set Python unbuffered mode
ENV PYTHONUNBUFFERED=1

# Copy requirements first for better caching
COPY requirements.txt .

# Install dependencies and system packages for docker socket access and tar handling
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    libffi-dev \
    gcc \
    tar \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt

# Copy the server code
COPY docker_mcp_server.py .

# Create non-root user
RUN useradd -m -u 1000 mcpuser && \
    chown -R mcpuser:mcpuser /app

# Switch to non-root user
USER mcpuser

# Default command
CMD ["python", "docker_mcp_server.py"]
```

---

## File 2 — `requirements.txt`

```
mcp[cli]>=1.2.0
docker>=6.0.0
httpx>=0.25.0
```

---

## File 3 — `docker_mcp_server.py`

```python
#!/usr/bin/env python3
"""docker_mcp - MCP server exposing Docker Engine operations via MCP tools."""

import os
import sys
import logging
import json
import time
import base64
import io
from datetime import datetime, timezone

import docker
from docker.errors import DockerException, NotFound, APIError

from mcp.server.fastmcp import FastMCP

# Configure logging to stderr
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("docker_mcp-server")

# Initialize MCP server (no prompt param!)
mcp = FastMCP("docker_mcp")

# Docker client factory to allow reconnects
def get_docker_client():
    """Return a docker client connected to the local daemon."""
    try:
        # If DOCKER_HOST is set, docker.from_env will respect it
        client = docker.from_env()
        return client
    except Exception as e:
        logger.error(f"Failed to create docker client: {e}")
        raise

# Utility: safe JSON formatting
def _fmt_json_safe(obj):
    """Return a pretty JSON string representation or a fallback."""
    try:
        return json.dumps(obj, indent=2, default=str)
    except Exception:
        return str(obj)

# === MCP Tools ===

@mcp.tool()
async def list_containers(all: str = "false", filters: str = "") -> str:
    """List containers with optional filters (filters JSON string)."""
    try:
        client = get_docker_client()
        all_bool = all.strip().lower() in ("1", "true", "yes")
        filters_obj = {}
        if filters.strip():
            try:
                filters_obj = json.loads(filters)
            except Exception:
                return "❌ Error: filters must be a valid JSON string"
        containers = client.containers.list(all=all_bool, filters=filters_obj)
        results = []
        for c in containers:
            results.append({
                "id": c.short_id,
                "name": c.name,
                "image": c.image.tags,
                "status": c.status,
            })
        return "📦 Containers:\n" + _fmt_json_safe(results)
    except Exception as e:
        logger.error(f"list_containers error: {e}", exc_info=True)
        return f"❌ Error listing containers: {str(e)}"

@mcp.tool()
async def create_container(image: str = "", command: str = "", env: str = "", mounts: str = "", ports: str = "", name: str = "") -> str:
    """Create a new container with given image, command, env, mounts, ports, and name."""
    if not image.strip():
        return "❌ Error: image is required"
    try:
        client = get_docker_client()
        env_list = []
        if env.strip():
            try:
                env_obj = json.loads(env)
                if isinstance(env_obj, dict):
                    env_list = [f"{k}={v}" for k, v in env_obj.items()]
                elif isinstance(env_obj, list):
                    env_list = env_obj
                else:
                    return "❌ Error: env must be JSON object or array"
            except Exception:
                return "❌ Error: env must be valid JSON"
        host_config = {}
        kwargs = {}
        if name.strip():
            kwargs["name"] = name.strip()
        # Ports and mounts handling (simple)
        port_bindings = {}
        if ports.strip():
            try:
                ports_obj = json.loads(ports)
                kwargs["ports"] = ports_obj
            except Exception:
                return "❌ Error: ports must be valid JSON (e.g. {\"80/tcp\": 8080})"
        if mounts.strip():
            try:
                mounts_obj = json.loads(mounts)
                kwargs["volumes"] = mounts_obj
            except Exception:
                return "❌ Error: mounts must be valid JSON (e.g. {\"/host/path\": {\"bind\": \"/container/path\", \"mode\": \"rw\"}})"
        # Create
        container = client.containers.create(image=image.strip(), command=command.strip() or None, environment=env_list or None, detach=True, **kwargs)
        return f"✅ Created container {container.short_id} ({container.name})"
    except APIError as e:
        logger.error(f"create_container APIError: {e}", exc_info=True)
        return f"❌ Docker API Error: {str(e)}"
    except Exception as e:
        logger.error(f"create_container error: {e}", exc_info=True)
        return f"❌ Error creating container: {str(e)}"

@mcp.tool()
async def start_container(container_id: str = "") -> str:
    """Start a container by id or name."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        c.start()
        return f"✅ Started container {c.short_id} ({c.name})"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"start_container error: {e}", exc_info=True)
        return f"❌ Error starting container: {str(e)}"

@mcp.tool()
async def stop_container(container_id: str = "", timeout: str = "10") -> str:
    """Stop a container by id or name with optional timeout seconds."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        to = int(timeout) if timeout.strip() else 10
        c.stop(timeout=to)
        return f"✅ Stopped container {c.short_id} ({c.name})"
    except ValueError:
        return "❌ Error: timeout must be an integer"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"stop_container error: {e}", exc_info=True)
        return f"❌ Error stopping container: {str(e)}"

@mcp.tool()
async def restart_container(container_id: str = "", timeout: str = "10") -> str:
    """Restart a container by id or name with optional timeout seconds."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        to = int(timeout) if timeout.strip() else 10
        c.restart(timeout=to)
        return f"✅ Restarted container {c.short_id} ({c.name})"
    except ValueError:
        return "❌ Error: timeout must be an integer"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"restart_container error: {e}", exc_info=True)
        return f"❌ Error restarting container: {str(e)}"

@mcp.tool()
async def kill_container(container_id: str = "", signal: str = "SIGKILL") -> str:
    """Kill a container with an optional signal."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        c.kill(signal=signal.strip() or None)
        return f"✅ Killed container {c.short_id} ({c.name}) with signal {signal}"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"kill_container error: {e}", exc_info=True)
        return f"❌ Error killing container: {str(e)}"

@mcp.tool()
async def pause_container(container_id: str = "") -> str:
    """Pause a container."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        c.pause()
        return f"✅ Paused container {c.short_id} ({c.name})"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"pause_container error: {e}", exc_info=True)
        return f"❌ Error pausing container: {str(e)}"

@mcp.tool()
async def unpause_container(container_id: str = "") -> str:
    """Unpause a container."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        c.unpause()
        return f"✅ Unpaused container {c.short_id} ({c.name})"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"unpause_container error: {e}", exc_info=True)
        return f"❌ Error unpausing container: {str(e)}"

@mcp.tool()
async def remove_container(container_id: str = "", force: str = "false") -> str:
    """Remove a container optionally forcing removal."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        c = client.containers.get(container_id.strip())
        force_bool = force.strip().lower() in ("1", "true", "yes")
        c.remove(force=force_bool)
        return f"✅ Removed container {container_id} (force={force_bool})"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"remove_container error: {e}", exc_info=True)
        return f"❌ Error removing container: {str(e)}"

@mcp.tool()
async def inspect_container(container_id: str = "") -> str:
    """Inspect a container and return its configuration JSON."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        info = client.api.inspect_container(container_id.strip())
        return "🔍 Container inspect:\n" + _fmt_json_safe(info)
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"inspect_container error: {e}", exc_info=True)
        return f"❌ Error inspecting container: {str(e)}"

@mcp.tool()
async def attach_container(container_id: str = "", logs: str = "false", stream_seconds: str = "5") -> str:
    """Attach to a container's stdout/stderr and capture a short stream (seconds)."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        stream_secs = int(stream_seconds) if stream_seconds.strip() else 5
        container = client.containers.get(container_id.strip())
        # Use low-level API attach streaming for up to stream_secs seconds
        sock = client.api.attach(container=container.id, stdout=1, stderr=1, stream=True, logs=logs.strip().lower() in ("1", "true", "yes"))
        output = []
        start = time.time()
        try:
            for chunk in sock:
                if not chunk:
                    break
                # chunk is raw bytes
                try:
                    output.append(chunk.decode("utf-8", errors="replace"))
                except Exception:
                    output.append(str(chunk))
                if time.time() - start > stream_secs:
                    break
        finally:
            # detach is managed by closing iterator
            pass
        return "📡 Attach output:\n" + "".join(output) if output else "📡 Attach: no output captured"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"attach_container error: {e}", exc_info=True)
        return f"❌ Error attaching to container: {str(e)}"

@mcp.tool()
async def get_logs(container_id: str = "", tail: str = "100", follow: str = "false", since: str = "") -> str:
    """Get logs from a container with tail, follow (short), and since timestamp (unix)."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        tail_arg = tail.strip() or "100"
        follow_bool = follow.strip().lower() in ("1", "true", "yes")
        since_arg = None
        if since.strip():
            try:
                since_arg = int(since.strip())
            except Exception:
                return "❌ Error: since must be a unix timestamp integer"
        # If follow requested, capture for up to 5 seconds to avoid background streams
        if follow_bool:
            stream = client.api.logs(container=container_id.strip(), stdout=True, stderr=True, tail=tail_arg, since=since_arg, stream=True, follow=True)
            collected = []
            start = time.time()
            for chunk in stream:
                if not chunk:
                    break
                try:
                    collected.append(chunk.decode("utf-8", errors="replace"))
                except Exception:
                    collected.append(str(chunk))
                if time.time() - start > 5:
                    break
            return "📝 Logs (follow partial):\n" + "".join(collected)
        else:
            logs = client.api.logs(container=container_id.strip(), stdout=True, stderr=True, tail=tail_arg, since=since_arg)
            try:
                logs_dec = logs.decode("utf-8", errors="replace")
            except Exception:
                logs_dec = str(logs)
            return "📝 Logs:\n" + logs_dec
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"get_logs error: {e}", exc_info=True)
        return f"❌ Error fetching logs: {str(e)}"

@mcp.tool()
async def get_stats(container_id: str = "", samples: str = "3") -> str:
    """Get short CPU/memory/network stats for a container with a small sample count."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    try:
        client = get_docker_client()
        samp = int(samples) if samples.strip() else 3
        stream = client.api.stats(container=container_id.strip(), stream=True)
        results = []
        count = 0
        for raw in stream:
            try:
                j = json.loads(raw.decode("utf-8", errors="replace"))
            except Exception:
                try:
                    j = json.loads(str(raw))
                except Exception:
                    j = {"raw": str(raw)}
            # Simplify stats for readability
            cpu = j.get("cpu_stats", {})
            mem = j.get("memory_stats", {})
            nets = j.get("networks", {})
            results.append({
                "cpu": cpu.get("cpu_usage", {}).get("total_usage"),
                "memory": mem.get("usage"),
                "memory_limit": mem.get("limit"),
                "networks": {k: v.get("rx_bytes", 0) + v.get("tx_bytes", 0) for k, v in nets.items()} if isinstance(nets, dict) else nets,
                "read": j.get("read"),
            })
            count += 1
            if count >= samp:
                break
        return "📊 Stats samples:\n" + _fmt_json_safe(results)
    except ValueError:
        return "❌ Error: samples must be an integer"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"get_stats error: {e}", exc_info=True)
        return f"❌ Error getting stats: {str(e)}"

@mcp.tool()
async def exec_create(container_id: str = "", cmd: str = "", tty: str = "false", stdin: str = "false") -> str:
    """Create an exec instance in a running container (returns exec id)."""
    if not container_id.strip():
        return "❌ Error: container_id is required"
    if not cmd.strip():
        return "❌ Error: cmd is required"
    try:
        client = get_docker_client()
        tty_bool = tty.strip().lower() in ("1", "true", "yes")
        stdin_bool = stdin.strip().lower() in ("1", "true", "yes")
        exec_id = client.api.exec_create(container=container_id.strip(), cmd=cmd.strip().split(), tty=tty_bool, stdin=stdin_bool)
        return f"✅ Exec created: {exec_id.get('Id')}"
    except NotFound:
        return f"❌ Error: container not found: {container_id}"
    except Exception as e:
        logger.error(f"exec_create error: {e}", exc_info=True)
        return f"❌ Error creating exec: {str(e)}"

@mcp.tool()
async def exec_start(exec_id: str = "", detach: str = "false", timeout: str = "5") -> str:
    """Start a previously created exec instance and capture output (short)."""
    if not exec_id.strip():
        return "❌ Error: exec_id is required"
    try:
        client = get_docker_client()
        detach_bool = detach.strip().lower() in ("1", "true", "yes")
        out = client.api.exec_start(exec_id.strip(), detach=detach_bool, tty=False, stream=False)
        try:
            decoded = out.decode("utf-8", errors="replace")
        except Exception:
            decoded = str(out)
        return "💻 Exec output:\n" + decoded
    except Exception as e:
        logger.error(f"exec_start error: {e}", exc_info=True)
        return f"❌ Error starting exec: {str(e)}"

# Images

@mcp.tool()
async def list_images(all: str = "false") -> str:
    """List images available on the daemon."""
    try:
        client = get_docker_client()
        imgs = client.images.list(all=all.strip().lower() in ("1", "true", "yes"))
        out = []
        for i in imgs:
            out.append({"id": i.short_id, "tags": i.tags})
        return "🖼️ Images:\n" + _fmt_json_safe(out)
    except Exception as e:
        logger.error(f"list_images error: {e}", exc_info=True)
        return f"❌ Error listing images: {str(e)}"

@mcp.tool()
async def inspect_image(name: str = "") -> str:
    """Inspect image details by name or id."""
    if not name.strip():
        return "❌ Error: image name is required"
    try:
        client = get_docker_client()
        info = client.api.inspect_image(name.strip())
        return "🔍 Image inspect:\n" + _fmt_json_safe(info)
    except NotFound:
        return f"❌ Error: image not found: {name}"
    except Exception as e:
        logger.error(f"inspect_image error: {e}", exc_info=True)
        return f"❌ Error inspecting image: {str(e)}"

@mcp.tool()
async def pull_image(fromImage: str = "", tag: str = "latest", auth_config: str = "") -> str:
    """Pull an image from a registry with optional auth_config (JSON)."""
    if not fromImage.strip():
        return "❌ Error: fromImage is required"
    try:
        client = get_docker_client()
        auth = None
        if auth_config.strip():
            try:
                auth = json.loads(auth_config)
            except Exception:
                return "❌ Error: auth_config must be valid JSON"
        for line in client.api.pull(repository=fromImage.strip(), tag=tag.strip(), stream=True, decode=True, auth_config=auth):
            # return the last status line as result summary
            last = line
        return f"✅ Pulled image {fromImage}:{tag} — last event: {_fmt_json_safe(last)}"
    except APIError as e:
        logger.error(f"pull_image APIError: {e}", exc_info=True)
        return f"❌ Docker API Error: {str(e)}"
    except Exception as e:
        logger.error(f"pull_image error: {e}", exc_info=True)
        return f"❌ Error pulling image: {str(e)}"

@mcp.tool()
async def build_image(path: str = "", tag: str = "", dockerfile: str = "Dockerfile") -> str:
    """Build an image from path (host path accessible to daemon) with optional tag."""
    if not path.strip():
        return "❌ Error: path to build context is required"
    try:
        client = get_docker_client()
        # Build using client.api.build
        stream = client.api.build(path=path.strip(), tag=tag.strip() or None, dockerfile=dockerfile.strip(), decode=True)
        last = None
        logs = []
        for chunk in stream:
            logs.append(chunk)
            last = chunk
        return "🛠️ Build completed:\n" + _fmt_json_safe({"last": last, "logs_count": len(logs)})
    except APIError as e:
        logger.error(f"build_image APIError: {e}", exc_info=True)
        return f"❌ Docker API Error: {str(e)}"
    except Exception as e:
        logger.error(f"build_image error: {e}", exc_info=True)
        return f"❌ Error building image: {str(e)}"

@mcp.tool()
async def push_image(name: str = "", tag: str = "latest", auth_config: str = "") -> str:
    """Push an image to a registry using name:tag and optional auth_config (JSON)."""
    if not name.strip():
        return "❌ Error: image name is required"
    try:
        client = get_docker_client()
        auth = None
        if auth_config.strip():
            try:
                auth = json.loads(auth_config)
            except Exception:
                return "❌ Error: auth_config must be valid JSON"
        stream = client.api.push(repository=name.strip(), tag=tag.strip(), stream=True, decode=True, auth_config=auth)
        last = None
        events = []
        for ev in stream:
            events.append(ev)
            last = ev
        return "📤 Push completed:\n" + _fmt_json_safe({"last": last, "events": events[-10:]})
    except APIError as e:
        logger.error(f"push_image APIError: {e}", exc_info=True)
        return f"❌ Docker API Error: {str(e)}"
    except Exception as e:
        logger.error(f"push_image error: {e}", exc_info=True)
        return f"❌ Error pushing image: {str(e)}"

@mcp.tool()
async def tag_image(name: str = "", repository: str = "", tag: str = "latest") -> str:
    """Tag an image: docker tag name repository:tag."""
    if not name.strip() or not repository.strip():
        return "❌ Error: name and repository are required"
    try:
        client = get_docker_client()
        img = client.images.get(name.strip())
        img.tag(repository.strip(), tag.strip())
        return f"✅ Tagged image {name} -> {repository}:{tag}"
    except NotFound:
        return f"❌ Error: image not found: {name}"
    except Exception as e:
        logger.error(f"tag_image error: {e}", exc_info=True)
        return f"❌ Error tagging image: {str(e)}"

@mcp.tool()
async def remove_image(name: str = "", force: str = "false") -> str:
    """Remove an image by name or id with optional force."""
    if not name.strip():
        return "❌ Error: image name is required"
    try:
        client = get_docker_client()
        client.images.remove(image=name.strip(), force=force.strip().lower() in ("1", "true", "yes"))
        return f"✅ Removed image {name}"
    except APIError as e:
        logger.error(f"remove_image APIError: {e}", exc_info=True)
        return f"❌ Docker API Error: {str(e)}"
    except Exception as e:
        logger.error(f"remove_image error: {e}", exc_info=True)
        return f"❌ Error removing image: {str(e)}"

# Volumes & Networks

@mcp.tool()
async def list_volumes() -> str:
    """List docker volumes."""
    try:
        client = get_docker_client()
        vols = client.volumes.list()
        out = [{"name": v.name, "mountpoint": v.attrs.get("Mountpoint")} for v in vols]
        return "📁 Volumes:\n" + _fmt_json_safe(out)
    except Exception as e:
        logger.error(f"list_volumes error: {e}", exc_info=True)
        return f"❌ Error listing volumes: {str(e)}"

@mcp.tool()
async def list_networks() -> str:
    """List docker networks."""
    try:
        client = get_docker_client()
        nets = client.networks.list()
        out = [{"id": n.id, "name": n.name, "driver": n.attrs.get("Driver")} for n in nets]
        return "🌐 Networks:\n" + _fmt_json_safe(out)
    except Exception as e:
        logger.error(f"list_networks error: {e}", exc_info=True)
        return f"❌ Error listing networks: {str(e)}"

@mcp.tool()
async def create_network(name: str = "", driver: str = "bridge") -> str:
    """Create a docker network with a name and optional driver."""
    if not name.strip():
        return "❌ Error: network name is required"
    try:
        client = get_docker_client()
        net = client.networks.create(name.strip(), driver=driver.strip() or "bridge")
        return f"✅ Created network {net.id} ({net.name})"
    except Exception as e:
        logger.error(f"create_network error: {e}", exc_info=True)
        return f"❌ Error creating network: {str(e)}"

@mcp.tool()
async def inspect_network(network_id: str = "") -> str:
    """Inspect a network by id or name."""
    if not network_id.strip():
        return "❌ Error: network_id is required"
    try:
        client = get_docker_client()
        net = client.networks.get(network_id.strip())
        return "🔍 Network inspect:\n" + _fmt_json_safe(net.attrs)
    except NotFound:
        return f"❌ Error: network not found: {network_id}"
    except Exception as e:
        logger.error(f"inspect_network error: {e}", exc_info=True)
        return f"❌ Error inspecting network: {str(e)}"

@mcp.tool()
async def remove_network(network_id: str = "") -> str:
    """Remove a network by id or name."""
    if not network_id.strip():
        return "❌ Error: network_id is required"
    try:
        client = get_docker_client()
        net = client.networks.get(network_id.strip())
        net.remove()
        return f"✅ Removed network {network_id}"
    except NotFound:
        return f"❌ Error: network not found: {network_id}"
    except Exception as e:
        logger.error(f"remove_network error: {e}", exc_info=True)
        return f"❌ Error removing network: {str(e)}"

@mcp.tool()
async def connect_network(network_id: str = "", container_id: str = "") -> str:
    """Connect a container to a network."""
    if not network_id.strip() or not container_id.strip():
        return "❌ Error: network_id and container_id are required"
    try:
        client = get_docker_client()
        net = client.networks.get(network_id.strip())
        net.connect(container_id.strip())
        return f"✅ Connected container {container_id} to network {network_id}"
    except Exception as e:
        logger.error(f"connect_network error: {e}", exc_info=True)
        return f"❌ Error connecting to network: {str(e)}"

@mcp.tool()
async def disconnect_network(network_id: str = "", container_id: str = "") -> str:
    """Disconnect a container from a network."""
    if not network_id.strip() or not container_id.strip():
        return "❌ Error: network_id and container_id are required"
    try:
        client = get_docker_client()
        net = client.networks.get(network_id.strip())
        net.disconnect(container_id.strip())
        return f"✅ Disconnected container {container_id} from network {network_id}"
    except Exception as e:
        logger.error(f"disconnect_network error: {e}", exc_info=True)
        return f"❌ Error disconnecting from network: {str(e)}"

# System / Info

@mcp.tool()
async def get_info() -> str:
    """Get Docker system info."""
    try:
        client = get_docker_client()
        info = client.info()
        return "ℹ️ Docker info:\n" + _fmt_json_safe(info)
    except Exception as e:
        logger.error(f"get_info error: {e}", exc_info=True)
        return f"❌ Error getting info: {str(e)}"

@mcp.tool()
async def get_version() -> str:
    """Get Docker version."""
    try:
        client = get_docker_client()
        v = client.version()
        return "🔢 Version:\n" + _fmt_json_safe(v)
    except Exception as e:
        logger.error(f"get_version error: {e}", exc_info=True)
        return f"❌ Error getting version: {str(e)}"

@mcp.tool()
async def system_df() -> str:
    """Get Docker disk usage (system df)."""
    try:
        client = get_docker_client()
        df = client.df()
        return "💽 System disk usage:\n" + _fmt_json_safe(df)
    except Exception as e:
        logger.error(f"system_df error: {e}", exc_info=True)
        return f"❌ Error running system df: {str(e)}"

@mcp.tool()
async def ping() -> str:
    """Ping the Docker daemon (_ping)."""
    try:
        client = get_docker_client()
        # low-level ping
        res = client.api.ping()
        return "🏓 Docker daemon ping: pong" if res else "⚠️ Docker daemon ping: no response"
    except Exception as e:
        logger.error(f"ping error: {e}", exc_info=True)
        return f"❌ Error pinging daemon: {str(e)}"

@mcp.tool()
async def events(seconds: str = "5") -> str:
    """Listen to docker events for a short duration (seconds) and return them."""
    try:
        client = get_docker_client()
        sec = int(seconds) if seconds.strip() else 5
        since_ts = int(time.time())
        stream = client.events(decode=True, since=since_ts)
        collected = []
        start = time.time()
        for ev in stream:
            collected.append(ev)
            if time.time() - start >= sec:
                break
        return "📣 Docker events (short capture):\n" + _fmt_json_safe(collected)
    except ValueError:
        return "❌ Error: seconds must be an integer"
    except Exception as e:
        logger.error(f"events error: {e}", exc_info=True)
        return f"❌ Error listening to events: {str(e)}"

# === Server startup ===

if __name__ == "__main__":
    logger.info("Starting docker_mcp MCP server...")
    # Optional guard: check DOCKER socket
    sock = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
    if not os.path.exists(sock):
        logger.warning(f"Docker socket not found at {sock}; ensure the socket is available or set DOCKER_HOST")
    try:
        mcp.run(transport="stdio")
    except Exception as e:
        logger.error(f"Server error: {e}", exc_info=True)
        sys.exit(1)
```

---

## File 4 — `readme.txt`

````markdown
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
```
````

## Security considerations

- This server interacts with the Docker socket. Mounting `/var/run/docker.sock` into a container grants the container effective control over the host and is a significant security risk.
- Do NOT expose the Docker socket to untrusted networks or users.
- Registry credentials should be provided via Docker secrets or auth_config JSON (not hardcoded).
- The server runs as a non-root user inside the container, but access to the socket defeats process isolation.

## Extending

- Add persistence for events or logs (SQLite/Postgres) if you want history across restarts.
- Add OAuth or API token checks at the MCP tool level if the gateway does not provide authentication.
- Improve streaming by integrating a websocket or long-lived transport; current design captures short streaming windows to respect MCP tool semantics.

## License

MIT

````

---

## File 5 — `CLAUDE.md`

```markdown
# Implementation notes for docker_mcp MCP Server

## Overview
This document explains implementation details, developer guidelines and how the server maps Docker Engine API functionality to MCP tools.

## Key design choices
- Uses the official `docker` Python SDK (docker-py) to interact with the Docker Engine via socket or DOCKER_HOST.
- All MCP tools return strings and provide friendly emoji-based responses.
- Tools follow the single-line docstring rule required by MCP usage guidelines.
- The server is stateless by default and captures short streaming windows when requested (to avoid background tasks).
- Logging to stderr for diagnostics.

## How tools map to Docker API
- list_containers -> client.containers.list
- create_container -> client.containers.create
- start/stop/restart -> client.containers.get(...).start/stop/restart
- attach_container -> client.api.attach with stream for a limited time
- get_logs -> client.api.logs with follow option limited to a short duration
- get_stats -> client.api.stats consumed for N samples
- exec_create / exec_start -> client.api.exec_create and exec_start
- images -> client.images and client.api methods (pull/push/build)
- networks/volumes -> client.networks and client.volumes

## Developer guidelines
- Keep tool docstrings to a single line.
- Use simple param defaults like param: str = "".
- Always return strings and handle exceptions to avoid unhandled errors.
- Avoid long-running background streaming — capture short windows and return aggregated results.

## Adding tools
1. Add an async function decorated with @mcp.tool()
2. Keep the docstring single-line
3. Use get_docker_client() for docker interactions
4. Return a formatted string, handle errors, and log to stderr

## Troubleshooting
- If tools can't connect to Docker, confirm socket path permissions and DOCKER_HOST.
- For push/pull auth errors, confirm docker login on host or provide valid auth_config JSON.

## Notes
- The server is intended for local development and use with MCP gateways (e.g., Claude Desktop). Exercise care when mounting the Docker socket into containers.

````

---

# SECTION 2: INSTALLATION INSTRUCTIONS FOR THE USER

Follow these exact numbered steps to build and run the MCP server locally and register it with Claude Desktop / Docker MCP Gateway.

1. Create project directory and save files

```bash
mkdir docker_mcp-mcp-server
cd docker_mcp-mcp-server

# Save these files into this directory:
# - Dockerfile
# - requirements.txt
# - docker_mcp_server.py
# - readme.txt
# - CLAUDE.md
```

2. Build the Docker image

```bash
docker build -t docker_mcp-server:latest .
```

3. Run the server container (recommended) with access to the Docker socket

```bash
# Run as interactive (keeps STDIO open) so MCP gateway can communicate via stdio
docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DOCKER_SOCKET=/var/run/docker.sock \
  docker_mcp-server:latest
```

This will run the MCP server and use stdio transport by default. If you run via an MCP gateway, the gateway will launch the container with appropriate args.

4. (Optional) Run locally without Docker (for development)

```bash
# Install python deps locally (virtualenv recommended)
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Ensure your user can access the docker socket or set DOCKER_HOST
export DOCKER_SOCKET=/var/run/docker.sock
python docker_mcp_server.py
```

5. Configure custom MCP catalog for Claude Desktop (example)

```bash
mkdir -p ~/.docker/mcp/catalogs
cat > ~/.docker/mcp/catalogs/custom.yaml <<'YAML'
version: 2
name: custom
displayName: Custom MCP Servers
registry:
  docker_mcp:
    description: "docker_mcp - Docker Engine MCP Server"
    title: "docker_mcp"
    type: server
    dateAdded: "2025-10-09T00:00:00Z"
    image: docker_mcp-server:latest
    ref: ""
    readme: ""
    toolsUrl: ""
    source: ""
    upstream: ""
    icon: ""
    tools:
      - name: list_containers
      - name: create_container
      - name: start_container
      - name: stop_container
      - name: restart_container
      - name: remove_container
      - name: inspect_container
      - name: attach_container
      - name: get_logs
      - name: get_stats
      - name: exec_create
      - name: exec_start
      - name: list_images
      - name: inspect_image
      - name: pull_image
      - name: build_image
      - name: push_image
      - name: tag_image
      - name: remove_image
      - name: list_volumes
      - name: list_networks
      - name: create_network
      - name: inspect_network
      - name: remove_network
      - name: connect_network
      - name: disconnect_network
      - name: get_info
      - name: get_version
      - name: system_df
      - name: ping
      - name: events
    secrets: []
    metadata:
      category: monitoring
      tags:
        - docker
        - mcp
        - monitoring
    license: MIT
    owner: local
YAML
```

6. Update registry (example)

```bash
mkdir -p ~/.docker/mcp
cat > ~/.docker/mcp/registry.yaml <<'YAML'
registry:
  docker_mcp:
    ref: ""
YAML
```

7. Configure Claude Desktop to use the MCP gateway (example snippet)  
   Edit your Claude Desktop config file (path depends on OS) and ensure the MCP gateway runs with the new catalog. Example `claude_desktop_config.json` args include mounting your catalog directory; follow Claude Desktop docs for exact placement. Example args you can use (no comments allowed in JSON):

```json
{
  "mcpServers": {
    "mcp-toolkit-gateway": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "-v",
        "/var/run/docker.sock:/var/run/docker.sock",
        "-v",
        "/home/your_username/.docker/mcp:/mcp",
        "docker/mcp-gateway",
        "--catalog=/mcp/catalogs/docker-mcp.yaml",
        "--catalog=/mcp/catalogs/custom.yaml",
        "--config=/mcp/config.yaml",
        "--registry=/mcp/registry.yaml",
        "--tools-config=/mcp/tools.yaml",
        "--transport=stdio"
      ]
    }
  }
}
```

Replace `/home/your_username` with your home directory path.

8. Restart Claude Desktop (or restart the MCP gateway container)

- Quit Claude Desktop fully and start it again.
- The `docker_mcp` server should appear in your custom catalog and its tools should be available.

9. Test a few commands from the gateway / direct run  
   If your MCP gateway runs the server container, invoke a few tools (or test locally by running the server and sending MCP JSON-RPC over stdio in a test harness). Examples using `docker` to verify basics:

```bash
# Check daemon
docker version
docker ps -a

# From the server container logs (if run detached)
docker logs <container>
```

10. Notes & security

- The container requires access to the Docker socket; mounting it is the recommended approach for full access, but it grants host-level control. Use with caution.
- Registry credentials: use Docker login on the host or pass JSON `auth_config` to pull/push tools. Avoid embedding secrets in code.
- If you want persistent event logging or DB-backed history, tell me and I can add SQLite/Postgres support.

---

If you want, I can now:

- (A) generate a small sample `custom.yaml` catalog that uses an absolute path for your home (I used a generic placeholder in instructions — I can produce an exact file for your OS), or
- (B) add an optional `MCP_API_TOKEN` simple check to the server to gate all tools (I left it off by default), or
- (C) add SQLite-backed event storage (stores last N events).

Which (if any) of A/B/C would you like next?
