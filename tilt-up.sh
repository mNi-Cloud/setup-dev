#!/bin/bash
set -e

echo "=== Starting mni Development Environment ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
FRONTEND_DIR="${MNI_ROOT}/mni-frontend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"
NGINX_CONF="${SCRIPT_DIR}/nginx.conf"

# Tmux session name
SESSION_NAME="mni-tilt"
NGINX_CONTAINER="mni-nginx"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check Docker permissions and restart with sg if needed
check_docker_permissions() {
    if ! docker info >/dev/null 2>&1; then
        if ! groups | grep -q docker; then
            # User is not in docker group - add them and restart
            print_warning "Adding user to docker group..."
            sudo usermod -aG docker $USER
            print_status "User added to docker group"
            print_status "Restarting script with docker permissions..."
            exec sg docker "$0" "$@"
        else
            # User is in docker group but daemon might not be running
            print_warning "Docker daemon may not be running"
            print_status "Attempting to start Docker..."
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl start docker
                sudo systemctl enable docker
            elif command -v service >/dev/null 2>&1; then
                sudo service docker start
            fi
            sleep 2
            if ! docker info >/dev/null 2>&1; then
                print_error "Cannot access Docker daemon"
                exit 1
            fi
        fi
    fi
}

# Check prerequisites
check_prerequisites() {
    local missing=()

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    command -v tmux >/dev/null 2>&1 || missing+=("tmux")
    command -v tilt >/dev/null 2>&1 || missing+=("tilt")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v yq >/dev/null 2>&1 || missing+=("yq")

    if command -v yq >/dev/null 2>&1 && should_start_frontend; then
        command -v node >/dev/null 2>&1 || missing+=("node")
        command -v npm >/dev/null 2>&1 || missing+=("npm")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_warning "Please run './setup-tools.sh' first"
        exit 1
    fi

    if should_start_frontend; then
        local missing_frontend_deps=()
        if [ ! -f "$NGINX_CONF" ]; then
            print_error "nginx.conf not found: $NGINX_CONF"
            exit 1
        fi

        for app_path in $(get_frontend_paths); do
            if [ ! -f "${FRONTEND_DIR}/${app_path}/package.json" ]; then
                print_error "Frontend package.json not found: ${FRONTEND_DIR}/${app_path}/package.json"
                exit 1
            fi
            if [ ! -d "${FRONTEND_DIR}/${app_path}/node_modules" ]; then
                missing_frontend_deps+=("$app_path")
            fi
        done
        if [ ${#missing_frontend_deps[@]} -gt 0 ]; then
            print_error "Missing frontend npm dependencies: ${missing_frontend_deps[*]}"
            print_warning "Run './prepare-deps.sh' before './tilt-up.sh'"
            exit 1
        fi
    fi
    
    # Check kubectl connection
    if ! kubectl cluster-info &>/dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_warning "Please configure kubectl connection"
        exit 1
    fi
}

# Check Docker registry
check_registry() {
    print_status "Checking Docker registry..."
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/v2/ | grep -q "200\|401"; then
        print_status "Docker registry is accessible"
    else
        print_warning "Docker registry at localhost:5000 is not accessible"
        print_warning "Run './setup-registry.sh' to start the registry"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Get component info from YAML
get_component_info() {
    local field=$1
    yq eval ".components[] | select(.has_tiltfile == true) | .$field" "$CONFIG_FILE"
}

get_component_tilt_port() {
    local component=$1
    yq eval ".components[] | select(.name == \"$component\") | .tilt_port // \"\"" "$CONFIG_FILE"
}

frontend_enabled() {
    yq eval '.frontend.enabled // false' "$CONFIG_FILE"
}

should_start_frontend() {
    [ "${START_FRONTEND:-true}" != "false" ] && [ "$(frontend_enabled)" = "true" ]
}

get_frontend_proxy_port() {
    yq eval '.frontend.proxy.port // 8000' "$CONFIG_FILE"
}

get_frontend_paths() {
    yq eval '.frontend.apps[].path' "$CONFIG_FILE"
}

get_frontend_app_count() {
    yq eval '.frontend.apps | length' "$CONFIG_FILE"
}

get_frontend_app_info() {
    local index=$1
    local field=$2
    yq eval ".frontend.apps[$index].$field" "$CONFIG_FILE"
}

get_api_gateway_namespace() {
    yq eval '.api_gateway.namespace // "api-gateway-system"' "$CONFIG_FILE"
}

get_api_gateway_service() {
    yq eval '.api_gateway.service // "api-gateway-gateway-server-service"' "$CONFIG_FILE"
}

get_api_gateway_local_port() {
    yq eval '.api_gateway.local_port // 8080' "$CONFIG_FILE"
}

get_api_gateway_service_port() {
    yq eval '.api_gateway.service_port // 80' "$CONFIG_FILE"
}

# Start Tilt for a component
start_tilt_component() {
    local component=$1
    local port=$2
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        print_warning "$component: Directory not found, skipping"
        return
    fi
    
    if [ ! -f "${component_dir}/Tiltfile" ]; then
        print_warning "$component: No Tiltfile found, skipping"
        return
    fi
    
    print_status "Starting Tilt for $component on port $port..."
    
    # Create new tmux window
    tmux new-window -t "$SESSION_NAME" -n "$component" -c "$component_dir"
    
    # Set environment variables and start Tilt
    tmux send-keys -t "$SESSION_NAME:$component" "# Starting $component" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export GOPRIVATE=github.com/mNi-Cloud" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export TILT_ALLOW_K8S_CONTEXT=kubernetes-admin@kubernetes" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export TILT_REGISTRY=localhost:5000" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export AQUA_ROOT_DIR=\$HOME/.local/share/aquaproj-aqua" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export PATH=\$AQUA_ROOT_DIR/bin:\$PATH" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "export PATH=./bin:\$PATH" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "cd $component_dir" C-m
    tmux send-keys -t "$SESSION_NAME:$component" "tilt up --port $port" C-m
}

start_frontend_app() {
    local path=$1
    local port=$2
    local app_dir="${FRONTEND_DIR}/${path}"
    local window="frontend-${path}"

    print_status "Starting frontend ${path} on port $port..."

    tmux new-window -t "$SESSION_NAME" -n "$window" -c "$app_dir"
    tmux send-keys -t "$SESSION_NAME:$window" "# Starting frontend $path" C-m
    tmux send-keys -t "$SESSION_NAME:$window" "export VITE_API_BASE_URL=\${VITE_API_BASE_URL:-http://localhost:8080}" C-m
    tmux send-keys -t "$SESSION_NAME:$window" "export VITE_API_NAMESPACE=\${VITE_API_NAMESPACE:-default}" C-m
    tmux send-keys -t "$SESSION_NAME:$window" "cd $app_dir" C-m
    tmux send-keys -t "$SESSION_NAME:$window" "npm exec -- vite dev --host 0.0.0.0 --port $port --strictPort" C-m
}

start_frontend_apps() {
    if ! should_start_frontend; then
        return
    fi

    local app_count
    local index
    local app_path
    local app_port
    app_count=$(get_frontend_app_count)

    for ((index=0; index<app_count; index++)); do
        app_path=$(get_frontend_app_info "$index" "path")
        app_port=$(get_frontend_app_info "$index" "dev_port")
        start_frontend_app "$app_path" "$app_port"
        sleep 1
    done
}

start_nginx() {
    if ! should_start_frontend; then
        return
    fi

    local proxy_port
    proxy_port=$(get_frontend_proxy_port)

    print_status "Starting nginx frontend proxy on port $proxy_port..."

    docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
    docker run -d \
        --name "$NGINX_CONTAINER" \
        --add-host=host.docker.internal:host-gateway \
        -p "${proxy_port}:80" \
        -v "${NGINX_CONF}:/etc/nginx/conf.d/default.conf:ro" \
        nginx:alpine >/dev/null
}

start_api_gateway_port_forward() {
    local namespace
    local service
    local local_port
    local service_port
    namespace=$(get_api_gateway_namespace)
    service=$(get_api_gateway_service)
    local_port=$(get_api_gateway_local_port)
    service_port=$(get_api_gateway_service_port)

    print_status "Starting API gateway port-forward on localhost:$local_port..."

    tmux new-window -t "$SESSION_NAME" -n "api-gateway-pf" -c "$MNI_ROOT"
    tmux send-keys -t "$SESSION_NAME:api-gateway-pf" "# Forwarding API gateway to localhost:$local_port" C-m
    tmux send-keys -t "$SESSION_NAME:api-gateway-pf" "while true; do kubectl -n $namespace port-forward svc/$service $local_port:$service_port && break; echo 'API gateway port-forward is not ready; retrying in 2s'; sleep 2; done" C-m
}

# Main function
main() {
    print_status "Starting mni development environment..."

    if [ ! -d "$BACKEND_DIR" ]; then
        print_error "Backend directory not found: $BACKEND_DIR"
        print_warning "Run ./clone-repos.sh first to clone repositories"
        exit 1
    fi
    
    check_docker_permissions
    check_prerequisites
    check_registry
    
    # Check if session already exists
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        print_warning "Tmux session '$SESSION_NAME' already exists"
        read -p "Kill existing session and start fresh? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Killing existing session..."
            tmux kill-session -t "$SESSION_NAME"
        else
            print_status "Attaching to existing session..."
            tmux attach-session -t "$SESSION_NAME"
            exit 0
        fi
    fi
    
    # Create new tmux session
    print_status "Creating tmux session '$SESSION_NAME'..."
    tmux new-session -d -s "$SESSION_NAME" -n "main" -c "$MNI_ROOT"
    
    # Send dashboard info to main window
    tmux send-keys -t "$SESSION_NAME:main" "clear" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo '=== mni Development Dashboard ==='" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo ''" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo 'Tmux Controls:'" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo '  Switch windows: Ctrl-b [number]'" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo '  List windows:   Ctrl-b w'" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo '  Detach session: Ctrl-b d'" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo ''" C-m
    tmux send-keys -t "$SESSION_NAME:main" "echo 'Starting components...'" C-m
    
    # Get components from YAML
    components=$(yq eval '.components[] | select(.has_tiltfile == true) | .name' "$CONFIG_FILE")
    
    if [ -z "$components" ]; then
        print_error "No components with Tiltfile found in $CONFIG_FILE"
        tmux kill-session -t "$SESSION_NAME"
        exit 1
    fi
    
    # Start dependency-controller first (provides CRDs)
    port_counter=10350
    if echo "$components" | grep -q "dependency-controller"; then
        dependency_port=$(get_component_tilt_port "dependency-controller")
        if [ -z "$dependency_port" ] || [ "$dependency_port" = "null" ]; then
            dependency_port=$port_counter
        fi
        start_tilt_component "dependency-controller" "$dependency_port"
        port_counter=$((port_counter + 1))
        sleep 3  # Give dependency-controller time to start
        components=$(echo "$components" | grep -v "dependency-controller")
    fi
    
    # Start remaining components
    for component in $components; do
        component_port=$(get_component_tilt_port "$component")
        if [ -z "$component_port" ] || [ "$component_port" = "null" ]; then
            component_port=$port_counter
        fi
        start_tilt_component "$component" "$component_port"
        port_counter=$((port_counter + 1))
        sleep 2  # Small delay between starts
    done

    start_api_gateway_port_forward
    sleep 1
    start_frontend_apps
    sleep 1
    start_nginx
    
    # Show summary
    echo ""
    echo -e "${BLUE}=== Tilt Environment Started ===${NC}"
    echo ""
    echo "Backend Tilt UIs available at:"
    
    port_counter=10350
    all_components=$(yq eval '.components[] | select(.has_tiltfile == true) | .name' "$CONFIG_FILE")
    
    # Show dependency-controller first
    if echo "$all_components" | grep -q "dependency-controller"; then
        dependency_port=$(get_component_tilt_port "dependency-controller")
        if [ -z "$dependency_port" ] || [ "$dependency_port" = "null" ]; then
            dependency_port=$port_counter
        fi
        echo "  dependency-controller: http://localhost:$dependency_port"
        port_counter=$((port_counter + 1))
        all_components=$(echo "$all_components" | grep -v "dependency-controller")
    fi
    
    # Show remaining components
    for component in $all_components; do
        component_port=$(get_component_tilt_port "$component")
        if [ -z "$component_port" ] || [ "$component_port" = "null" ]; then
            component_port=$port_counter
        fi
        echo "  $component: http://localhost:$component_port"
        port_counter=$((port_counter + 1))
    done

    if should_start_frontend; then
        echo ""
        echo "Frontend available at:"
        echo "  UI proxy: http://localhost:$(get_frontend_proxy_port)"
    fi

    echo ""
    echo "API gateway available at:"
    echo "  api-gateway: http://localhost:$(get_api_gateway_local_port)"
    
    echo ""
    echo "Tmux commands:"
    echo "  Attach:  tmux attach -t $SESSION_NAME"
    echo "  Detach:  Ctrl-b d"
    echo "  Windows: Ctrl-b w"
    echo ""
    
    # Ask to attach
    read -p "Attach to tmux session now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        tmux attach-session -t "$SESSION_NAME"
    fi
}

main "$@"
