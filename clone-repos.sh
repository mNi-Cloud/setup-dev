#!/bin/bash
set -e

echo "=== Clone/Update mni-backend Components ==="

# Base directories - works from any location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNI_ROOT="$(dirname "$SCRIPT_DIR")"
BACKEND_DIR="${MNI_ROOT}/mni-backend"
CONFIG_FILE="${SCRIPT_DIR}/components.yaml"

# Create backend directory if it doesn't exist
mkdir -p "$BACKEND_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    if ! command_exists git; then
        print_error "git is not installed. Please install git first."
        exit 1
    fi
    
    if ! command_exists yq && ! command_exists python3; then
        print_warning "yq or python3 not found. Installing yq..."
        wget -q -O /tmp/yq "https://github.com/mikefarah/yq/releases/download/v4.35.2/yq_linux_amd64"
        chmod +x /tmp/yq
        sudo mv /tmp/yq /usr/local/bin/yq
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
}

# Parse YAML using yq or python
parse_yaml() {
    local query=$1
    
    if command_exists yq; then
        yq eval "$query" "$CONFIG_FILE"
    elif command_exists python3; then
        python3 -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)
    query = '$query'.replace('.', ' ').split()
    result = data
    for key in query:
        if key.startswith('[') and key.endswith(']'):
            index = int(key[1:-1])
            result = result[index]
        else:
            result = result.get(key, '')
    print(result if result else '')
"
    else
        print_error "No YAML parser available (yq or python3 with yaml)"
        exit 1
    fi
}

# Get component count
get_component_count() {
    if command_exists yq; then
        yq eval '.components | length' "$CONFIG_FILE"
    else
        python3 -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)
    print(len(data.get('components', [])))
"
    fi
}

# Get component info
get_component_info() {
    local index=$1
    local field=$2
    
    if command_exists yq; then
        yq eval ".components[$index].$field" "$CONFIG_FILE"
    else
        python3 -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)
    components = data.get('components', [])
    if $index < len(components):
        print(components[$index].get('$field', ''))
"
    fi
}

# Clone or update repository
clone_or_update_repo() {
    local name=$1
    local repo=$2
    local component_dir="${BACKEND_DIR}/${name}"
    
    print_status "Processing $name..."
    
    # Create backend directory if it doesn't exist
    mkdir -p "$BACKEND_DIR"
    
    if [ -d "$component_dir/.git" ]; then
        print_status "$name already cloned, pulling latest changes..."
        cd "$component_dir"
        
        # Stash any local changes
        if ! git diff --quiet || ! git diff --cached --quiet; then
            print_warning "Local changes detected in $name, stashing..."
            git stash push -m "Auto-stash before pull $(date +%Y%m%d-%H%M%S)"
        fi
        
        # Pull latest changes
        git pull origin main 2>/dev/null || git pull origin master || {
            print_warning "Failed to pull from main/master, trying current branch..."
            git pull
        }
        
        cd - > /dev/null
    else
        print_status "Cloning $name..."
        git clone "$repo" "$component_dir"
    fi
}

# Setup GitHub authentication
setup_github_auth() {
    print_status "Checking GitHub authentication..."
    
    # Check if we can access private repos
    if ! git ls-remote https://github.com/mNi-Cloud/dependency-controller.git &>/dev/null; then
        print_warning "Cannot access private mNi-Cloud repositories"
        echo ""
        echo "Please configure GitHub access using one of these methods:"
        echo "1. GitHub Personal Access Token (recommended):"
        echo "   git config --global url.'https://YOUR_TOKEN@github.com/'.insteadOf 'https://github.com/'"
        echo ""
        echo "2. SSH Key:"
        echo "   git config --global url.'git@github.com:'.insteadOf 'https://github.com/'"
        echo ""
        read -p "Have you configured GitHub access? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "GitHub authentication required. Please configure and try again."
            exit 1
        fi
    else
        print_status "GitHub authentication OK"
    fi
}

# Main function
main() {
    print_status "Starting repository setup..."
    
    check_prerequisites
    setup_github_auth
    
    # Get component count
    component_count=$(get_component_count)
    print_status "Found $component_count components in configuration"
    
    # Process each component
    for ((i=0; i<$component_count; i++)); do
        name=$(get_component_info $i "name")
        repo=$(get_component_info $i "repo")
        
        if [ -n "$name" ] && [ -n "$repo" ]; then
            clone_or_update_repo "$name" "$repo"
        fi
    done
    
    print_status "All repositories processed successfully!"
    
    # Show summary
    echo ""
    echo -e "${BLUE}=== Repository Summary ===${NC}"
    for ((i=0; i<$component_count; i++)); do
        name=$(get_component_info $i "name")
        type=$(get_component_info $i "type")
        has_tiltfile=$(get_component_info $i "has_tiltfile")
        
        if [ -d "${BACKEND_DIR}/${name}" ]; then
            echo -e "  ${GREEN}✓${NC} $name ($type) - Tiltfile: $has_tiltfile"
        else
            echo -e "  ${RED}✗${NC} $name ($type) - Not found"
        fi
    done
}

main "$@"