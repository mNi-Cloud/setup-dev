#!/bin/bash
set -e

echo "=== Preparing mni Dependencies ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
FRONTEND_DIR="${MNI_ROOT}/mni-frontend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_header() { echo -e "${BLUE}=== $1 ===${NC}"; }

# Check prerequisites
check_prerequisites() {
    local missing=()

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    command -v go >/dev/null 2>&1 || missing+=("go")
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    command -v mnibuilder >/dev/null 2>&1 || missing+=("mnibuilder")
    command -v make >/dev/null 2>&1 || missing+=("make")

    if command -v yq >/dev/null 2>&1 && [ "$(frontend_enabled)" = "true" ]; then
        command -v node >/dev/null 2>&1 || missing+=("node")
        command -v npm >/dev/null 2>&1 || missing+=("npm")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        print_warning "Please run './setup-tools.sh' first"
        exit 1
    fi
}

# Get component info from YAML
get_component_type() {
    local component=$1
    yq eval ".components[] | select(.name == \"$component\") | .type" "$CONFIG_FILE"
}

frontend_enabled() {
    yq eval '.frontend.enabled // false' "$CONFIG_FILE"
}

get_frontend_paths() {
    yq eval '.frontend.apps[].path' "$CONFIG_FILE"
}

has_makefile() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    [ -f "${component_dir}/Makefile" ]
}

install_npm_deps() {
    local name=$1
    local app_dir=$2

    if [ ! -d "$app_dir" ]; then
        print_warning "$name: Directory not found, skipping npm dependencies"
        return
    fi

    if [ ! -f "${app_dir}/package.json" ]; then
        print_warning "$name: No package.json found, skipping npm dependencies"
        return
    fi

    print_status "$name: Installing npm dependencies..."
    cd "$app_dir"

    if [ -f package-lock.json ]; then
        npm ci
    else
        npm install
    fi

    cd - > /dev/null
    print_status "$name: npm dependencies installed"
}

# Setup Go environment
setup_go_env() {
    export GOPRIVATE=github.com/mNi-Cloud
    export GOPATH=$HOME/go
    export PATH=$PATH:$GOPATH/bin:/usr/local/go/bin
}

# Download Go dependencies
download_go_deps() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -f "${component_dir}/go.mod" ]; then
        print_warning "$component: No go.mod found, skipping Go dependencies"
        return
    fi
    
    print_status "$component: Downloading Go dependencies..."
    cd "$component_dir"
    
    # Download dependencies
    if go mod download; then
        print_status "$component: Go dependencies downloaded"
    else
        print_warning "$component: Failed to download some dependencies"
    fi
    
    # Tidy up go.mod
    go mod tidy || true
    
    cd - > /dev/null
}

# Run make manifests for controllers
run_make_manifests() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if ! has_makefile "$component"; then
        print_warning "$component: No Makefile found, skipping manifests"
        return
    fi
    
    print_status "$component: Generating manifests..."
    cd "$component_dir"
    
    # Set environment variables directly
    export GOPRIVATE=github.com/mNi-Cloud
    export PATH=$component_dir/bin:$PATH
    
    if make manifests; then
        print_status "$component: Manifests generated successfully"
    else
        print_warning "$component: Failed to generate manifests (may be normal for non-controllers)"
    fi
    
    cd - > /dev/null
}

# Run make generate for controllers
run_make_generate() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if ! has_makefile "$component"; then
        print_warning "$component: No Makefile found, skipping generate"
        return
    fi
    
    print_status "$component: Generating code..."
    cd "$component_dir"
    
    # Set environment variables directly
    export GOPRIVATE=github.com/mNi-Cloud
    export PATH=$component_dir/bin:$PATH
    
    if make generate; then
        print_status "$component: Code generated successfully"
    else
        print_warning "$component: Failed to generate code (may be normal for non-controllers)"
    fi
    
    cd - > /dev/null
}

