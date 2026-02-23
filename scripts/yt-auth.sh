#!/bin/bash
# yt-auth.sh - YouTube OAuth 2.0 token management
# Returns valid access token to stdout, errors to stderr
#
# Setup:
# 1. Go to https://console.cloud.google.com/
# 2. Create project, enable YouTube Data API v3
# 3. Create OAuth 2.0 credentials (Desktop application)
# 4. Run: ./yt-auth.sh --setup
# 5. Follow browser authorisation flow
#
# Usage:
#   ACCESS_TOKEN=$(./yt-auth.sh)
#   curl -H "Authorisation: Bearer $ACCESS_TOKEN" ...

set -euo pipefail

# Configuration
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vidcom"
TOKEN_FILE="${CONFIG_DIR}/youtube_token.json"
CREDENTIALS_FILE="${CONFIG_DIR}/client_secrets.json"

# OAuth endpoints
AUTH_URI="https://accounts.google.com/o/oauth2/auth"
TOKEN_URI="https://oauth2.googleapis.com/token"
REDIRECT_URI="urn:ietf:wg:oauth:2.0:oob"
# Scopes must be URL-encoded (space = %20)
SCOPE="https://www.googleapis.com/auth/youtube.upload%20https://www.googleapis.com/auth/youtube"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

#------------------------------------------------------------------------------
# Setup - Initial OAuth flow
#------------------------------------------------------------------------------
setup_oauth() {
    log_info "YouTube OAuth Setup"
    echo "" >&2
    
    # Check for credentials file
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log_error "Client secrets file not found: $CREDENTIALS_FILE"
        echo "" >&2
        echo "To set up YouTube API access:" >&2
        echo "1. Go to https://console.cloud.google.com/" >&2
        echo "2. Create a new project (or select existing)" >&2
        echo "3. Enable 'YouTube Data API v3'" >&2
        echo "4. Go to Credentials > Create Credentials > OAuth client ID" >&2
        echo "5. Choose 'Desktop app' as application type" >&2
        echo "6. Download the JSON file" >&2
        echo "7. Save it as: $CREDENTIALS_FILE" >&2
        exit 1
    fi
    
    # Parse credentials
    local CLIENT_ID=$(jq -r '.installed.client_id // .web.client_id' "$CREDENTIALS_FILE")
    local CLIENT_SECRET=$(jq -r '.installed.client_secret // .web.client_secret' "$CREDENTIALS_FILE")
    
    if [[ -z "$CLIENT_ID" ]] || [[ "$CLIENT_ID" == "null" ]]; then
        log_error "Invalid client_secrets.json format"
        exit 1
    fi
    
    # Generate authorisation URL
    local AUTH_URL="${AUTH_URI}?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&scope=${SCOPE}&response_type=code&access_type=offline&prompt=consent"
    
    echo "" >&2
    log_info "Opening browser for authorisation..."
    log_info "If browser doesn't open, visit this URL manually:"
    echo "" >&2
    echo "$AUTH_URL" >&2
    echo "" >&2
    
    # Save URL for Chromium script (in case manual launch needed)
    echo "$AUTH_URL" > "${CONFIG_DIR}/oauth_url.txt"
    
    # Try to open browser - prefer our isolated Chromium
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local CHROMIUM_SCRIPT="$SCRIPT_DIR/setup-chromium.sh"
    
    if [[ -x "$CHROMIUM_SCRIPT" ]] && "$CHROMIUM_SCRIPT" status 2>/dev/null | grep -q "Binary:.*chrome"; then
        log_info "Opening in VIDCOM Chromium (isolated profile)..."
        "$CHROMIUM_SCRIPT" oauth "$AUTH_URL" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$AUTH_URL" 2>/dev/null || true
    elif command -v open &>/dev/null; then
        open "$AUTH_URL" 2>/dev/null || true
    elif [[ -n "${BROWSER:-}" ]]; then
        "$BROWSER" "$AUTH_URL" 2>/dev/null || true
    else
        log_warn "No browser found. Use: $CHROMIUM_SCRIPT install"
        log_info "Then run: $CHROMIUM_SCRIPT oauth"
    fi
    
    # Get authorisation code from user
    echo "" >&2
    read -p "Enter the authorisation code: " AUTH_CODE
    
    if [[ -z "$AUTH_CODE" ]]; then
        log_error "No authorisation code provided"
        exit 1
    fi
    
    # Exchange code for tokens
    log_info "Exchanging authorisation code for tokens..."
    
    local RESPONSE=$(curl -s -X POST "$TOKEN_URI" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "code=$AUTH_CODE" \
        -d "redirect_uri=$REDIRECT_URI" \
        -d "grant_type=authorization_code")
    
    # Check for errors
    local ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
    if [[ -n "$ERROR" ]]; then
        local ERROR_DESC=$(echo "$RESPONSE" | jq -r '.error_description // "Unknown error"')
        log_error "OAuth error: $ERROR - $ERROR_DESC"
        exit 1
    fi
    
    # Extract tokens
    local ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
    local REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r '.refresh_token')
    local EXPIRES_IN=$(echo "$RESPONSE" | jq -r '.expires_in')
    
    if [[ -z "$ACCESS_TOKEN" ]] || [[ "$ACCESS_TOKEN" == "null" ]]; then
        log_error "Failed to get access token"
        echo "$RESPONSE" >&2
        exit 1
    fi
    
    # Calculate expiration timestamp
    local NOW=$(date +%s)
    local EXPIRES_AT=$((NOW + EXPIRES_IN))
    
    # Save tokens
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    
    cat > "$TOKEN_FILE" << EOF
{
    "access_token": "$ACCESS_TOKEN",
    "refresh_token": "$REFRESH_TOKEN",
    "expires_at": $EXPIRES_AT,
    "created_at": $NOW
}
EOF
    chmod 600 "$TOKEN_FILE"
    
    log_info "OAuth setup complete! Tokens saved to $TOKEN_FILE"
    echo "$ACCESS_TOKEN"
}

