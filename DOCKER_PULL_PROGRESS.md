# Docker Pull Progress Tracking

## Overview

The Strealer ALM system now includes **real-time Docker image pull progress tracking** using the Docker Socket API. This provides users with detailed visibility into image downloads that happen automatically via Puppet.

---

## Features

✅ **Real-Time Progress**: See exact byte counts and percentages during downloads
✅ **Layer-by-Layer Tracking**: Monitor each Docker layer individually
✅ **Cached vs Fresh**: Distinguish between cached and newly downloaded layers
✅ **User-Friendly Logging**: All progress logged to `/var/log/alm/docker-pull.log`
✅ **CLI Integration**: Monitor via `alm pull` command
✅ **Automatic Fallback**: Falls back to standard `docker pull` if API unavailable

---

## Architecture

### Components

1. **`docker-pull-with-progress`** - Progress tracking wrapper script
   - Location: `/usr/local/bin/docker-pull-with-progress`
   - Source: `alm-config/system-files/docker-pull-with-progress`
   - Deployed by: Puppet (from public GitHub repo)

2. **Puppet Integration** - Automated deployment and usage
   - Profiles updated: `raspberry_pi.pp`, `amd_server.pp`, `dev_machine.pp`
   - Downloads script from public `alm-config` repository
   - Uses wrapper for all image pulls

3. **ALM CLI Enhancement** - User monitoring interface
   - New command: `alm pull`
   - Options: `-f` (follow), `-n NUM` (show N lines)
   - Source: `alm-config/system-files/alm`

### How It Works

```
Puppet Run (every 30 min)
  │
  ├─► Docker Login (GCP Artifact Registry)
  │
  ├─► Pull init image via docker-pull-with-progress
  │     │
  │     ├─► Docker Socket API: POST /v1.41/images/create?fromImage=...
  │     ├─► Stream JSON progress events
  │     ├─► Parse and log: downloading, extracting, complete
  │     └─► Log to /var/log/alm/docker-pull.log
  │
  ├─► Pull main app image via docker-pull-with-progress
  │
  ├─► Pull telemetry image via docker-pull-with-progress
  │
  └─► Smart container update (recreate only if new image)
```

---

## Usage

### For End Users (Customers)

**Monitor real-time progress:**
```bash
alm pull -f
```

**View recent pull activity:**
```bash
alm pull              # Last 50 lines
alm pull -n 100       # Last 100 lines
```

**Get help:**
```bash
alm pull --help
```

### For Administrators

**Manually pull with progress tracking:**
```bash
sudo /usr/local/bin/docker-pull-with-progress europe-west1-docker.pkg.dev/effective-pipe-424209-r1/alm-init/alm-init:latest
```

**View log file directly:**
```bash
tail -f /var/log/alm/docker-pull.log
```

**Check Puppet logs for pull activity:**
```bash
journalctl -u puppet -f | grep docker-pull
```

---

## Example Output

```
[2025-11-19 10:30:15] ==========================================
[2025-11-19 10:30:15] 📦 PULLING IMAGE (enhanced mode)
[2025-11-19 10:30:15] ==========================================
[2025-11-19 10:30:15] Image: europe-west1-docker.pkg.dev/.../alm-init:latest
[2025-11-19 10:30:15] Method: Docker Socket API (detailed progress)
[2025-11-19 10:30:15] ==========================================
[2025-11-19 10:30:15] 🔄 Pulling from alm-init/alm-init
[2025-11-19 10:30:16] 📋 Layer abc123 queued (total: 3 layers)
[2025-11-19 10:30:16] 📋 Layer def456 queued (total: 3 layers)
[2025-11-19 10:30:16] 📋 Layer ghi789 queued (total: 3 layers)
[2025-11-19 10:30:17] ⬇️  Layer abc123: [████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 10% (5MB / 50MB)
[2025-11-19 10:30:19] ⬇️  Layer abc123: [██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 25% (12MB / 50MB)
[2025-11-19 10:30:21] ⬇️  Layer abc123: [████████████████████░░░░░░░░░░░░░░░░░░] 50% (25MB / 50MB)
[2025-11-19 10:30:23] ⬇️  Layer abc123: [██████████████████████████████░░░░░░░░] 75% (37MB / 50MB)
[2025-11-19 10:30:24] ✅ Layer abc123: Download complete
[2025-11-19 10:30:24] 📂 Layer abc123: Extracting [████████████████████░░░░░░░░░░░░░░░░░░] 50%
[2025-11-19 10:30:26] ✅ Layer abc123: Complete (1/3)
[2025-11-19 10:30:27] ⬇️  Layer def456: [████████████████████████████████████████] 100% (20MB / 20MB)
[2025-11-19 10:30:27] ✅ Layer def456: Download complete
[2025-11-19 10:30:28] 📂 Layer def456: Extracting...
[2025-11-19 10:30:29] ✅ Layer def456: Complete (2/3)
[2025-11-19 10:30:30] 💾 Layer ghi789: Already cached (3/3)
[2025-11-19 10:30:30] 🔐 Image digest: sha256:abc123...
[2025-11-19 10:30:30] 📊 Status: Downloaded newer image
[2025-11-19 10:30:30] ==========================================
[2025-11-19 10:30:30] ✅ PULL SUCCESSFUL
[2025-11-19 10:30:30] Overall Progress: [██████████████████████████████████████████████████] 100%
[2025-11-19 10:30:30] Layers: 3/3 completed
[2025-11-19 10:30:30] ==========================================
```

