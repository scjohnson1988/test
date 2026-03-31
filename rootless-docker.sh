#!/bin/bash
# Refactored script to setup rootless Docker on Ubuntu and RHEL systems
# Must be run as root
# REFERENCE: https://docs.docker.com/engine/security/rootless/

### GENERAL NOTES ###
#Always use './rootless-docker.sh' or 'bash rootless-docker.sh'; do NOT use 'sh'.
#A great troubleshooting tool is to run 'dockerd-rootless.sh' as the user
#If you have network errors, either add this 'Environment=DOCKER_IGNORE_BR_NETFILTER_ERROR=1' to [Service] section here /home/a2i2.docker/.config/systemd/user as a workaround
#To fix the above error, run modprobe br_netfilter as root (verify via checking /proc/sys/net/bridge/bridge-nf-call-iptables)
#To check the CONTEXT of docker, run: docker context.  You can also run 'docker context inspect rootless' top view more information on it.
#To EDIT the context of docker, run (update as needed): docker context update rootless --docker "host=unix:///run/user/1003/docker.sock"
#For RHEL8, it may not be possible to use DISABLE_ICC.

set -euo pipefail
trap 'echo "[ERROR] Line $LINENO failed"' ERR

# ---- CONFIGURATION ----
DOCKER_USER="a2i2.docker"
CUSTOM_DATA_ROOT="/docker/docker"  # Set to absolute path if desired, leave empty for default
ADD_TO_DOCKER_GROUP=true
USE_REMOTE_LOGGING=true
REMOTE_SYSLOG_ADDRESS="udp://10.74.4.3:514"
STORAGE_DRIVER="" # Auto-detects based on OS/SELinux
DISABLE_ICC=false # Set to true to enforce CIS benchmark in daemon.json (may require troubleshooting on RHEL8 and likely will not work)
APPLY_SELINUX_FIXES=true # Automatically create a temporary SELinux module for any denials that may have been detected 
ENABLE_IP_FORWARD=true # Generally a good idea to leave this enabled, as it is no longer a STIG to ahve it on 

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Run this as root 
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Ensure this is called with 'bash' instead of 'sh'
# Ensure the script is ran with bash and not sh or in POSIX mode.
if set -o | grep -Eq '^posix[[:space:]]+on$'; then
  echo "Error: This script requires bash. Please run it with 'bash rootless-docker.sh' or './rootless-docker.sh'."
  exit 1
fi


# ---- HELPER FUNCTION: Run as User without SSH ----
# Uses sudo to securely switch users while explicitly passing required systemd variables
run_as_user() {
    local user="$1"
    local uid
    uid="$(id -u "$user")"
    
    # Ensure linger is on and session is active
    loginctl enable-linger "$user" 2>/dev/null || true
    systemctl start "user@${uid}.service" 2>/dev/null || true

    # Execute the piped heredoc with correct XDG variables
    sudo -H -u "$user" env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" bash
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "/etc/os-release not found."
        exit 1
    fi
    
    case $OS in
        ubuntu|debian)
            PACKAGE_MANAGER="apt-get"
            ;;
        rhel|centos|fedora|rocky|almalinux)
            PACKAGE_MANAGER="dnf"
            if ! command -v dnf &> /dev/null; then PACKAGE_MANAGER="yum"; fi
            ;;
        *)
            print_error "Unsupported OS: $OS"; exit 1 ;;
    esac
    print_status "Detected OS: $OS using $PACKAGE_MANAGER"
}

handle_selinux_start() {
    SELINUX_WAS_ENFORCING=false
    if command -v getenforce &>/dev/null; then
        if [[ "$(getenforce)" == "Enforcing" ]]; then
            print_warning "SELinux is Enforcing. Temporarily setting to Permissive for installation..."
            setenforce 0
            SELINUX_WAS_ENFORCING=true
        fi
    fi
}

handle_selinux_end() {
    if [[ "$SELINUX_WAS_ENFORCING" == "true" ]]; then
        print_status "Restoring SELinux enforcement..."
        sleep 3  # Let auditd flush

        if [[ "$APPLY_SELINUX_FIXES" == "true" ]]; then
            print_warning "APPLY_SELINUX_FIXES enabled - generating temporary SELinux module from ALL denials"

            audit2allow -aM temp_docker_module 2>/dev/null || true

            if [[ -f temp_docker_module.pp ]]; then
                semodule -i temp_docker_module.pp && \
                    print_success "Temporary SELinux module installed (temp_docker_module)" || \
                    print_warning "Failed to install SELinux module"
            else
                print_warning "No SELinux module generated (no denials found)"
            fi
        else
            print_status "Skipping SELinux policy generation (APPLY_SELINUX_FIXES=false)"
        fi

        setenforce 1
        print_success "SELinux restored to Enforcing."
    fi
}


