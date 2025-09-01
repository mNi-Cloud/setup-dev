#!/bin/bash
set -e

echo "=== Stopping Tilt for mni-backend Components ==="

# Tmux session name
SESSION_NAME="mni-tilt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Stop Tilt in tmux window
stop_tilt_window() {
    local window=$1
    
    if tmux list-windows -t "$SESSION_NAME" 2>/dev/null | grep -q "$window"; then
        print_status "Stopping Tilt in $window..."
        tmux send-keys -t "$SESSION_NAME:$window" C-c
        sleep 1
        tmux send-keys -t "$SESSION_NAME:$window" "exit" C-m
    fi
}

# Clean up Kubernetes resources
cleanup_k8s() {
    print_status "Cleaning up Kubernetes resources..."
    
    # Delete Tilt-managed resources
    kubectl delete deployments,services,configmaps,secrets \
        -l "app.kubernetes.io/managed-by=tilt" \
        --all-namespaces 2>/dev/null || true
    
    # Kill any port-forwards
    pkill -f "kubectl port-forward" 2>/dev/null || true
    pkill -f "tilt" 2>/dev/null || true
}

# Main
main() {
    # Check if tmux session exists
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        print_warning "Tmux session '$SESSION_NAME' not found"
        
        # Check for orphaned Tilt processes
        if pgrep -f "tilt up" > /dev/null; then
            print_status "Found orphaned Tilt processes, killing them..."
            pkill -f "tilt up" || true
        fi
    else
        print_status "Stopping all Tilt instances in session '$SESSION_NAME'..."
        
        # Get all windows
        windows=$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null || echo "")
        
        for window in $windows; do
            if [ "$window" != "main" ]; then
                stop_tilt_window "$window"
            fi
        done
        
        # Wait for processes to terminate
        print_status "Waiting for processes to terminate..."
        sleep 3
        
        # Kill tmux session
        print_status "Killing tmux session..."
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    fi
    
    # Optional cleanup
    read -p "Clean up Kubernetes resources? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_k8s
    fi
    
    print_status "All Tilt instances stopped!"
}

main "$@"