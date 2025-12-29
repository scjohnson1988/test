#!/bin/bash
# Simplified script to setup rootless Docker on Ubuntu and RHEL systems
# Must be run as root
# REFERENCE: https://docs.docker.com/engine/security/rootless/



### GENERAL NOTES ###
#A great troubleshooting tool is to run 'dockerd-rootless.sh' as the user
#If you have network errors, either add this 'Environment=DOCKER_IGNORE_BR_NETFILTER_ERROR=1' to [Service] section here /home/a2i2.docker/.config/systemd/user as a workaround
#To fix the above error, run modprobe br_netfilter as root (verify via checking /proc/sys/net/bridge/bridge-nf-call-iptables)
#To check the CONTEXT of docker, run: docker context.  You can also run 'docker context inspect rootless' top view more information on it.
#To EDIT the context of docker, run (update as needed): docker context update rootless --docker "host=unix:///run/user/1003/docker.sock"


set -euo pipefail

# ---- CONFIGURATION ----
DOCKER_USER="a2i2.docker"
CUSTOM_DATA_ROOT="/docker/docker"  # Set to absolute path if desired, leave empty for default
ADD_TO_DOCKER_GROUP=true  # Set to true to add user to docker group
USE_REMOTE_LOGGING=true   # Set to true to use remote syslog logging
REMOTE_SYSLOG_ADDRESS="udp://10.74.4.3:514"  # Update as needed

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Detect OS and set package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            PACKAGE_MANAGER="apt-get"
            ;;
        rhel|centos|fedora|rocky|almalinux)
            PACKAGE_MANAGER="dnf"
            if ! command -v dnf &> /dev/null; then
                PACKAGE_MANAGER="yum"
            fi
            ;;
        *)
            print_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    print_status "Detected OS: $OS using $PACKAGE_MANAGER"
}

# Load required kernel modules
load_kernel_modules() {
    print_status "Loading required kernel modules..."
    modprobe br_netfilter || print_warning "Failed to load br_netfilter module"
    print_success "Kernel modules loaded"
	echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
}

# Remove existing Docker installations
remove_existing_docker() {
    print_status "Stopping and removing existing Docker installations..."
    
    # Stop services
    systemctl stop docker docker.socket || true
    systemctl disable docker docker.socket || true
    
    # Stop snap docker if running
    if command -v snap &> /dev/null && snap list | grep -q docker 2>/dev/null; then
        print_warning "Removing snap Docker..."
        snap remove docker || true
    fi
    
    # Remove non-Docker CE packages based on OS
    case $PACKAGE_MANAGER in
        apt-get)
            $PACKAGE_MANAGER remove -y docker.io || true
            ;;
        dnf|yum)
            $PACKAGE_MANAGER remove -y docker.io || true
            ;;
    esac
    
    # Delete docker socket
    rm -rf /var/run/docker.sock || true
    
    print_success "Existing Docker installations removed"
}

# Install required dependencies
install_dependencies() {
    print_status "Installing required packages..."
    
    case $PACKAGE_MANAGER in
        apt-get)
            $PACKAGE_MANAGER update
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras uidmap dbus-user-session
            ;;
        dnf|yum)
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras uidmap
            ;;
    esac
    
    print_success "Dependencies installed"
}

# Configure subuid/subgid
configure_subuid_subgid() {
    print_status "Configuring subuid/subgid for $DOCKER_USER..."
    if ! grep -q "^$DOCKER_USER:" /etc/subuid; then
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$DOCKER_USER"
        print_success "subuid/subgid configured for $DOCKER_USER"
    else
        print_success "subuid/subgid already configured"
    fi
}

# Verify/create user
verify_user() {
    print_status "Verifying user: $DOCKER_USER"
    
    if ! id "$DOCKER_USER" &>/dev/null; then
        print_status "User $DOCKER_USER does not exist. Creating user..."
        useradd -m -s /bin/bash "$DOCKER_USER"
        print_success "User $DOCKER_USER created with /bin/bash shell"
    else
        print_success "User $DOCKER_USER exists"
    fi
    
    # Add to docker group if requested
    if [[ "$ADD_TO_DOCKER_GROUP" == "true" ]]; then
        print_status "Adding $DOCKER_USER to docker group"
        usermod -aG docker "$DOCKER_USER"
    fi
    
    # Add to systemd-journal group (may be needed for logging)
    usermod -aG systemd-journal "$DOCKER_USER" || true
    
    # Configure subuid/subgid
    configure_subuid_subgid
}