load_kernel_modules() {
    print_status "Loading required kernel modules..."

	# nf_tables preferred for RHEL8+ networking
	# ip_tables included for backward compatibility with legacy tools
    modprobe overlay || print_warning "Failed to load overlay"
    modprobe br_netfilter || print_warning "Failed to load br_netfilter"
    modprobe nf_tables || print_warning "Failed to load nf_tables"
	modprobe ip_tables || print_warning "ip_tables module missing or already loaded"


    cat > /etc/modules-load.d/docker-rootless.conf <<EOF
overlay
br_netfilter
nf_tables
ip_tables
EOF

# RHEL8 / AlmaLinux: ensure ip_tables module is loaded for rootless Docker
if [[ "$OS" =~ rhel|centos|alma|rocky|fedora ]]; then
    print_status "Loading ip_tables kernel module for rootless Docker..."
    modprobe ip_tables || print_warning "ip_tables module already loaded or not available"
fi

    print_success "Kernel modules loaded"
}

remove_existing_docker() {
    print_status "Stopping and disabling rootful Docker services..."
    systemctl stop docker.service docker.socket 2>/dev/null || true
    systemctl disable docker.service docker.socket 2>/dev/null || true
	systemctl mask docker.service docker.socket 2>/dev/null || true

    if command -v snap &> /dev/null && snap list | grep -q docker 2>/dev/null; then
        print_warning "Removing snap Docker..."
        snap remove docker || true
    fi
    rm -rf /var/run/docker.sock /var/run/docker/ || true
}

install_dependencies() {
    print_status "Installing required packages..."
    case $PACKAGE_MANAGER in
        apt-get)
            $PACKAGE_MANAGER update
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras uidmap dbus-user-session
            ;;
        dnf|yum)
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras shadow-utils fuse-overlayfs
            ;;
    esac
}

verify_user() {
    print_status "Verifying user: $DOCKER_USER"
    if ! id "$DOCKER_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$DOCKER_USER"
        print_success "User $DOCKER_USER created"
    fi
    [[ "$ADD_TO_DOCKER_GROUP" == "true" ]] && usermod -aG docker "$DOCKER_USER" 2>/dev/null || true
    usermod -aG systemd-journal "$DOCKER_USER" 2>/dev/null || true

    loginctl enable-linger "$DOCKER_USER"
    
    # Configure subuid/subgid
    if ! grep -q "^$DOCKER_USER:" /etc/subuid; then
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$DOCKER_USER"
    fi
}

verify_binaries() {
    print_status "Verifying required binaries..."
    command -v dockerd-rootless-setuptool.sh >/dev/null || { print_error "dockerd-rootless-setuptool.sh not found"; exit 1; }
}

setup_apparmor_profile() {
    if ! grep -qiE "ubuntu|debian" /etc/os-release 2>/dev/null || ! command -v apparmor_parser &>/dev/null; then
        return 0
    fi

    print_status "Setting up AppArmor profile for rootlesskit..."
    local user_home
    user_home=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
    local profile_name
    profile_name=$(echo "${user_home}/bin/rootlesskit" | sed -e s@^/@@ -e s@/@.@g)
    
    run_as_user "$DOCKER_USER" <<EOF
set -eux
cat <<APPARMOR_EOF > ~/${profile_name}
abi <abi/4.0>,
include <tunables/global>
"${user_home}/bin/rootlesskit" flags=(unconfined) {
  userns,
  include if exists <local/${profile_name}>
}
APPARMOR_EOF
EOF

    if [[ -f "${user_home}/${profile_name}" ]]; then
        mv "${user_home}/${profile_name}" "/etc/apparmor.d/${profile_name}"
        apparmor_parser -r "/etc/apparmor.d/${profile_name}" 2>/dev/null || true
        print_success "AppArmor profile configured"
    fi
}

