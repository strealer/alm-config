# Vector Observability Optimizations

This document describes performance optimizations made to Vector configuration for edge devices.

## Overview

Vector runs on each edge device (Raspberry Pi / AMD64) to collect metrics and logs. Several optimizations have been made to reduce CPU usage while maintaining comprehensive observability.

---

## Optimization 1: Lightweight Docker Stats via cgroup v2

### Problem
The original `docker stats` command caused **15-20% CPU spikes** every 30 seconds:
```bash
# OLD: Expensive command (~2.5 seconds, high CPU)
docker stats --no-stream --format '{{json .}}' --all | jq -c '{name:.Name,cpu:.CPUPerc,mem:.MemPerc,net:.NetIO,block:.BlockIO}'
```

### Solution
Read directly from Linux cgroup v2 files instead of calling Docker:
```bash
# NEW: Lightweight file reads (~0.2 seconds, no CPU spike)
# Reads from /sys/fs/cgroup/system.slice/docker-<container_id>.scope/
# Files: memory.current, cpu.stat, io.stat
```

### Performance Comparison
| Method | Execution Time | CPU Impact |
|--------|---------------|------------|
| `docker stats` | ~2.5 seconds | 15-20% spike |
| cgroup files | ~0.2 seconds | Near-zero |

### Data Collected
| Metric | Description | Source |
|--------|-------------|--------|
| `name` | Container name | `docker inspect` |
| `mem_mb` | Memory usage in MB | `memory.current` |
| `cpu_usec` | Cumulative CPU time (microseconds) | `cpu.stat` |
| `io_read_bytes` | Bytes read from disk | `io.stat` |
| `io_write_bytes` | Bytes written to disk | `io.stat` |

> **Note**: Network I/O is NOT collected per-container because containers use `network_mode: host`. Host-level network metrics are already collected via `host_metrics`.

---

## Optimization 2: PSI Pressure Monitoring

### What is PSI?
Pressure Stall Information (PSI) is a Linux kernel feature that tracks resource contention. Unlike point-in-time CPU percentages, PSI captures **cumulative** stalls - so no spike is ever missed.

### Configuration
```yaml
psi_pressure:
  type: "exec"
  command: ["/bin/sh", "-c", "... read /proc/pressure/cpu,memory,io ..."]
  scheduled:
    exec_interval_secs: 1  # High resolution - reads are instant
```

### Metrics
| Metric | Description |
|--------|-------------|
| `psi_cpu_some` | % time some tasks stalled on CPU |
| `psi_cpu_full` | % time all tasks stalled on CPU |
| `psi_mem_some` | % time some tasks stalled on memory |
| `psi_mem_full` | % time all tasks stalled on memory |
| `psi_io_some` | % time some tasks stalled on I/O |
| `psi_io_full` | % time all tasks stalled on I/O |

---

## Optimization 3: configure_puppet_agent.service Fix

### Problem
The `configure_puppet_agent.service` was restarting every 30 seconds even after successful Puppet configuration, causing periodic CPU spikes.

### Root Cause
- Service used `Restart=always`
- Script exits with status 0 if Puppet already configured
- Despite successful exit, `Restart=always` kept triggering restarts

### Fix
```ini
[Unit]
# Only run if Puppet hasn't been configured yet
ConditionPathExists=!/var/lib/puppet-config-done

[Service]
# Only restart on failure, not on success
Restart=on-failure
RestartSec=30
```

---

## Exec Source Intervals

| Source | Interval | Description | CPU Impact |
|--------|----------|-------------|------------|
| `psi_pressure` | 1 sec | Read /proc/pressure/* files | Very Low |
| `cpu_temperature` | 30 sec | Read thermal zone temp | Very Low |
| `docker_stats` | 30 sec | Read cgroup files | Very Low |
| `service_health` | 60 sec | Check systemctl status | Low |
| `top_processes` | 60 sec | ps aux --sort | Low |
| `ip_info` | 300 sec | wget external IP | Low (network) |
| `docker_images_info` | 300 sec | docker inspect | Medium |

---

## Best Practices for Vector Exec Commands

### Escaping Dollar Signs
In Vector YAML, `$` is interpreted as an environment variable. Use `$$` to escape:
```yaml
# Wrong - Vector tries to expand $cg as env var
command: ["...", "cg=$(find ...)"]

# Correct - $$ becomes literal $
command: ["...", "cg=$$(find ...)"]
```

### Use File Reads Over Commands
Prefer reading Linux pseudo-files over running commands:
```bash
# Slower: Run a command
docker stats --no-stream

# Faster: Read files directly
cat /sys/fs/cgroup/.../memory.current
cat /proc/pressure/cpu
cat /sys/class/thermal/thermal_zone0/temp
```

---

## Related Files

- `alm-config/observability/vector.yaml` - Main Vector configuration
- `alm-config/system-files/configure_puppet_agent.service` - Fixed service file
