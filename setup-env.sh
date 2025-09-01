#!/bin/bash
set -e

echo "=== mni-backend Environment Configuration ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"

# Create backend directory if it doesn't exist
if [ ! -d "$BACKEND_DIR" ]; then
    print_warning "Backend directory not found: $BACKEND_DIR"
    print_status "Run ./clone-repos.sh first to clone repositories"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    local missing=()
    
    command -v aqua >/dev/null 2>&1 || missing+=("aqua")
    command -v direnv >/dev/null 2>&1 || missing+=("direnv")
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_warning "Please run './setup-tools.sh' first"
        exit 1
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
}

# Get component list from YAML
get_components() {
    yq eval '.components[].name' "$CONFIG_FILE"
}

# Create .envrc for each component
create_envrc() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        print_warning "Component directory not found: $component_dir (skipping)"
        return
    fi
    
    print_status "Creating .envrc for $component..."
    
    cat > "${component_dir}/.envrc" << 'EOF'
# mni-backend environment variables
export GOPRIVATE=github.com/mNi-Cloud
export TILT_ALLOW_K8S_CONTEXT=kubernetes-admin@kubernetes
export TILT_REGISTRY=localhost:5000

# Add aqua bin to PATH
export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua
export PATH=$AQUA_ROOT_DIR/bin:$PATH

# Add local bin to PATH (for controller-gen, kustomize, etc.)
export PATH=$(pwd)/bin:$PATH
EOF
    
    print_status ".envrc created for $component"
}

# Create or update aqua.yaml for components that don't have it
ensure_aqua_yaml() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        return
    fi
    
    if [ -f "${component_dir}/aqua.yaml" ]; then
        print_status "aqua.yaml already exists for $component"
    else
        print_status "Creating aqua.yaml for $component..."
        
        cat > "${component_dir}/aqua.yaml" << 'EOF'
---
# aqua - Declarative CLI Version Manager
# https://aquaproj.github.io/
registries:
- type: standard
  ref: v4.212.0 # renovate: depName=aquaproj/aqua-registry
packages:
- name: kubernetes/kubectl@v1.30.3
- name: tilt-dev/tilt@v0.33.21
EOF
        
        print_status "aqua.yaml created for $component"
    fi
}

# Install aqua packages
install_aqua_packages() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        return
    fi
    
    if [ -f "${component_dir}/aqua.yaml" ]; then
        print_status "Installing aqua packages for $component..."
        cd "$component_dir"
        
        # Set AQUA_ROOT_DIR for installation
        export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua
        
        if aqua install -a; then
            print_status "aqua packages installed for $component"
        else
            print_warning "Failed to install some aqua packages for $component"
        fi
        
        cd - > /dev/null
    fi
}

# Allow direnv for component
allow_direnv() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        return
    fi
    
    if [ -f "${component_dir}/.envrc" ]; then
        print_status "Allowing direnv for $component..."
        cd "$component_dir"
        direnv allow . 2>/dev/null || true
        cd - > /dev/null
    fi
}

# Create global .envrc in project root
create_global_envrc() {
    print_status "Creating global .envrc in project root..."
    
    cat > "${MNI_ROOT}/.envrc" << 'EOF'
# mni-backend global environment
export GOPRIVATE=github.com/mNi-Cloud
export TILT_ALLOW_K8S_CONTEXT=kubernetes-admin@kubernetes
export TILT_REGISTRY=localhost:5000

# Add aqua bin to PATH
export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua
export PATH=$AQUA_ROOT_DIR/bin:$PATH

# Add local bin to PATH
export PATH=$HOME/.local/bin:$PATH

# Go settings
export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH
EOF
    
    direnv allow "${MNI_ROOT}" 2>/dev/null || true
    print_status "Global .envrc created and allowed"
}

# Main function
main() {
    print_status "Configuring environment for mni-backend components..."
    
    check_prerequisites
    
    # Create global envrc
    create_global_envrc
    
    # Get component list
    components=$(get_components)
    
    if [ -z "$components" ]; then
        print_error "No components found in $CONFIG_FILE"
        exit 1
    fi
    
    # Process each component
    for component in $components; do
        print_status "Processing $component..."
        create_envrc "$component"
        ensure_aqua_yaml "$component"
        install_aqua_packages "$component"
        allow_direnv "$component"
    done
    
    echo ""
    print_status "Environment configuration complete!"
    echo ""
    echo "=== Configuration Summary ==="
    echo "GOPRIVATE: github.com/mNi-Cloud"
    echo "TILT_ALLOW_K8S_CONTEXT: kubernetes-admin@kubernetes"
    echo "TILT_REGISTRY: localhost:5000"
    echo ""
    echo "Components configured:"
    for component in $components; do
        if [ -d "${BACKEND_DIR}/${component}" ]; then
            echo "  ✓ $component"
        else
            echo "  ✗ $component (not cloned)"
        fi
    done
    
    echo ""
    print_warning "If direnv prompts appear, run 'direnv allow' in each directory"
    print_status "Next step: Run './setup-registry.sh' to start Docker registry"
}

main "$@"