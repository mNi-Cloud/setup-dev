#!/bin/bash
set -e

echo "=== Docker Registry Setup ==="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

REGISTRY_NAME="registry"
REGISTRY_PORT="5000"
REGISTRY_IMAGE="registry:2"

# Check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running or you don't have permission"
        print_warning "Please start Docker or add your user to docker group"
        exit 1
    fi
}

# Check if registry is already running
check_existing_registry() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
            print_status "Docker registry is already running"
            docker ps --filter "name=${REGISTRY_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            return 0
        else
            print_warning "Docker registry container exists but is not running"
            read -p "Do you want to start it? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                docker start ${REGISTRY_NAME}
                print_status "Docker registry started"
                return 0
            else
                read -p "Do you want to remove and recreate it? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    docker rm ${REGISTRY_NAME}
                    return 1
                else
                    exit 0
                fi
            fi
        fi
    fi
    return 1
}

# Start Docker registry
start_registry() {
    print_status "Starting Docker registry on localhost:${REGISTRY_PORT}..."
    
    docker run -d \
        --restart=unless-stopped \
        --name ${REGISTRY_NAME} \
        -p ${REGISTRY_PORT}:5000 \
        ${REGISTRY_IMAGE}
    
    print_status "Docker registry started successfully"
}

# Test registry connectivity
test_registry() {
    print_status "Testing registry connectivity..."
    
    # Wait for registry to be ready
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:${REGISTRY_PORT}/v2/ | grep -q "200\|401"; then
            print_status "Registry is accessible at http://localhost:${REGISTRY_PORT}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    
    print_error "Registry is not accessible after ${max_attempts} attempts"
    return 1
}

# Configure Docker daemon for insecure registry (if needed)
configure_docker_daemon() {
    print_status "Checking Docker daemon configuration..."
    
    local daemon_json="/etc/docker/daemon.json"
    local needs_config=false
    
    if [ -f "$daemon_json" ]; then
        if ! grep -q "localhost:${REGISTRY_PORT}" "$daemon_json"; then
            needs_config=true
        fi
    else
        needs_config=true
    fi
    
    if [ "$needs_config" = true ]; then
        print_warning "Docker daemon needs to be configured for insecure registry"
        echo "Add the following to /etc/docker/daemon.json:"
        echo '{'
        echo '  "insecure-registries": ["localhost:5000"]'
        echo '}'
        echo ""
        echo "Then restart Docker daemon:"
        echo "  sudo systemctl restart docker"
        echo ""
        read -p "Do you want me to do this for you? (requires sudo) (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ -f "$daemon_json" ]; then
                # Backup existing file
                sudo cp "$daemon_json" "${daemon_json}.backup"
                # This is simplified - in production, you'd want to merge JSON properly
                print_warning "Manual intervention needed to merge daemon.json"
                print_warning "Please add 'localhost:5000' to insecure-registries array"
            else
                echo '{
  "insecure-registries": ["localhost:5000"]
}' | sudo tee "$daemon_json" > /dev/null
                sudo systemctl restart docker
                print_status "Docker daemon configured and restarted"
            fi
        fi
    else
        print_status "Docker daemon already configured for localhost:${REGISTRY_PORT}"
    fi
}

# Show registry usage
show_usage() {
    echo ""
    echo "=== Registry Information ==="
    echo "Registry URL: localhost:${REGISTRY_PORT}"
    echo ""
    echo "To push an image:"
    echo "  docker tag myimage:tag localhost:${REGISTRY_PORT}/myimage:tag"
    echo "  docker push localhost:${REGISTRY_PORT}/myimage:tag"
    echo ""
    echo "To list images in registry:"
    echo "  curl http://localhost:${REGISTRY_PORT}/v2/_catalog"
    echo ""
    echo "To stop registry:"
    echo "  docker stop ${REGISTRY_NAME}"
    echo ""
    echo "To remove registry:"
    echo "  docker rm -f ${REGISTRY_NAME}"
}

# Main function
main() {
    print_status "Setting up Docker registry for Tilt..."
    
    check_docker
    
    if ! check_existing_registry; then
        start_registry
    fi
    
    if test_registry; then
        print_status "Docker registry is ready!"
        configure_docker_daemon
        show_usage
    else
        print_error "Failed to setup Docker registry"
        exit 1
    fi
    
    echo ""
    print_status "Next step: Run './prepare-deps.sh' to prepare component dependencies"
}

main "$@"