# Build binary to ensure everything compiles
build_component() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    print_status "$component: Building binary..."
    cd "$component_dir"
    
    # Set environment variables directly
    export GOPRIVATE=github.com/mNi-Cloud
    export PATH=$component_dir/bin:$PATH
    
    # Try different build approaches
    if has_makefile "$component" && grep -q "^build:" Makefile; then
        make build || print_warning "$component: make build failed"
    elif [ -f "cmd/main.go" ]; then
        go build -o bin/manager cmd/main.go || print_warning "$component: go build failed"
    else
        print_warning "$component: No standard build target found"
    fi
    
    cd - > /dev/null
}

# Process component based on type
process_component() {
    local component=$1
    local component_dir="${BACKEND_DIR}/${component}"
    
    if [ ! -d "$component_dir" ]; then
        print_error "$component: Directory not found, skipping"
        return
    fi
    
    local component_type=$(get_component_type "$component")
    print_header "Processing $component ($component_type)"
    
    # Download Go dependencies for all components
    download_go_deps "$component"
    
    # For controllers, run make manifests and generate
    if [ "$component_type" = "controller" ]; then
        run_make_manifests "$component"
        run_make_generate "$component"
    fi
    
    # Try to build the component
    build_component "$component"
    
    print_status "$component: Processing complete"
    echo ""
}

prepare_frontend_deps() {
    if [ "$(frontend_enabled)" != "true" ]; then
        return
    fi

    print_header "Processing frontend dependencies"

    if [ ! -d "$FRONTEND_DIR" ]; then
        print_warning "Frontend directory not found: $FRONTEND_DIR"
        print_warning "Run ./clone-repos.sh first to clone frontend repositories"
        return
    fi

    for path in $(get_frontend_paths); do
        install_npm_deps "$path" "${FRONTEND_DIR}/${path}"
    done

    echo ""
}

# Main function
main() {
    print_status "Preparing dependencies for configured repositories..."

    if [ ! -d "$BACKEND_DIR" ]; then
        print_error "Backend directory not found: $BACKEND_DIR"
        print_warning "Run ./clone-repos.sh first to clone repositories"
        exit 1
    fi
    
    check_prerequisites
    setup_go_env
    
    # Get component list
    components=$(yq eval '.components[].name' "$CONFIG_FILE")
    
    if [ -z "$components" ]; then
        print_error "No components found in $CONFIG_FILE"
        exit 1
    fi
    
    # Process dependency-controller first (it provides CRDs)
    if echo "$components" | grep -q "dependency-controller"; then
        process_component "dependency-controller"
        components=$(echo "$components" | grep -v "dependency-controller")
    fi
    
    # Process remaining components
    for component in $components; do
        process_component "$component"
    done

    prepare_frontend_deps
    
    print_header "Summary"
    echo "Backend components processed:"
    for component in $(yq eval '.components[].name' "$CONFIG_FILE"); do
        component_dir="${BACKEND_DIR}/${component}"
        if [ -d "$component_dir" ]; then
            if [ -f "${component_dir}/bin/manager" ] || [ -f "${component_dir}/bin/server" ]; then
                echo -e "  ${GREEN}✓${NC} $component - Built successfully"
            else
                echo -e "  ${YELLOW}⚠${NC} $component - No binary found"
            fi
        else
            echo -e "  ${RED}✗${NC} $component - Not cloned"
        fi
    done

    if [ "$(frontend_enabled)" = "true" ]; then
        echo ""
        echo "Frontend apps processed:"
        for path in $(get_frontend_paths); do
            if [ -d "${FRONTEND_DIR}/${path}/node_modules" ]; then
                echo -e "  ${GREEN}✓${NC} $path - npm dependencies installed"
            else
                echo -e "  ${YELLOW}⚠${NC} $path - npm dependencies missing"
            fi
        done
    fi
    
    echo ""
    print_status "Dependencies preparation complete!"
    print_status "Next step: Run './tilt-up.sh' to start development environment"
}

main "$@"
