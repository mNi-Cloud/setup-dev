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
        # Extract org/repo from URL (https://github.com/mNi-Cloud/dependency-controller.git -> mNi-Cloud/dependency-controller)
        local gh_repo=$(echo "$repo" | sed -E 's|https://github.com/||; s|\.git$||')
        
        # Use gh CLI to clone (handles auth automatically)
        if command -v gh >/dev/null 2>&1; then
            gh repo clone "$gh_repo" "$component_dir"
        else
            # Fallback to git clone
            git clone "$repo" "$component_dir"
        fi
    fi
}

# Setup GitHub authentication
setup_github_auth() {
    print_status "Checking GitHub authentication..."
    
    # Check if gh CLI is installed
    if ! command -v gh >/dev/null 2>&1; then
        print_error "GitHub CLI (gh) is not installed"
        print_warning "Please run './setup-tools.sh' first to install gh"
        exit 1
    fi
    
    # Check if gh is authenticated
    if ! gh auth status &>/dev/null; then
        print_warning "GitHub CLI is not authenticated"
        echo ""
        echo "Please authenticate with GitHub:"
        echo ""
        gh auth login
        
        # Setup git to use gh CLI authentication
        print_status "Setting up git to use GitHub CLI authentication..."
        gh auth setup-git
    else
        print_status "GitHub CLI authentication OK"
        
        # Ensure git is configured to use gh auth
        gh auth setup-git &>/dev/null || true
    fi
    
    # Verify we can access private repos
    print_status "Verifying access to private repositories..."
    if ! gh repo view mNi-Cloud/dependency-controller &>/dev/null; then
        print_error "Cannot access private mNi-Cloud repositories"
        print_warning "Please ensure you have access to the mNi-Cloud organization"
        exit 1
    fi
    
    print_status "GitHub authentication configured successfully"
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