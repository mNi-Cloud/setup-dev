#!/bin/bash
set -e

echo "=== mni-backend Development Tools Installation ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
INSTALL_DIR="$HOME/.local/bin"

# Create backend directory if it doesn't exist
mkdir -p "$BACKEND_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
   print_error "Please do not run as root"
   exit 1
fi

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Install Go 1.24.2
install_go() {
    if command -v go >/dev/null 2>&1 && go version | grep -q "1.24"; then
        print_status "Go 1.24.x is already installed"
    else
        print_status "Installing Go 1.24.2..."
        wget -q --show-progress https://go.dev/dl/go1.24.2.linux-amd64.tar.gz -O /tmp/go.tar.gz
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf /tmp/go.tar.gz
        rm /tmp/go.tar.gz
        
        # Add to PATH
        if ! grep -q "/usr/local/go/bin" ~/.bashrc; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
            echo 'export GOPATH=$HOME/go' >> ~/.bashrc
            echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.bashrc
        fi
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=$HOME/go
        export PATH=$PATH:$GOPATH/bin
        print_status "Go installed successfully"
    fi
}

# Install Docker
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        print_status "Docker is already installed"
        # Check if user is in docker group
        if ! groups | grep -q docker; then
            print_warning "Adding user to docker group..."
            sudo usermod -aG docker $USER
            print_warning "Please log out and back in for group changes to take effect"
        fi
    else
        print_status "Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker $USER
        print_warning "Please log out and back in for Docker group changes to take effect"
    fi
}

# Install mnibuilder (from private repo, requires gh CLI)
install_mnibuilder() {
    if command -v mnibuilder >/dev/null 2>&1; then
        print_status "mnibuilder is already installed"
    else
        # Get version from components.yaml if available
        CONFIG_FILE="${SCRIPT_DIR}/components.yaml"
        if [ -f "$CONFIG_FILE" ] && command -v yq >/dev/null 2>&1; then
            MNIBUILDER_VERSION=$(yq eval '.build_tools.mnibuilder_version' "$CONFIG_FILE")
        elif [ -f "$CONFIG_FILE" ] && command -v python3 >/dev/null 2>&1; then
            MNIBUILDER_VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG_FILE'))['build_tools']['mnibuilder_version'])" 2>/dev/null)
        fi
        
        # Default version if not specified
        MNIBUILDER_VERSION=${MNIBUILDER_VERSION:-"v0.0.3"}
        
        print_status "Installing mnibuilder ${MNIBUILDER_VERSION}..."
        
        # mnibuilder is in a private repo, need gh CLI
        if command -v gh >/dev/null 2>&1; then
            # Check gh auth status
            if ! gh auth status &>/dev/null; then
                print_warning "GitHub CLI not authenticated. Please login first:"
                gh auth login
            fi
            
            # Download to /tmp like other tools
            gh release download "${MNIBUILDER_VERSION}" \
                --repo mNi-Cloud/mnibuilder \
                --pattern "mnibuilder_Linux_x86_64.tar.gz" \
                --dir /tmp \
                --clobber || {
                print_error "Failed to download mnibuilder ${MNIBUILDER_VERSION}"
                print_warning "Make sure you have access to the mNi-Cloud/mnibuilder repository"
                return 1
            }
            
            # Extract and install
            tar -xzf /tmp/mnibuilder_Linux_x86_64.tar.gz -C /tmp
            mv /tmp/mnibuilder "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/mnibuilder"
            rm /tmp/mnibuilder_Linux_x86_64.tar.gz  # Clean up
            
            print_status "mnibuilder ${MNIBUILDER_VERSION} installed successfully"
        else
            print_error "GitHub CLI (gh) is required to download mnibuilder from private repo"
            print_warning "Please install gh first or run this script later after gh is installed"
            return 1
        fi
    fi
}

# Install aqua
install_aqua() {
    if command -v aqua >/dev/null 2>&1; then
        print_status "aqua is already installed"
    else
        print_status "Installing aqua..."
        AQUA_VERSION="2.38.0"
        wget -q --show-progress "https://github.com/aquaproj/aqua/releases/download/v${AQUA_VERSION}/aqua_linux_amd64.tar.gz" -O /tmp/aqua.tar.gz
        tar -xzf /tmp/aqua.tar.gz -C /tmp
        mv /tmp/aqua "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/aqua"
        rm /tmp/aqua.tar.gz
        
        # Add aqua path to bashrc
        if ! grep -q "AQUA_ROOT_DIR" ~/.bashrc; then
            echo 'export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua' >> ~/.bashrc
            echo 'export PATH=$AQUA_ROOT_DIR/bin:$PATH' >> ~/.bashrc
        fi
        export AQUA_ROOT_DIR=$HOME/.local/share/aquaproj-aqua
        export PATH=$AQUA_ROOT_DIR/bin:$PATH
        print_status "aqua installed successfully"
    fi
}

