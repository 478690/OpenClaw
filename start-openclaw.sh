#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 or Supabase via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone or Supabase, watches for file changes)
# 5. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# STORAGE BACKEND DETECTION
# ============================================================

# Check if R2 is configured
r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

# Check if Supabase is configured
supabase_configured() {
    [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_ANON_KEY" ]
}

# Determine which storage backend to use
use_r2=false
use_supabase=false

if r2_configured; then
    use_r2=true
    echo "Using R2 for storage"
elif supabase_configured; then
    use_supabase=true
    echo "Using Supabase for storage"
else
    echo "No storage backend configured, starting fresh"
fi

# ============================================================
# RCLONE SETUP (for R2)
# ============================================================

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# SUPABASE SETUP
# ============================================================

SUPABASE_BUCKET="${SUPABASE_BUCKET:-moltbot-data}"

setup_supabase() {
    # Create configuration file for Supabase
    cat > /tmp/supabase_config.json << EOF
{
    "url": "$SUPABASE_URL",
    "anonKey": "$SUPABASE_ANON_KEY",
    "serviceKey": "$SUPABASE_SERVICE_KEY",
    "bucket": "$SUPABASE_BUCKET"
}
EOF
    touch /tmp/.supabase-configured
    echo "Supabase configured for bucket: $SUPABASE_BUCKET"
}

# Supabase Storage API helper functions
supabase_upload() {
    local local_path="$1"
    local remote_path="$2"
    
    if [ ! -f "$local_path" ]; then
        echo "File not found: $local_path"
        return 1
    fi
    
    # Get file content and encode for JSON
    local file_content
    file_content=$(cat "$local_path" | jq -Rs .)
    
    # Upload to Supabase Storage
    local response
    response=$(
        curl -s -X POST \
            "${SUPABASE_URL}/storage/v1/object/${SUPABASE_BUCKET}/${remote_path}" \
            -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY:-$SUPABASE_ANON_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"data\": $file_content}"
    )
    
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        echo "Upload failed: $(echo "$response" | jq -r '.error.message')"
        return 1
    fi
    
    return 0
}

supabase_download() {
    local remote_path="$1"
    local local_path="$2"
    
    # Download from Supabase Storage
    local response
    response=$(curl -s -X GET \
        "${SUPABASE_URL}/storage/v1/object/public/${SUPABASE_BUCKET}/${remote_path}" \
        -H "Authorization: Bearer ${SUPABASE_ANON_KEY}")
    
    # Check if response is an error
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        echo "Download failed: $(echo "$response" | jq -r '.error.message // "file not found"')"
        return 1
    fi
    
    # Write content to file
    echo "$response" > "$local_path"
    return 0
}

supabase_list() {
    local prefix="$1"
    
    # List objects in Supabase Storage
    curl -s -X GET \
        "${SUPABASE_URL}/storage/v1/object/list/${SUPABASE_BUCKET}" \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY:-$SUPABASE_ANON_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"prefix\": \"$prefix\"}"
}

supabase_restore_directory() {
    local remote_prefix="$1"
    local local_dir="$2"
    
    echo "Checking Supabase for $remote_prefix..."
    
    # List files in the remote directory
    local files
    files=$(supabase_list "$remote_prefix")
    
    if [ -z "$files" ] || [ "$files" = "[]" ]; then
        echo "No files found in Supabase for $remote_prefix"
        return 0
    fi
    
    # Create local directory
    mkdir -p "$local_dir"
    
    # Download each file
    echo "$files" | jq -r '.[] | .name' | while read -r file; do
        if [ -n "$file" ]; then
            local local_file="$local_dir/$(basename "$file")"
            echo "Restoring: $file -> $local_file"
            supabase_download "$file" "$local_file" || echo "Warning: Failed to restore $file"
        fi
    done
    
    return 0
}

# ============================================================
# RESTORE FROM STORAGE (R2 or Supabase)
# ============================================================

if [ "$use_r2" = true ]; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi

elif [ "$use_supabase" = true ]; then
    setup_supabase

    echo "Checking Supabase for existing backup..."
    
    # Restore config from Supabase
    if supabase_list "openclaw" | jq -e '. | length > 0' > /dev/null 2>&1; then
        echo "Restoring config from Supabase..."
        supabase_restore_directory "openclaw" "$CONFIG_DIR" || echo "WARNING: config restore failed"
        echo "Config restored"
    elif supabase_list "clawdbot" | jq -e '. | length > 0' > /dev/null 2>&1; then
        echo "Restoring from legacy Supabase backup..."
        supabase_restore_directory "clawdbot" "$CONFIG_DIR" || echo "WARNING: legacy config restore failed"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in Supabase, starting fresh"
    fi

    # Restore workspace from Supabase
    if supabase_list "workspace" | jq -e '. | length > 0' > /dev/null 2>&1; then
        echo "Restoring workspace from Supabase..."
        mkdir -p "$WORKSPACE_DIR"
        supabase_restore_directory "workspace" "$WORKSPACE_DIR" || echo "WARNING: workspace restore failed"
        echo "Workspace restored"
    fi

    # Restore skills from Supabase
    if supabase_list "skills" | jq -e '. | length > 0' > /dev/null 2>&1; then
        echo "Restoring skills from Supabase..."
        mkdir -p "$SKILLS_DIR"
        supabase_restore_directory "skills" "$SKILLS_DIR" || echo "WARNING: skills restore failed"
        echo "Skills restored"
    fi

else
    echo "No storage backend configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if [ "$use_r2" = true ]; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"

elif [ "$use_supabase" = true ]; then
    echo "Starting background Supabase sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/supabase-sync.log
        touch "$MARKER"

        # Function to sync a directory to Supabase
        supabase_sync_dir() {
            local local_dir="$1"
            local remote_prefix="$2"
            local exclude_patterns="$3"
            
            if [ ! -d "$local_dir" ]; then
                return 0
            fi
            
            # Find changed files
            local CHANGED_FILES
            CHANGED_FILES=$(find "$local_dir" -newer "$MARKER" -type f 2>/dev/null)
            
            if [ -z "$CHANGED_FILES" ]; then
                return 0
            fi
            
            while IFS= read -r file; do
                if [ -z "$file" ]; then
                    continue
                fi
                
                # Apply exclude patterns
                local should_skip=false
                for pattern in $exclude_patterns; do
                    if echo "$file" | grep -q "$pattern"; then
                        should_skip=true
                        break
                    fi
                done
                
                if [ "$should_skip" = true ]; then
                    continue
                fi
                
                local relative_path="${file#$local_dir/}"
                local remote_path="$remote_prefix/$relative_path"
                
                # Read file and upload
                local file_content
                file_content=$(cat "$file" | jq -Rs .)
                
                if [ -n "$file_content" ]; then
                    curl -s -X POST \
                        "${SUPABASE_URL}/storage/v1/object/${SUPABASE_BUCKET}/${remote_path}" \
                        -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY:-$SUPABASE_ANON_KEY}" \
                        -H "Content-Type: application/json" \
                        -d "{\"data\": $file_content}" >> "$LOGFILE" 2>&1
                fi
            done <<< "$CHANGED_FILES"
        }

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                
                # Sync config
                supabase_sync_dir "$CONFIG_DIR" "openclaw" "*.lock *.log *.tmp .git"
                
                # Sync workspace
                if [ -d "$WORKSPACE_DIR" ]; then
                    supabase_sync_dir "$WORKSPACE_DIR" "workspace" ".git node_modules"
                fi
                
                # Sync skills
                if [ -d "$SKILLS_DIR" ]; then
                    supabase_sync_dir "$SKILLS_DIR" "skills" ".git"
                fi
                
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background Supabase sync loop started (PID: $!)"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