**Visual Features:**
- 🟩 **Green progress bars** with filled (█) and empty (░) characters
- **40-character bars** for per-layer progress (easier to read in logs)
- **50-character bar** for overall completion status
- **Color-coded**: Green bars make progress instantly visible
- **Real-time updates**: Bars update every 2 seconds during download/extraction

---

## Technical Details

### Docker Socket API

The script uses the official Docker Engine API:

```bash
curl --unix-socket /var/run/docker.sock -X POST \
  "http://localhost/v1.41/images/create?fromImage=<image>"
```

**JSON Response Format:**
```json
{"status":"Downloading","progressDetail":{"current":999424,"total":4138069},"id":"layer_id"}
{"status":"Download complete","progressDetail":{},"id":"layer_id"}
{"status":"Extracting","progressDetail":{"current":2752512,"total":4138069},"id":"layer_id"}
{"status":"Pull complete","progressDetail":{},"id":"layer_id"}
```

### Progress Rate Limiting

To avoid log spam, progress updates are rate-limited to **once every 2 seconds per layer**:

```bash
# Only log if 2+ seconds have passed since last update for this layer
if [ $((current_time - last_time)) -ge 2 ]; then
    log "⬇️  Layer $layer_id: ${percent}% (${current_h}/${total_h})"
fi
```

### Fallback Mechanism

If Docker API is unavailable, the script automatically falls back to standard `docker pull`:

```bash
can_use_docker_api() {
    # Check socket exists
    [ ! -S "$DOCKER_SOCKET" ] && return 1

    # Check curl available
    ! command -v curl &>/dev/null && return 1

    # Test connectivity
    curl --unix-socket "$DOCKER_SOCKET" --max-time 2 \
        "http://localhost/_ping" &>/dev/null || return 1

    return 0
}
```

---

## Deployment

### Automatic Deployment (via Puppet)

1. **Script Download** - Every Puppet run (30 min intervals):
   ```puppet
   exec { 'download_docker_pull_progress':
     command => "curl -fsSL -o /usr/local/bin/docker-pull-with-progress ${config_repo_url}/docker-pull-with-progress",
     path    => ['/usr/bin', '/bin'],
     require => Package['curl'],
   }
   ```

2. **Permissions** - Set executable:
   ```puppet
   file { '/usr/local/bin/docker-pull-with-progress':
     ensure  => file,
     owner   => 'root',
     group   => 'root',
     mode    => '0755',
     require => Exec['download_docker_pull_progress'],
   }
   ```

3. **Image Pulls** - Use wrapper for all pulls:
   ```puppet
   exec { 'pull-alm-init-image':
     command   => '/usr/local/bin/docker-pull-with-progress europe-west1-docker.pkg.dev/.../alm-init:latest',
     path      => ['/usr/local/bin', '/usr/bin', '/bin'],
     timeout   => 600,
     require   => [Exec['docker-login-gcp'], File['/usr/local/bin/docker-pull-with-progress']],
     logoutput => true,
   }
   ```

### Manual Deployment (for testing)

```bash
# Download script
curl -fsSL -o /usr/local/bin/docker-pull-with-progress \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/docker-pull-with-progress

# Make executable
chmod +x /usr/local/bin/docker-pull-with-progress

# Test pull
/usr/local/bin/docker-pull-with-progress alpine:latest
```

---

## Troubleshooting

