#!/bin/bash
# dashboard.sh - Simple HTTP dashboard for VIDCOM progress/uploads
#
# Serves a web UI showing:
# - Current processing status
# - Completed uploads with clickable YouTube links
# - Queue of pending highlights
#
# Uses Python's built-in http.server (no dependencies)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARD_DIR="$PROJECT_DIR/dashboard"
DATA_DIR="$PROJECT_DIR/output"
PORT="${1:-8765}"
HOST="${2:-0.0.0.0}"

log() { echo "[dashboard] $*"; }

# Create dashboard directory and files
setup_dashboard() {
    mkdir -p "$DASHBOARD_DIR"
    mkdir -p "$DATA_DIR"
    
    # Create status file if not exists
    if [[ ! -f "$DATA_DIR/status.json" ]]; then
        cat > "$DATA_DIR/status.json" <<'EOF'
{
  "status": "idle",
  "current_task": null,
  "progress": 0,
  "message": "Ready",
  "uploads": [],
  "queue": []
}
EOF
    fi
    
    # Create main HTML dashboard
    cat > "$DASHBOARD_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VIDCOM Dashboard</title>
    <style>
        :root {
            --bg: #1a1a2e;
            --surface: #16213e;
            --primary: #0f3460;
            --accent: #e94560;
            --text: #eee;
            --text-dim: #888;
            --success: #4ecca3;
            --warning: #ffc107;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
            min-height: 100vh;
            padding: 2rem;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 {
            font-size: 2rem;
            margin-bottom: 2rem;
            display: flex;
            align-items: center;
            gap: 1rem;
        }
        h1 .logo { font-size: 2.5rem; }
        h2 {
            font-size: 1.2rem;
            color: var(--text-dim);
            margin-bottom: 1rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
        }
        .card {
            background: var(--surface);
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 1.5rem;
        }
        .status-bar {
            display: flex;
            align-items: center;
            gap: 1rem;
        }
        .status-indicator {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background: var(--success);
        }
        .status-indicator.processing { 
            background: var(--warning);
            animation: pulse 1s infinite;
        }
        .status-indicator.error { background: var(--accent); }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        .progress-bar {
            height: 8px;
            background: var(--primary);
            border-radius: 4px;
            overflow: hidden;
            margin-top: 1rem;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--accent), var(--success));
            transition: width 0.3s ease;
        }
        .uploads-list {
            display: grid;
            gap: 1rem;
        }
        .upload-item {
            display: flex;
            align-items: center;
            gap: 1rem;
            padding: 1rem;
            background: var(--primary);
            border-radius: 8px;
        }
        .upload-thumb {
            width: 120px;
            height: 68px;
            background: var(--bg);
            border-radius: 4px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--text-dim);
            font-size: 0.8rem;
        }
        .upload-info { flex: 1; }
        .upload-title {
            font-weight: 600;
            margin-bottom: 0.25rem;
        }
        .upload-meta {
            font-size: 0.85rem;
            color: var(--text-dim);
        }
        .upload-link {
            color: var(--accent);
            text-decoration: none;
            padding: 0.5rem 1rem;
            border: 1px solid var(--accent);
            border-radius: 4px;
            transition: all 0.2s;
        }
        .upload-link:hover {
            background: var(--accent);
            color: var(--bg);
        }
        .queue-item {
            padding: 0.75rem 1rem;
            background: var(--primary);
            border-radius: 6px;
            margin-bottom: 0.5rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .queue-item .filename { font-family: monospace; }
        .queue-item .status { 
            font-size: 0.8rem;
            color: var(--text-dim);
        }
        .empty-state {
            text-align: center;
            padding: 2rem;
            color: var(--text-dim);
        }
        .refresh-info {
            text-align: center;
            font-size: 0.8rem;
            color: var(--text-dim);
            margin-top: 2rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1><span class="logo">🎮</span> VIDCOM Dashboard</h1>
        
        <div class="card">
            <h2>Current Status</h2>
            <div class="status-bar">
                <div class="status-indicator" id="statusIndicator"></div>
                <span id="statusText">Loading...</span>
            </div>
            <div class="progress-bar">
                <div class="progress-fill" id="progressFill" style="width: 0%"></div>
            </div>
            <p id="statusMessage" style="margin-top: 0.5rem; color: var(--text-dim); font-size: 0.9rem;"></p>
        </div>
        
        <div class="card">
            <h2>Recent Uploads</h2>
            <div class="uploads-list" id="uploadsList">
                <div class="empty-state">No uploads yet</div>
            </div>
        </div>
        
        <div class="card">
            <h2>Processing Queue</h2>
            <div id="queueList">
                <div class="empty-state">Queue is empty</div>
            </div>
        </div>
        
        <p class="refresh-info">Auto-refreshes every 5 seconds</p>
    </div>
    
    <script>
        async function fetchStatus() {
            try {
                const res = await fetch('/output/status.json?' + Date.now());
                return await res.json();
            } catch (e) {
                return { status: 'error', message: 'Failed to load status' };
            }
        }
        
        function updateUI(data) {
            // Status indicator
            const indicator = document.getElementById('statusIndicator');
            indicator.className = 'status-indicator';
            if (data.status === 'processing') indicator.classList.add('processing');
            if (data.status === 'error') indicator.classList.add('error');
            
            // Status text
            document.getElementById('statusText').textContent = 
                data.status.charAt(0).toUpperCase() + data.status.slice(1);
            
            // Progress
            document.getElementById('progressFill').style.width = (data.progress || 0) + '%';
            
            // Message
            document.getElementById('statusMessage').textContent = data.message || '';
            
            // Uploads list
            const uploadsList = document.getElementById('uploadsList');
            if (data.uploads && data.uploads.length > 0) {
                uploadsList.innerHTML = data.uploads.map(u => `
                    <div class="upload-item">
                        <div class="upload-thumb">${u.game || '🎬'}</div>
                        <div class="upload-info">
                            <div class="upload-title">${u.title || 'Untitled'}</div>
                            <div class="upload-meta">
                                ${u.duration || '?'}s • ${u.uploaded_at || 'Unknown date'}
                            </div>
                        </div>
                        <a href="${u.url}" target="_blank" class="upload-link">
                            Watch on YouTube →
                        </a>
                    </div>
                `).join('');
            } else {
                uploadsList.innerHTML = '<div class="empty-state">No uploads yet</div>';
            }
            
            // Queue
            const queueList = document.getElementById('queueList');
            if (data.queue && data.queue.length > 0) {
                queueList.innerHTML = data.queue.map(q => `
                    <div class="queue-item">
                        <span class="filename">${q.filename}</span>
                        <span class="status">${q.status || 'pending'}</span>
                    </div>
                `).join('');
            } else {
                queueList.innerHTML = '<div class="empty-state">Queue is empty</div>';
            }
        }
        
        async function refresh() {
            const data = await fetchStatus();
            updateUI(data);
        }
        
        // Initial load and auto-refresh
        refresh();
        setInterval(refresh, 5000);
    </script>
</body>
</html>
HTMLEOF

    log "Dashboard files created in $DASHBOARD_DIR"
}

# Update status.json (called by other scripts)
update_status() {
    local status="$1"
    local message="$2"
    local progress="${3:-0}"
    
    cat > "$DATA_DIR/status.json" <<EOF
{
  "status": "$status",
  "message": "$message",
  "progress": $progress,
  "updated_at": "$(date -Iseconds)"
}
EOF
}

# Add upload to status
add_upload() {
    local video_id="$1"
    local title="$2"
    local game="${3:-Unknown}"
    local duration="${4:-0}"
    
    # Read existing status
    local existing
    existing=$(cat "$DATA_DIR/status.json" 2>/dev/null || echo '{"uploads":[]}')
    
    # Add new upload using jq
    echo "$existing" | jq --arg id "$video_id" \
        --arg title "$title" \
        --arg game "$game" \
        --arg duration "$duration" \
        --arg date "$(date '+%Y-%m-%d %H:%M')" \
        '.uploads = [{
            "id": $id,
            "url": "https://youtube.com/shorts/\($id)",
            "title": $title,
            "game": $game,
            "duration": $duration,
            "uploaded_at": $date
        }] + (.uploads // [])' > "$DATA_DIR/status.json.tmp"
    
    mv "$DATA_DIR/status.json.tmp" "$DATA_DIR/status.json"
}

start_server() {
    setup_dashboard
    
    log "Starting dashboard server..."
    log "  URL: http://localhost:$PORT"
    log "  Serving: $PROJECT_DIR"
    log ""
    log "Press Ctrl+C to stop"
    log ""
    
    # Use Python's http.server to serve the project directory
    cd "$PROJECT_DIR"
    python3 -m http.server "$PORT" --bind "$HOST"
}

# Commands
case "${1:-start}" in
    start)
        start_server
        ;;
    setup)
        setup_dashboard
        ;;
    update)
        # Called by other scripts: dashboard.sh update <status> <message> [progress]
        update_status "${2:-idle}" "${3:-}" "${4:-0}"
        ;;
    add-upload)
        # Called after upload: dashboard.sh add-upload <video_id> <title> [game] [duration]
        add_upload "${2:-}" "${3:-Untitled}" "${4:-Unknown}" "${5:-0}"
        ;;
    *)
        log "Usage: $0 [start|setup|update|add-upload]"
        exit 1
        ;;
esac
