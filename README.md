# mni-backend Development Environment

Complete development environment setup for mni-backend components.

## Quick Start

Run the complete setup:
```bash
./setup-all.sh
```

This will:
1. Install all required tools
2. Clone/update repositories  
3. Configure environment
4. Start Docker registry
5. Prepare dependencies
6. Optionally start Tilt

## Required Tools

All tools are installed as binaries (no package manager dependencies):
- **Go 1.24.2** - Programming language
- **Docker** - Container runtime
- **mnibuilder** - mNi Cloud project scaffolding tool
- **aqua** - CLI version manager
- **direnv** - Environment variable management (installed but not required)
- **tmux** - Terminal multiplexer for managing Tilt sessions
- **yq** - YAML processor
- **Tilt** - Kubernetes development tool
- **gh** - GitHub CLI for authentication and repository access

## Components

Configured in `components.yaml`:
- **dependency-controller** - Provides CRDs, must start first
- **api-gateway** - API gateway service
- **vpc-controller** - VPC management controller
- **cli** - Command line interface (no Tiltfile)

Add new components by editing `components.yaml`.

## Individual Scripts

### setup-tools.sh
Installs all required development tools as binaries.
```bash
./setup-tools.sh
```

### clone-repos.sh
Clones or updates all component repositories from GitHub using GitHub CLI.
```bash
./clone-repos.sh
```
Automatically uses `gh auth login` if not authenticated.

### setup-env.sh  
Configures environment variables and installs aqua packages.
```bash
./setup-env.sh
```

### setup-registry.sh
Starts Docker registry at localhost:5000.
```bash
./setup-registry.sh
```

### prepare-deps.sh
Downloads Go dependencies and runs initial build for all components.
```bash
./prepare-deps.sh
```

### tilt-up.sh
Starts Tilt for all components in tmux session.
```bash
./tilt-up.sh
```
- Creates tmux session "mni-tilt"
- Starts dependency-controller first
- Each component gets its own tmux window
- Tilt UIs on sequential ports starting from 10350

### tilt-down.sh
Stops all Tilt instances and cleans up.
```bash
./tilt-down.sh
```

### tilt-status.sh
Shows status of Tilt instances and Kubernetes deployments.
```bash
./tilt-status.sh
```

## Environment Variables

Automatically configured:
- `GOPRIVATE=github.com/mNi-Cloud`
- `TILT_ALLOW_K8S_CONTEXT=kubernetes-admin@kubernetes`
- `TILT_REGISTRY=localhost:5000`

## Tilt UI URLs

After running `tilt-up.sh`:
- dependency-controller: http://localhost:10350
- api-gateway: http://localhost:10351  
- vpc-controller: http://localhost:10352

## Tmux Commands

- Attach to session: `tmux attach -t mni-tilt`
- List windows: `Ctrl-b w`
- Switch window: `Ctrl-b [number]`
- Detach: `Ctrl-b d`

## Troubleshooting

### GitHub Access
The setup uses GitHub CLI for authentication. If not already authenticated:
```bash
# Login to GitHub (will be prompted during clone-repos.sh)
gh auth login

# Manual login if needed
gh auth login --web

# Check authentication status
gh auth status
```

GitHub CLI automatically handles authentication for git operations.

### Docker Registry
If registry is not accessible:
```bash
docker run -d --restart=unless-stopped --name registry -p 5000:5000 registry:2
```

### Kubernetes Connection
Ensure kubectl is configured:
```bash
kubectl cluster-info
```

## Adding New Components

1. Edit `components.yaml`:
```yaml
- name: new-controller
  repo: https://github.com/mNi-Cloud/new-controller.git
  type: controller
  has_tiltfile: true
  tilt_port: 10353
  required: false
```

2. Run setup:
```bash
./clone-repos.sh
./setup-env.sh
./prepare-deps.sh
./tilt-up.sh
```

Components with `has_tiltfile: true` will be automatically managed by Tilt.