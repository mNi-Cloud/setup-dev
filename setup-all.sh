#!/bin/bash
set -e

echo "=== Complete mni-backend Development Setup ==="
echo ""

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# Check if script exists and is executable
check_script() {
    local script=$1
    if [ ! -f "${SCRIPT_DIR}/$script" ]; then
        print_error "Script not found: $script"
        return 1
    fi
    if [ ! -x "${SCRIPT_DIR}/$script" ]; then
        chmod +x "${SCRIPT_DIR}/$script"
    fi
    return 0
}

# Run a setup script
run_script() {
    local script=$1
    local description=$2
    
    print_header "$description"
    
    if check_script "$script"; then
        if "${SCRIPT_DIR}/$script"; then
            print_status "$description completed successfully"
            return 0
        else
            print_error "$description failed"
            return 1
        fi
    else
        print_error "Cannot run $script"
        return 1
    fi
}

# Main setup flow
main() {
    print_status "Starting complete development environment setup..."
    echo ""
    echo "This will:"
    echo "  1. Install all required tools (Go, Docker, mnibuilder, aqua, direnv, tmux, yq, Tilt)"
    echo "  2. Clone/update all repositories"
    echo "  3. Configure environment variables"
    echo "  4. Start Docker registry"
    echo "  5. Prepare component dependencies"
    echo "  6. Start Tilt for all components"
    echo ""
    
    read -p "Continue with full setup? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi
    
    # Make all scripts executable
    chmod +x "${SCRIPT_DIR}"/*.sh
    
    # Step 1: Install tools
    if ! run_script "setup-tools.sh" "Installing Development Tools"; then
        print_error "Tool installation failed. Please fix errors and try again."
        exit 1
    fi
    
    # Reload PATH
    export PATH=$HOME/.local/bin:$PATH
    export PATH=/usr/local/go/bin:$PATH
    export GOPATH=$HOME/go
    export PATH=$GOPATH/bin:$PATH
    export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua
    export PATH=$AQUA_ROOT_DIR/bin:$PATH
    
    # Step 2: Clone repositories
    if ! run_script "clone-repos.sh" "Cloning/Updating Repositories"; then
        print_warning "Some repositories may not have been cloned. Check GitHub access."
    fi
    
    # Step 3: Configure environment
    if ! run_script "setup-env.sh" "Configuring Environment"; then
        print_warning "Environment configuration had issues. Some components may not work properly."
    fi
    
    # Step 4: Start Docker registry
    if ! run_script "setup-registry.sh" "Starting Docker Registry"; then
        print_warning "Docker registry setup failed. Tilt may not work properly."
    fi
    
    # Step 5: Prepare dependencies
    if ! run_script "prepare-deps.sh" "Preparing Component Dependencies"; then
        print_warning "Some components may not have built properly."
    fi
    
    # Final summary
    print_header "Setup Complete!"
    echo ""
    echo "Environment is ready! You can now:"
    echo ""
    echo "  Start Tilt for all components:"
    echo "    ./tilt-up.sh"
    echo ""
    echo "  Stop all Tilt instances:"
    echo "    ./tilt-down.sh"
    echo ""
    echo "  Check status:"
    echo "    ./tilt-status.sh"
    echo ""
    echo "Important URLs:"
    echo "  Docker Registry: http://localhost:5000"
    echo "  Tilt UIs will be available at:"
    echo "    dependency-controller: http://localhost:10350"
    echo "    api-gateway: http://localhost:10351"
    echo "    vpc-controller: http://localhost:10352"
    echo ""
    
    # Ask if user wants to start Tilt now
    read -p "Start Tilt development environment now? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_script "tilt-up.sh" "Starting Tilt Environment"
    else
        print_status "Run './tilt-up.sh' when you're ready to start development"
    fi
}

# Run main function
main "$@"