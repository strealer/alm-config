#!/bin/bash
# ============================================================================
# Puppet Network Trigger
# ============================================================================
#
# WHAT THIS SCRIPT DOES:
# - Waits for network connectivity to Puppet server
# - Triggers an immediate Puppet agent run when network is available
# - Creates a flag to prevent re-runs during the same boot
#
# USAGE:
# - Called by puppet-network-trigger.service on boot
# - NOT intended for manual execution
#
# DEPLOYMENT:
# - Deployed from alm-config repository via Puppet
# ============================================================================

set -euo pipefail

MAX_WAIT=300  # 5 minutes max wait
INTERVAL=5
ELAPSED=0
FLAG_FILE="/var/lib/alm/puppet-triggered"
PUPPET_SERVER="puppet.strealer.io"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting Puppet network trigger (max wait: ${MAX_WAIT}s)"

# Wait for network connectivity
while [ $ELAPSED -lt $MAX_WAIT ]; do
    if curl -sfI --connect-timeout 5 "https://${PUPPET_SERVER}" >/dev/null 2>&1; then
        log "Network available - triggering Puppet agent"
        
        # Run Puppet agent (allow failure, it will retry on schedule)
        /opt/puppetlabs/bin/puppet agent -t 2>&1 | while read line; do log "puppet: $line"; done || true
        
        # Create flag to prevent re-runs this boot
        mkdir -p /var/lib/alm
        touch "$FLAG_FILE"
        
        log "Puppet run completed, flag created at $FLAG_FILE"
        exit 0
    fi
    
    log "Waiting for network... (${ELAPSED}s/${MAX_WAIT}s)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

log "ERROR: Timeout waiting for network connectivity"
exit 1