# Verify required binaries
verify_binaries() {
    print_status "Verifying required binaries..."
    
    # Check dockerd-rootless-setuptool.sh
    local DOCKERD_ROOTLESS_SETUPTOOL
    if DOCKERD_ROOTLESS_SETUPTOOL="$(command -v dockerd-rootless-setuptool.sh)"; then
        if [[ ! -x "$DOCKERD_ROOTLESS_SETUPTOOL" ]]; then
            print_error "dockerd-rootless-setuptool.sh found but not executable"
            exit 1
        fi
        print_success "dockerd-rootless-setuptool.sh found and executable"
    else
        print_error "dockerd-rootless-setuptool.sh not found"
        exit 1
    fi
    
    # Check dockerd-rootless.sh
    local DOCKERD_ROOTLESS_SH
    if DOCKERD_ROOTLESS_SH="$(command -v dockerd-rootless.sh)"; then
        if [[ ! -x "$DOCKERD_ROOTLESS_SH" ]]; then
            print_error "dockerd-rootless.sh found but not executable"
            exit 1
        fi
        print_success "dockerd-rootless.sh found and executable"
    else
        print_error "dockerd-rootless.sh not found"
        exit 1
    fi
    
    # Check slirp4netns
    local SLIRP4NETNS_BIN
    if SLIRP4NETNS_BIN="$(command -v slirp4netns)"; then
        chmod 755 "$SLIRP4NETNS_BIN"
        
        # Check version
        local SLIRP_VERSION
        SLIRP_VERSION=$(slirp4netns --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        if [[ $(echo -e "0.4.0\n$SLIRP_VERSION" | sort -V | head -n1) == "0.4.0" ]]; then
            print_success "slirp4netns version $SLIRP_VERSION is sufficient (>= 0.4.0)"
        else
            print_error "slirp4netns version $SLIRP_VERSION is too old (< 0.4.0)"
            exit 1
        fi
    else
        print_error "slirp4netns not found"
        exit 1
    fi
}

# Setup AppArmor profile for rootlesskit
setup_apparmor_profile() {
    print_status "Setting up AppArmor profile for rootlesskit..."
    
    su - "$DOCKER_USER" <<'EOF'
set -e

# Create AppArmor profile for rootlesskit
filename=$(echo $HOME/bin/rootlesskit | sed -e s@^/@@ -e s@/@.@g)
cat <<APPARMOR_EOF > ~/${filename}
abi <abi/4.0>,
include <tunables/global>
"$HOME/bin/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/${filename}>
}
APPARMOR_EOF

# Move to system AppArmor directory (requires sudo)
sudo mv ~/${filename} /etc/apparmor.d/${filename}
echo "AppArmor profile created for rootlesskit"
EOF

    print_success "AppArmor profile configured"
}