# Install direnv
install_direnv() {
    if command -v direnv >/dev/null 2>&1; then
        print_status "direnv is already installed"
    else
        print_status "Installing direnv..."
        DIRENV_VERSION="2.35.0"
        wget -q --show-progress "https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}/direnv.linux-amd64" -O "$INSTALL_DIR/direnv"
        chmod +x "$INSTALL_DIR/direnv"
        
        # Add direnv hook to bashrc
        if ! grep -q "direnv hook bash" ~/.bashrc; then
            echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
        fi
        print_status "direnv installed successfully"
    fi
}

# Install tmux
install_tmux() {
    if command -v tmux >/dev/null 2>&1; then
        print_status "tmux is already installed"
    else
        print_status "Installing tmux..."
        # Try package manager first
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y tmux
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y tmux
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --noconfirm tmux
        else
            # Fallback to binary
            print_warning "Installing tmux as AppImage..."
            wget -q --show-progress "https://github.com/nelsonenzo/tmux-appimage/releases/download/v3.5a/tmux-3.5a.AppImage" -O "$INSTALL_DIR/tmux"
            chmod +x "$INSTALL_DIR/tmux"
        fi
        print_status "tmux installed successfully"
    fi
}

# Install yq for YAML processing
install_yq() {
    if command -v yq >/dev/null 2>&1; then
        print_status "yq is already installed"
    else
        print_status "Installing yq..."
        wget -q --show-progress "https://github.com/mikefarah/yq/releases/download/v4.35.2/yq_linux_amd64" -O "$INSTALL_DIR/yq"
        chmod +x "$INSTALL_DIR/yq"
        print_status "yq installed successfully"
    fi
}

# Install Tilt (will be managed by aqua, but install as fallback)
install_tilt() {
    if command -v tilt >/dev/null 2>&1; then
        print_status "Tilt is already installed"
    else
        print_status "Installing Tilt..."
        curl -fsSL https://raw.githubusercontent.com/tilt-dev/tilt/master/scripts/install.sh | bash
        print_status "Tilt installed successfully"
    fi
}

# Install GitHub CLI
install_gh() {
    if command -v gh >/dev/null 2>&1; then
        print_status "GitHub CLI is already installed"
    else
        print_status "Installing GitHub CLI..."
        # Download latest release
        GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        if [ -z "$GH_VERSION" ]; then
            GH_VERSION="2.45.0"  # Fallback version
        fi
        wget -q --show-progress "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" -O /tmp/gh.tar.gz
        tar -xzf /tmp/gh.tar.gz -C /tmp
        mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/gh"
        rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_amd64
        print_status "GitHub CLI installed successfully"
    fi
}

# Add local bin to PATH
setup_path() {
    if ! grep -q "$INSTALL_DIR" ~/.bashrc; then
        echo "export PATH=$INSTALL_DIR:\$PATH" >> ~/.bashrc
    fi
    export PATH=$INSTALL_DIR:$PATH
}

# Main installation
main() {
    print_status "Starting installation of development tools..."
    
    # Setup PATH first
    setup_path
    
    # Install tools in order
    # Install gh first (needed for private repos)
    install_gh
    install_go
    install_docker
    install_mnibuilder  # Requires gh for private repo access
    install_aqua
    install_direnv
    install_tmux
    install_yq
    install_tilt
    
    echo ""
    print_status "Installation complete!"
    echo ""
    echo "=== Installed Tools ===" 
    go version 2>/dev/null || print_error "Go not found"
    docker --version 2>/dev/null || print_error "Docker not found"
    mnibuilder version 2>/dev/null || print_error "mnibuilder not found"
    aqua version 2>/dev/null || print_error "aqua not found"
    direnv version 2>/dev/null || print_error "direnv not found"
    tmux -V 2>/dev/null || print_error "tmux not found"
    yq --version 2>/dev/null || print_error "yq not found"
    tilt version 2>/dev/null || print_error "Tilt not found"
    gh --version 2>/dev/null || print_error "GitHub CLI not found"
    
    echo ""
    print_warning "IMPORTANT: Run 'source ~/.bashrc' to update your PATH"
    print_warning "If you were added to docker group, log out and back in"
    echo ""
    print_status "Next step: Run './setup-env.sh' to configure environment"
}

main "$@"