#------------------------------------------------------------------------------
# Refresh access token
#------------------------------------------------------------------------------
refresh_token() {
    local REFRESH_TOKEN=$(jq -r '.refresh_token' "$TOKEN_FILE")
    
    if [[ -z "$REFRESH_TOKEN" ]] || [[ "$REFRESH_TOKEN" == "null" ]]; then
        log_error "No refresh token available. Run: $0 --setup"
        exit 1
    fi
    
    # Get client credentials
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log_error "Client secrets not found: $CREDENTIALS_FILE"
        exit 1
    fi
    
    local CLIENT_ID=$(jq -r '.installed.client_id // .web.client_id' "$CREDENTIALS_FILE")
    local CLIENT_SECRET=$(jq -r '.installed.client_secret // .web.client_secret' "$CREDENTIALS_FILE")
    
    log_info "Refreshing access token..." >&2
    
    local RESPONSE=$(curl -s -X POST "$TOKEN_URI" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "refresh_token=$REFRESH_TOKEN" \
        -d "grant_type=refresh_token")
    
    # Check for errors
    local ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
    if [[ -n "$ERROR" ]]; then
        local ERROR_DESC=$(echo "$RESPONSE" | jq -r '.error_description // "Unknown error"')
        log_error "Token refresh failed: $ERROR - $ERROR_DESC"
        log_error "Try running: $0 --setup"
        exit 1
    fi
    
    # Extract new access token
    local ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
    local EXPIRES_IN=$(echo "$RESPONSE" | jq -r '.expires_in')
    local NOW=$(date +%s)
    local EXPIRES_AT=$((NOW + EXPIRES_IN))
    
    # Update token file (preserve refresh token)
    jq --arg at "$ACCESS_TOKEN" --argjson ea "$EXPIRES_AT" \
        '.access_token = $at | .expires_at = $ea' \
        "$TOKEN_FILE" > "${TOKEN_FILE}.tmp" && mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
    
    echo "$ACCESS_TOKEN"
}

#------------------------------------------------------------------------------
# Get valid access token (refresh if needed)
#------------------------------------------------------------------------------
get_token() {
    # Check if token file exists
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log_error "No token file found. Run: $0 --setup"
        exit 1
    fi
    
    # Check expiration
    local EXPIRES_AT=$(jq -r '.expires_at // 0' "$TOKEN_FILE")
    local NOW=$(date +%s)
    
    # Refresh if expires in less than 5 minutes
    if (( NOW > EXPIRES_AT - 300 )); then
        refresh_token
    else
        jq -r '.access_token' "$TOKEN_FILE"
    fi
}

#------------------------------------------------------------------------------
# Show token status
#------------------------------------------------------------------------------
show_status() {
    echo "YouTube OAuth Status" >&2
    echo "====================" >&2
    
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log_warn "Not authenticated. Run: $0 --setup"
        exit 1
    fi
    
    local EXPIRES_AT=$(jq -r '.expires_at // 0' "$TOKEN_FILE")
    local CREATED_AT=$(jq -r '.created_at // 0' "$TOKEN_FILE")
    local NOW=$(date +%s)
    local REMAINING=$((EXPIRES_AT - NOW))
    
    echo "Config directory: $CONFIG_DIR" >&2
    echo "Token file: $TOKEN_FILE" >&2
    echo "Credentials: $CREDENTIALS_FILE" >&2
    echo "" >&2
    
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        local CLIENT_ID=$(jq -r '.installed.client_id // .web.client_id' "$CREDENTIALS_FILE")
        echo "Client ID: ${CLIENT_ID:0:20}..." >&2
    else
        log_warn "Client secrets file not found"
    fi
    
    echo "" >&2
    if (( REMAINING > 0 )); then
        log_info "Token valid for $((REMAINING / 60)) minutes"
    else
        log_warn "Token expired. Will refresh on next use."
    fi
    
    if (( CREATED_AT > 0 )); then
        echo "Created: $(date -d @$CREATED_AT '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    mkdir -p "$CONFIG_DIR"
    
    case "${1:-}" in
        --setup|-s)
            setup_oauth
            ;;
        --status)
            show_status
            ;;
        --refresh|-r)
            refresh_token
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]" >&2
            echo "" >&2
            echo "Options:" >&2
            echo "  --setup, -s    Run initial OAuth authorisation flow" >&2
            echo "  --status       Show current authentication status" >&2
            echo "  --refresh, -r  Force token refresh" >&2
            echo "  --help, -h     Show this help message" >&2
            echo "" >&2
            echo "Without options, returns a valid access token to stdout." >&2
            echo "" >&2
            echo "Setup:" >&2
            echo "  1. Create OAuth credentials at console.cloud.google.com" >&2
            echo "  2. Save client_secrets.json to: $CREDENTIALS_FILE" >&2
            echo "  3. Run: $0 --setup" >&2
            ;;
        *)
            get_token
            ;;
    esac
}

main "$@"