# Setup rootless Docker for user
setup_rootless_docker() {
    print_status "Setting up rootless Docker for $DOCKER_USER..."
    
    if [[ -n "$CUSTOM_DATA_ROOT" && ! "$CUSTOM_DATA_ROOT" =~ ^/ ]]; then
        print_error "Data-root path must be absolute"
        exit 1
    fi
    
    if [[ -n "$CUSTOM_DATA_ROOT" ]]; then
        print_status "Creating custom data-root: $CUSTOM_DATA_ROOT"
        mkdir -p "$CUSTOM_DATA_ROOT"
        chown "$DOCKER_USER:$DOCKER_USER" "$CUSTOM_DATA_ROOT"
    fi

    # Enable linger BEFORE setting up rootless Docker (must be done as root)
    print_status "Enabling linger for $DOCKER_USER..."
    loginctl enable-linger "$DOCKER_USER"
    print_success "Linger enabled for $DOCKER_USER"
	
    # Prepare JSON config components
    local LOG_DRIVER LOG_OPTS
    if [[ "$USE_REMOTE_LOGGING" == "true" ]]; then
        LOG_DRIVER="syslog"
        LOG_OPTS="{ \"syslog-address\": \"$REMOTE_SYSLOG_ADDRESS\" }"
    else
        LOG_DRIVER="local"
        LOG_OPTS="{ \"max-size\": \"256m\", \"max-file\": \"3\" }"
    fi

    local DATA_ROOT_JSON=""
    if [[ -n "$CUSTOM_DATA_ROOT" ]]; then
        DATA_ROOT_JSON=",\n  \"data-root\": \"$CUSTOM_DATA_ROOT\""
    fi

    su - "$DOCKER_USER" <<EOF
set -e

# Clean up previous Docker config
dockerd-rootless-setuptool.sh uninstall -f || true
rm -rf ~/.local/share/docker || true

# Install rootless Docker
dockerd-rootless-setuptool.sh install

# Write daemon.json with dynamic config
mkdir -p ~/.config/docker

cat > ~/.config/docker/daemon.json <<JSON
{
  "experimental": false,
  "no-new-privileges": true,
  "userland-proxy": false,
  "selinux-enabled": false,
  "cgroup-parent": "",
  "storage-driver": "overlay2"${DATA_ROOT_JSON},
  "insecure-registries": [],
  "log-driver": "$LOG_DRIVER",
  "live-restore": true,
  "log-level": "info",
  "icc": false,
  "log-opts": $LOG_OPTS,
  "default-ulimits": {
    "nofile": {
      "Hard": 64000,
      "Name": "nofile",
      "Soft": 64000
    }
  }
}
JSON

if command -v jq &>/dev/null; then
    jq empty ~/.config/docker/daemon.json || echo "Warning: daemon.json syntax error"
fi


mkdir -p ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user enable docker
systemctl --user start docker

# Configure environment variables
cat >> ~/.bashrc <<BASHRC_EOF

# Docker rootless environment variables
export XDG_RUNTIME_DIR="/run/user/\$UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\${XDG_RUNTIME_DIR}/bus"
export PATH=/usr/bin:\$PATH
export DOCKER_HOST=unix:///run/user/\$(id -u)/docker.sock
BASHRC_EOF

echo "Rootless Docker setup complete!"
EOF

    print_success "Rootless Docker configured for $DOCKER_USER"
}

# Validate rootless setup
validate_setup() {
    print_status "Validating rootless Docker setup..."
    
    su - "$DOCKER_USER" <<'EOF'
# Wait for Docker to be ready
echo "Waiting for Docker daemon to be ready..."
for i in {1..30}; do
    if docker version &>/dev/null; then
        break
    fi
    sleep 2
done

# Check if systemd service is running
echo "Checking if Docker service is running..."
if ! systemctl --user is-active --quiet docker; then
    echo "✗ Docker service is not running"
    systemctl --user status docker
    exit 1
fi
echo "✓ Docker service is running"

# Check if Docker is running in rootless mode
echo "Checking rootless mode..."
if docker info 2>/dev/null | grep -q "rootless"; then
    echo "✓ Docker is running in rootless mode"
    docker info | grep -E "(Context:|rootless)"
else
    echo "✗ Docker is not running in rootless mode"
    exit 1
fi

# Test with hello-world
echo "Testing with hello-world container..."
if docker run --rm hello-world &>/dev/null; then
    echo "✓ Docker test successful"
else
    echo "✗ Docker test failed"
    exit 1
fi

EOF

    if [[ $? -eq 0 ]]; then
        print_success "Rootless Docker validation successful!"
    else
        print_error "Rootless Docker validation failed!"
        exit 1
    fi
	
echo "Review the below to ensure the Docker context is rootless, the 'docker' command us using the correct socket, and it is in rootless mode"
docker context
docker info | grep rootless
}

# Main execution
main() {
    print_status "Starting rootless Docker setup..."
    
    detect_os
    load_kernel_modules
    remove_existing_docker
    install_dependencies
    verify_user
    verify_binaries
    setup_apparmor_profile
    setup_rootless_docker
    validate_setup
    
    print_success "Setup complete! Switch to user with: su - $DOCKER_USER"
}

# Run main function
main "$@"