configure_sysctls() {
    if ! grep -qiE "rhel|alma|centos|rocky|fedora" /etc/os-release 2>/dev/null; then return 0; fi

    print_status "Configuring kernel parameters for rootless Docker..."

    if grep -q "^user\.max_user_namespaces\s*=\s*0" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^\(user\.max_user_namespaces\s*=\s*0\)$/# DISABLED for rootless Docker: \1/' /etc/sysctl.conf
    fi

    cat > /etc/sysctl.d/99-rootless-docker.conf <<EOF
user.max_user_namespaces = 28633
EOF

    if [[ "$ENABLE_IP_FORWARD" == "true" ]]; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-rootless-docker.conf
    fi

    # Debian/Ubuntu userns clone check (optional)
    if sysctl -n kernel.unprivileged_userns_clone &>/dev/null; then
        echo "kernel.unprivileged_userns_clone=1" >> /etc/sysctl.d/99-rootless-docker.conf
    fi

    # Only present on Debian/Ubuntu kernels, not RHEL/Alma
    if sysctl -n kernel.unprivileged_userns_clone &>/dev/null; then
        echo "kernel.unprivileged_userns_clone=1" >> /etc/sysctl.d/99-rootless-docker.conf
    fi

    sysctl --system > /dev/null 2>&1
}

remove_docker_config() {
    if [ -f /etc/docker/daemon.json ]; then
        mv /etc/docker/daemon.json /etc/docker/daemon.json.back
    fi
}

setup_rootless_docker() {
    print_status "Setting up rootless Docker for $DOCKER_USER..."
    
    if [[ -n "$CUSTOM_DATA_ROOT" ]]; then
        mkdir -p "$CUSTOM_DATA_ROOT"
        chown "$DOCKER_USER:$DOCKER_USER" "$CUSTOM_DATA_ROOT"
    fi

    local LOG_DRIVER LOG_OPTS
    if [[ "$USE_REMOTE_LOGGING" == "true" ]]; then
        LOG_DRIVER="syslog"
        LOG_OPTS="\"syslog-address\": \"$REMOTE_SYSLOG_ADDRESS\""
    else
        LOG_DRIVER="local"
        LOG_OPTS="\"max-size\": \"256m\", \"max-file\": \"3\""
    fi
    
    if [[ -z "$STORAGE_DRIVER" ]]; then
        if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
            STORAGE_DRIVER="fuse-overlayfs"
        else
            STORAGE_DRIVER="overlay2"
        fi
    fi

    local OPTIONAL_JSON=""
    [[ -n "$CUSTOM_DATA_ROOT" ]] && OPTIONAL_JSON+=$',\n  "data-root": "'"$CUSTOM_DATA_ROOT"'"'
    [[ "$DISABLE_ICC" == "true" ]] && OPTIONAL_JSON+=$',\n  "icc": false'

    local DAEMON_JSON
    DAEMON_JSON=$(cat <<JSONEOF
{
  "no-new-privileges": true,
  "userland-proxy": false,
  "storage-driver": "$STORAGE_DRIVER",
  "log-driver": "$LOG_DRIVER",
  "log-opts": { $LOG_OPTS }$OPTIONAL_JSON
}
JSONEOF
)

    run_as_user "$DOCKER_USER" <<EOF
set -eux
dockerd-rootless-setuptool.sh uninstall -f || true
rm -rf ~/.local/share/docker ~/.config/docker || true

dockerd-rootless-setuptool.sh install

mkdir -p ~/.config/docker
cat > ~/.config/docker/daemon.json <<'JSON'
${DAEMON_JSON}
JSON

systemctl --user daemon-reload
systemctl --user enable docker
systemctl --user restart docker

docker context use rootless 2>/dev/null || true

if ! grep -q "XDG_RUNTIME_DIR" ~/.bash_profile; then
cat >> ~/.bash_profile <<'BASHRC_EOF'

# --- Rootless Docker Environment Variables ---
if [[ -z "\$XDG_RUNTIME_DIR" ]]; then
    export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=\${XDG_RUNTIME_DIR}/bus"
fi
BASHRC_EOF
fi
EOF
}


validate_setup() {
    print_status "Validating rootless Docker setup..."
    run_as_user "$DOCKER_USER" <<'EOF'
for i in {1..15}; do
    if docker info &>/dev/null; then break; fi
    sleep 2
done

if docker info 2>/dev/null | grep -q "rootless"; then
    echo "Docker is running in rootless mode."
    docker info | grep -E "Context:|Storage Driver:|Cgroup Driver:|Root Dir:"
else
    echo "Docker is NOT running properly in rootless mode."
    systemctl --user status docker --no-pager
    exit 1
fi
EOF
}

main() {
    print_status "Starting rootless Docker setup..."
    detect_os
    handle_selinux_start
    load_kernel_modules
    remove_existing_docker
    install_dependencies
    verify_user
    verify_binaries
    setup_apparmor_profile
    configure_sysctls
    remove_docker_config
    setup_rootless_docker
    validate_setup
    handle_selinux_end
    print_success "Setup complete! Access the user cleanly with: sudo su - $DOCKER_USER"
}

main "$@"
