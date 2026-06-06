#!/bin/bash

echo "=== mni Development Status ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
FRONTEND_DIR="${MNI_ROOT}/mni-frontend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"

# Tmux session name
SESSION_NAME="mni-tilt"
NGINX_CONTAINER="mni-nginx"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}$1${NC}"; }

frontend_enabled() {
    yq eval '.frontend.enabled // false' "$CONFIG_FILE"
}

get_frontend_proxy_port() {
    yq eval '.frontend.proxy.port // 8000' "$CONFIG_FILE"
}

get_component_tilt_port() {
    local component=$1
    yq eval ".components[] | select(.name == \"$component\") | .tilt_port // \"\"" "$CONFIG_FILE"
}

get_api_gateway_local_port() {
    yq eval '.api_gateway.local_port // 8080' "$CONFIG_FILE"
}

get_frontend_app_count() {
    yq eval '.frontend.apps | length' "$CONFIG_FILE"
}

get_frontend_app_info() {
    local index=$1
    local field=$2
    yq eval ".frontend.apps[$index].$field" "$CONFIG_FILE"
}

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
            component_port=$(get_component_tilt_port "dependency-controller")
            if [ -z "$component_port" ] || [ "$component_port" = "null" ]; then
                component_port=$port
            fi
            if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$component_port" | grep -q "200\|302"; then
                echo -e "  dependency-controller (http://localhost:$component_port): ${GREEN}UP${NC}"
            else
                echo -e "  dependency-controller (http://localhost:$component_port): ${RED}DOWN${NC}"
            fi
            port=$((port + 1))
            components=$(echo "$components" | grep -v "dependency-controller")
        fi
        
        # Check other components
        for component in $components; do
            component_port=$(get_component_tilt_port "$component")
            if [ -z "$component_port" ] || [ "$component_port" = "null" ]; then
                component_port=$port
            fi
            if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$component_port" | grep -q "200\|302"; then
                echo -e "  $component (http://localhost:$component_port): ${GREEN}UP${NC}"
            else
                echo -e "  $component (http://localhost:$component_port): ${RED}DOWN${NC}"
            fi
            port=$((port + 1))
        done
    else
        echo "Cannot check - components.yaml or yq not found"
    fi
}

check_frontend_proxy() {
    print_header "Frontend"

    if [ ! -f "$CONFIG_FILE" ] || ! command -v yq >/dev/null 2>&1 || [ "$(frontend_enabled)" != "true" ]; then
        echo "Frontend is not configured"
        return
    fi

    local proxy_port
    proxy_port=$(get_frontend_proxy_port)

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${NGINX_CONTAINER}$"; then
        echo -e "nginx container (${NGINX_CONTAINER}): ${GREEN}RUNNING${NC}"
    else
        echo -e "nginx container (${NGINX_CONTAINER}): ${RED}NOT RUNNING${NC}"
    fi

    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${proxy_port}" | grep -q "200\|302"; then
        echo -e "proxy http://localhost:${proxy_port}: ${GREEN}UP${NC}"
    else
        echo -e "proxy http://localhost:${proxy_port}: ${RED}DOWN${NC}"
    fi

    local app_count
    local index
    local app_path
    local app_port
    app_count=$(get_frontend_app_count)

    for ((index=0; index<app_count; index++)); do
        app_path=$(get_frontend_app_info "$index" "path")
        app_port=$(get_frontend_app_info "$index" "dev_port")
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${app_port}/${app_path}/" | grep -q "200\|302"; then
            echo -e "  ${app_path} (http://localhost:${app_port}/${app_path}/): ${GREEN}UP${NC}"
        else
            echo -e "  ${app_path} (http://localhost:${app_port}/${app_path}/): ${RED}DOWN${NC}"
        fi
    done
}

check_api_gateway() {
    print_header "API Gateway"

    if [ ! -f "$CONFIG_FILE" ] || ! command -v yq >/dev/null 2>&1; then
        echo "Cannot check - components.yaml or yq not found"
        return
    fi

    local api_port
    api_port=$(get_api_gateway_local_port)

    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${api_port}/openapi.json" | grep -q "200"; then
        echo -e "http://localhost:${api_port}: ${GREEN}UP${NC}"
    else
        echo -e "http://localhost:${api_port}: ${RED}DOWN${NC}"
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
    check_api_gateway
    check_frontend_proxy
    check_k8s
    
    print_header "Quick Commands"
    echo "Start env:   ./tilt-up.sh"
    echo "Stop env:    ./tilt-down.sh"
    echo "Attach tmux: tmux attach -t $SESSION_NAME"
    echo ""
}

main "$@"
