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

# ---- HELPER FUNCTION: Run as User with Systemd Context ----
run_as_user() {
    local user="$1"
    shift
    local uid
    uid="$(id -u "$user")"
    
    # Wait for the user's systemd bus to be ready
    local bus_path="/run/user/$uid/bus"
    local timeout=10
    while [[ ! -e "$bus_path" && $timeout -gt 0 ]]; do
        sleep 1
        ((timeout--))
    done

    # Inject environment variables manually for this specific execution
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path" \
        PATH="/usr/bin:/bin:$PATH" \
        "$@"
}

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
    print_status "Stopping and disabling rootful Docker services..."
    
    # Stop and disable rootful Docker services 
    systemctl stop docker.service || true
    systemctl stop docker.socket || true
    systemctl disable docker.service || true
    systemctl disable docker.socket || true
    
    # Remove snap Docker installations (conflicts with Docker CE)
    if command -v snap &> /dev/null && snap list | grep -q docker 2>/dev/null; then
        print_warning "Removing snap Docker..."
        snap remove docker || true
    fi
    
    # Clean up socket files from rootful installation
    rm -rf /var/run/docker.sock /var/run/docker/ || true
    
    print_success "Rootful Docker services stopped and disabled"
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
        useradd -m -s /bin/bash "$DOCKER_USER"
        print_success "User $DOCKER_USER created"
    fi
    [[ "$ADD_TO_DOCKER_GROUP" == "true" ]] && usermod -aG docker "$DOCKER_USER"
    usermod -aG systemd-journal "$DOCKER_USER" || true
    configure_subuid_subgid
}

# Verify required binaries
verify_binaries() {
    print_status "Verifying required binaries..."
    command -v dockerd-rootless-setuptool.sh >/dev/null || { print_error "dockerd-rootless-setuptool.sh not found"; exit 1; }
    
    if command -v slirp4netns >/dev/null; then
        local v
        v=$(slirp4netns --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        [[ $(echo -e "0.4.0\n$v" | sort -V | head -n1) == "0.4.0" ]] || { print_error "slirp4netns too old"; exit 1; }
    fi
}

# Setup AppArmor profile for rootlesskit
setup_apparmor_profile() {
    print_status "Setting up AppArmor profile for rootlesskit..."
    
    # FIX: Derive filename once to ensure consistency between user-space and root-space
    local user_home
    user_home=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
    local profile_name
    profile_name=$(echo "${user_home}/bin/rootlesskit" | sed -e s@^/@@ -e s@/@.@g)

    run_as_user "$DOCKER_USER" bash <<EOF
set -e
cat <<APPARMOR_EOF > ~/${profile_name}
abi <abi/4.0>,
include <tunables/global>
"${user_home}/bin/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/${profile_name}>
}
APPARMOR_EOF
EOF

    # Move to system directory as root
    if [[ -f "${user_home}/${profile_name}" ]]; then
        mv "${user_home}/${profile_name}" "/etc/apparmor.d/${profile_name}"
        print_success "AppArmor profile configured"
    fi
}

# Setup rootless Docker for user
setup_rootless_docker() {
    print_status "Setting up rootless Docker for $DOCKER_USER..."
    
    if [[ -n "$CUSTOM_DATA_ROOT" ]]; then
        mkdir -p "$CUSTOM_DATA_ROOT"
        chown "$DOCKER_USER:$DOCKER_USER" "$CUSTOM_DATA_ROOT"
    fi

    loginctl enable-linger "$DOCKER_USER"
    
    local LOG_DRIVER LOG_OPTS DATA_ROOT_JSON=""
    if [[ "$USE_REMOTE_LOGGING" == "true" ]]; then
        LOG_DRIVER="syslog"
        LOG_OPTS="{ \"syslog-address\": \"$REMOTE_SYSLOG_ADDRESS\" }"
    else
        LOG_DRIVER="local"
        LOG_OPTS="{ \"max-size\": \"256m\", \"max-file\": \"3\" }"
    fi

    [[ -n "$CUSTOM_DATA_ROOT" ]] && DATA_ROOT_JSON=",\n  \"data-root\": \"$CUSTOM_DATA_ROOT\""

    run_as_user "$DOCKER_USER" bash <<EOF
set -e
dockerd-rootless-setuptool.sh uninstall -f || true
rm -rf ~/.local/share/docker || true
dockerd-rootless-setuptool.sh install

mkdir -p ~/.config/docker
cat > ~/.config/docker/daemon.json <<JSON
{
  "no-new-privileges": true,
  "userland-proxy": false,
  "storage-driver": "overlay2"${DATA_ROOT_JSON},
  "log-driver": "$LOG_DRIVER",
  "log-opts": $LOG_OPTS,
  "icc": false
}
JSON

systemctl --user daemon-reload
systemctl --user enable docker
systemctl --user start docker

# FIX: Only export DOCKER_HOST. Leave XDG_RUNTIME_DIR to systemd.
if ! grep -q "DOCKER_HOST" ~/.bashrc; then
cat >> ~/.bashrc <<BASHRC_EOF

# Docker rootless environment variables
# NOTE: XDG_RUNTIME_DIR is managed by systemd; do not force it here.
export DOCKER_HOST=unix:///run/user/\\\$(id -u)/docker.sock
BASHRC_EOF
fi
EOF

    print_success "Rootless Docker configured for $DOCKER_USER"
}

# Validate rootless setup
validate_setup() {
    print_status "Validating rootless Docker setup..."
    run_as_user "$DOCKER_USER" bash <<'EOF'
for i in {1..30}; do
    if docker version &>/dev/null; then break; fi
    sleep 2
done

if docker info 2>/dev/null | grep -q "rootless"; then
    print_success "Docker is running in rootless mode"
else
    exit 1
fi
docker run --rm hello-world &>/dev/null
EOF
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

main "$@"