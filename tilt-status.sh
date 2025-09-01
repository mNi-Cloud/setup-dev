#!/bin/bash

echo "=== mni-backend Tilt Status ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"

# Tmux session name
SESSION_NAME="mni-tilt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}$1${NC}"; }

# Check tmux session
check_tmux() {
    print_header "Tmux Session Status"
    
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo -e "Session '$SESSION_NAME': ${GREEN}RUNNING${NC}"
        echo ""
        echo "Windows:"
        tmux list-windows -t "$SESSION_NAME" 2>/dev/null | while read line; do
            echo "  $line"
        done
    else
        echo -e "Session '$SESSION_NAME': ${RED}NOT RUNNING${NC}"
    fi
}

# Check Tilt processes
check_tilt_processes() {
    print_header "Tilt Processes"
    
    if pgrep -f "tilt up" > /dev/null; then
        echo -e "Status: ${GREEN}RUNNING${NC}"
        ps aux | grep "tilt up" | grep -v grep | while read line; do
            echo "$line" | awk '{print "  PID:", $2, "Port:", $NF}'
        done
    else
        echo -e "Status: ${RED}NOT RUNNING${NC}"
    fi
}

# Check Docker registry
check_registry() {
    print_header "Docker Registry"
    
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/v2/ | grep -q "200\|401"; then
        echo -e "localhost:5000: ${GREEN}AVAILABLE${NC}"
    else
        echo -e "localhost:5000: ${RED}NOT AVAILABLE${NC}"
    fi
}

# Check Tilt UIs
check_tilt_ui() {
    print_header "Tilt UI Status"
    
    if [ -f "$CONFIG_FILE" ] && command -v yq >/dev/null 2>&1; then
        components=$(yq eval '.components[] | select(.has_tiltfile == true) | .name' "$CONFIG_FILE")
        port=10350
        
        # Check dependency-controller first
        if echo "$components" | grep -q "dependency-controller"; then
            if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port" | grep -q "200\|302"; then
                echo -e "  dependency-controller (http://localhost:$port): ${GREEN}UP${NC}"
            else
                echo -e "  dependency-controller (http://localhost:$port): ${RED}DOWN${NC}"
            fi
            port=$((port + 1))
            components=$(echo "$components" | grep -v "dependency-controller")
        fi
        
        # Check other components
        for component in $components; do
            if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port" | grep -q "200\|302"; then
                echo -e "  $component (http://localhost:$port): ${GREEN}UP${NC}"
            else
                echo -e "  $component (http://localhost:$port): ${RED}DOWN${NC}"
            fi
            port=$((port + 1))
        done
    else
        echo "Cannot check - components.yaml or yq not found"
    fi
}

# Check Kubernetes
check_k8s() {
    print_header "Kubernetes Connection"
    
    if kubectl cluster-info &>/dev/null; then
        echo -e "Status: ${GREEN}CONNECTED${NC}"
        
        # Check for Tilt-managed resources
        tilt_resources=$(kubectl get deployments,services,pods -l "app.kubernetes.io/managed-by=tilt" --all-namespaces 2>/dev/null | wc -l)
        if [ "$tilt_resources" -gt 1 ]; then
            echo "Tilt-managed resources: $((tilt_resources - 1))"
        else
            echo "No Tilt-managed resources found"
        fi
    else
        echo -e "Status: ${RED}NOT CONNECTED${NC}"
    fi
}

# Main
main() {
    check_tmux
    check_tilt_processes
    check_registry
    check_tilt_ui
    check_k8s
    
    print_header "Quick Commands"
    echo "Start Tilt:  ./tilt-up.sh"
    echo "Stop Tilt:   ./tilt-down.sh"
    echo "Attach tmux: tmux attach -t $SESSION_NAME"
    echo ""
}

main "$@"