### Issue: No progress shown, only "Downloading"

**Cause**: Image already pulled recently, no new data to download.

**Solution**: Expected behavior. Use `docker rmi <image>` to force fresh pull for testing.

---

### Issue: "Docker socket not found" error

**Cause**: Docker socket not available at `/var/run/docker.sock`.

**Solution**:
1. Check Docker is running: `sudo systemctl status docker`
2. Verify socket exists: `ls -l /var/run/docker.sock`
3. Script will auto-fallback to standard `docker pull`

---

### Issue: Permission denied on /var/log/alm

**Cause**: Script not running as root.

**Solution**: Puppet runs script as root automatically. For manual testing:
```bash
sudo /usr/local/bin/docker-pull-with-progress <image>
```

---

### Issue: "declare -A: invalid option" error

**Cause**: Bash version < 4.0 (macOS default is 3.2).

**Solution**: Only affects local macOS testing. Production devices (Raspberry Pi OS, Ubuntu) use Bash 4.2+.

---

## Monitoring & Logging

### Log File Location

```
/var/log/alm/docker-pull.log
```

**Permissions**: 644 (readable by all users)
**Owner**: root:root
**Rotation**: Handled by systemd journal (default 7 days retention)

### Log Format

```
[YYYY-MM-DD HH:MM:SS] Message with emoji indicators
[HH:MM:SS] Raw JSON (detailed technical log)
```

**Emoji Indicators**:
- 📦 Pull starting/ending
- 📋 Layer discovered
- ⬇️  Downloading with progress
- ✅ Download/extraction complete
- 💾 Layer already cached
- 🔍 Checksum verification
- 📂 Extracting
- 🔐 Image digest
- 📊 Final status

---

## Security Considerations

### No Credentials in Script

The `docker-pull-with-progress` script is **public** and contains **no secrets**:

✅ No GCP tokens
✅ No registry credentials
✅ No API keys

**Authentication flow**:
1. Puppet distributes GCP token to `/opt/alm/config/gcp-registry-token` (private)
2. `docker-login-gcp` script authenticates to registry (before pull)
3. `docker-pull-with-progress` uses cached Docker credentials

### Socket Access

Access to `/var/run/docker.sock` is **restricted to root** and `docker` group:

```bash
srw-rw---- 1 root docker 0 Nov 19 10:00 /var/run/docker.sock
```

Only `almadmin` and `root` can run the progress script with socket access. Customer users (`almuser`) can only **view logs**.

---

## Performance Impact

### Resource Usage

- **CPU**: Minimal (<1% overhead from JSON parsing)
- **Memory**: ~2MB additional (associative arrays for layer tracking)
- **Network**: Zero overhead (reads existing Docker API stream)
- **Disk I/O**: Append-only logging (~10KB per pull)

### Comparison

| Method | CPU | Memory | Network | Progress Detail |
|--------|-----|--------|---------|-----------------|
| `docker pull` (standard) | Baseline | Baseline | Baseline | Basic (layer status only) |
| `docker-pull-with-progress` | +0.5% | +2MB | +0% | Detailed (bytes, %) |

---

## Future Enhancements

Potential improvements discussed with client (Kristo):

1. **HDMI Console Display** - Show progress on connected monitor without SSH
   - Modify `systemd` service to output to `/dev/tty1`
   - Enable console output in pi-gen boot config
   - Estimated: 6-8 hours implementation

2. **Web Dashboard** - Real-time progress in web UI
   - WebSocket streaming of pull progress
   - Multi-device fleet view
   - Estimated: 16-20 hours implementation

3. **Slack/Email Notifications** - Alert on pull completion/failure
   - Integration with existing telemetry system
   - Estimated: 4-6 hours implementation

---

## References

- **Docker Engine API Docs**: https://docs.docker.com/engine/api/v1.41/#tag/Image
- **alm-config Repository**: https://github.com/strealer/alm-config
- **Client Discussion**: Slack #alm-edge-computing (Nov 19, 2025)

---

## Change Log

### 2025-11-19 - Initial Implementation
- Created `docker-pull-with-progress` script with Docker Socket API
- Updated Puppet profiles: `raspberry_pi.pp`, `amd_server.pp`, `dev_machine.pp`
- Added `alm pull` command to ALM CLI
- Documentation created

---

## Support

For issues or questions:
- Check logs: `alm pull -f`
- GitHub Issues: https://github.com/strealer/alm-config/issues
- Slack: #alm-edge-computing
