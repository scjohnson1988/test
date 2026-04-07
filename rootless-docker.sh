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

# RHEL NON-COMPLIANT CIS CONFIGS #
# When running the bench as rootless, there is a warning of: [WARN] Some tests might require root to run -- this applies to the below out.
# You can review the logic used in the bench by reviewing the bash scripts: https://github.com/docker/docker-bench-security/blob/master/tests/2_docker_daemon_configuration.sh

#2.2 (CIS) - For RHEL8, there is no traditional docker0 bridge exists in rootless mode and icc only applies to bridge networking in rootful Docker.  There is a variable below (DISABLE_ICC) to control it. This works fine on Ubuntu.
#2.9 (user namespace support/userns-remap): This config is a false-positive for RHEL rootless, as subuids and subgids are already used and rootless docker is already using usier namespaces.  This is only necessary when running rootful docker.
#2.12 (authorization-plugins) - This requires 
#2.14 (no-new-privileges) - This appears to be a false-positive issue.  If you run 'docker info | grep no-new-privileges', it shows that it's enabled.  
#2.16 (userland-proxy) - As Rootless Docker is using RootlessKit networking (slirp4netns/pasta) on RHEL, userland-proxy is irrelevant.  The script should set this value in the daemon.json config, which is the only available evidence that can be offered (grep userland-proxy /home/a2i2.docker/.config/docker/daemon.json)



set -euo pipefail
trap 'echo "[ERROR] Line $LINENO failed"' ERR

# ---- CONFIGURATION ----
DOCKER_USER="a2i2.docker"
CUSTOM_DATA_ROOT="/docker/docker"  # Set to absolute path if desired, leave empty for default
ADD_TO_DOCKER_GROUP=true
USE_REMOTE_LOGGING=true
REMOTE_SYSLOG_ADDRESS="udp://10.74.4.3:514"
STORAGE_DRIVER="" # Auto-detects based on OS/SELinux
DISABLE_ICC=false # APPLIES TO RHEL-ONLY: Set to true to enforce CIS benchmark in daemon.json (may require troubleshooting on RHEL8 and likely will not work)
APPLY_SELINUX_FIXES=true # Automatically create a temporary SELinux module for any denials that may have been detected 
ENABLE_IP_FORWARD=true # Generally a good idea to leave this enabled, as it is no longer a STIG to have it on 
FIX_SYSCTL_NAMESPACES=true  # Set to true to comment out user.max_user_namespaces=0 in /etc/sysctl.d/99-sysctl.conf/.  This may remove OS compliance, but will not work with rootless docker otherwise.
SETUP_AUDIT_RULES=false # This is experimental.  If enabled, it will perform a best-effort attempt to create root and rootless audit rules.  If not enabled, this will be required by the user running the script.
SETUP_NVIDIA_RUNTIME=false  # Set to true to configure NVIDIA container runtime.  This is necessary to allow rootless docker containers to access the GPU.
NVIDIA_SET_DEFAULT_RUNTIME=true  # Set to true to also set nvidia as default-runtime.  This is ignored if SETUP_NVIDIA_RUNTIME is not set to true.

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
    modprobe ip_tables || print_warning "Failed to load ip_tables"
	
    # Ensure the bridge-nf path actually exists before we try to sysctl it
    # This triggers the kernel to "realize" the bridge parameters are there
    ls /proc/sys/net/bridge/bridge-nf-call-iptables >/dev/null 2>&1 || true

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
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras uidmap dbus-user-session jq
            ;;
        dnf|yum)
            $PACKAGE_MANAGER install -y docker-ce docker-ce-rootless-extras shadow-utils fuse-overlayfs jq
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

verify_network_driver() {
    # pasta is preferred on RHEL9+ and modern Ubuntu; slirp4netns is the fallback for RHEL8
    if command -v pasta &>/dev/null; then
        print_success "pasta (passt) network driver found — preferred driver available"
        return 0
    fi

    print_status "pasta not found — checking slirp4netns..."

    local SLIRP4NETNS_BIN
    if SLIRP4NETNS_BIN="$(command -v slirp4netns)"; then
        local SLIRP_VERSION
        SLIRP_VERSION=$(slirp4netns --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

        if [[ -z "$SLIRP_VERSION" ]]; then
            print_warning "Could not determine slirp4netns version — proceeding anyway"
            return 0
        fi

        if [[ $(printf '0.4.0\n%s' "$SLIRP_VERSION" | sort -V | head -n1) == "0.4.0" ]]; then
            print_success "slirp4netns $SLIRP_VERSION found (>= 0.4.0 required)"
        else
            print_error "slirp4netns $SLIRP_VERSION is too old (< 0.4.0 required)"
            exit 1
        fi
    else
        print_error "Neither pasta nor slirp4netns found — rootless Docker networking will fail"
        exit 1
    fi
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

# Used to ensure 'user.max_user_namespaces=0 ' is not set
fix_sysctl_namespace_conf() {
    [[ "$FIX_SYSCTL_NAMESPACES" != "true" ]] && return 0

    local SYSCTL_CONF="/etc/sysctl.d/99-sysctl.conf"
    [[ ! -f "$SYSCTL_CONF" ]] && return 0

    if grep -qE '^\s*user\.max_user_namespaces\s*=\s*0' "$SYSCTL_CONF"; then
        print_status "Commenting out user.max_user_namespaces=0 in $SYSCTL_CONF (CCE-82211-4 override)..."
        sed -i 's|^\(\s*user\.max_user_namespaces\s*=\s*0\)|# Commented out for rootless Docker (was: \1)|' "$SYSCTL_CONF"
        print_success "Commented out restrictive namespace setting in $SYSCTL_CONF"
    else
        print_status "No restrictive user.max_user_namespaces=0 found in $SYSCTL_CONF — skipping"
    fi
}

configure_sysctls() {
    print_status "Configuring kernel parameters for rootless Docker..."

    # ---- Applies to ALL distros ----
    local SYSCTL_FILE="/etc/sysctl.d/99-rootless-docker.conf"

    {
        echo "user.max_user_namespaces = 28633"

        # Enable user namespaces where supported (Ubuntu/Debian)
        if sysctl -n kernel.unprivileged_userns_clone &>/dev/null; then
            echo "kernel.unprivileged_userns_clone = 1"
        fi

        [[ "$ENABLE_IP_FORWARD" == "true" ]] && echo "net.ipv4.ip_forward = 1"
    } > "$SYSCTL_FILE"

    # ---- RHEL-specific adjustments ----
    if grep -qiE "rhel|alma|centos|rocky|fedora" /etc/os-release 2>/dev/null; then

        # Comment out restrictive setting if present
        if grep -q "^user\.max_user_namespaces\s*=\s*0" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^\(user\.max_user_namespaces\s*=\s*0\)$/# DISABLED for rootless Docker: \1/' /etc/sysctl.conf
        fi

        # CIS-related bridge settings (harmless even if unused in rootless)
        echo "net.bridge.bridge-nf-call-iptables = 1" >> "$SYSCTL_FILE"
        echo "net.bridge.bridge-nf-call-ip6tables = 1" >> "$SYSCTL_FILE"

        modprobe br_netfilter || true
    fi

    # Apply immediately
    sysctl -w user.max_user_namespaces=28633
    sysctl --system > /dev/null 2>&1

    print_success "Kernel parameters configured"
}


remove_docker_config() {
    if [ -f /etc/docker/daemon.json ]; then
        mv /etc/docker/daemon.json /etc/docker/daemon.json.back
    fi
}

# This creates daemon.json for RHEL
build_daemon_json_rhel() {
    local storage_driver="$1"
    local log_driver="$2"
    local syslog_address="$3"
    local data_root="$4"

    local base
    base=$(jq -n \
        --arg sd "$storage_driver" \
        --arg ld "$log_driver" \
        --arg dr "$data_root" \
        '{
            "no-new-privileges": true,
            "experimental": false,
            "userland-proxy": false,
            "storage-driver": $sd,
            "live-restore": true,
            "log-level": "info",
            "log-driver": $ld,
            "data-root": $dr,
            "default-ulimits": {
                "nofile": {
                    "Name": "nofile",
                    "Soft": 64000,
                    "Hard": 64000
                }
            }
        }')

    if [[ "$log_driver" == "syslog" ]]; then
        base=$(echo "$base" | jq --arg addr "$syslog_address" \
            '. + {"log-opts": {"syslog-address": $addr}}')
    else
        base=$(echo "$base" | jq \
            '. + {"log-opts": {"max-size": "256m", "max-file": "3"}}')
    fi

    [[ "$DISABLE_ICC" == "true" ]] && base=$(echo "$base" | jq '. + {"icc": false}')

    echo "$base"
}

# This creates daemon.json for Ubuntu hosts
build_daemon_json_ubuntu() {
    local storage_driver="$1"
    local log_driver="$2"
    local syslog_address="$3"
    local data_root="$4"

    local base
    base=$(jq -n \
        --arg sd "$storage_driver" \
        --arg ld "$log_driver" \
        --arg dr "$data_root" \
        '{
            "experimental": false,
            "no-new-privileges": true,
            "userland-proxy": false,
            "selinux-enabled": false,
            "icc": false,
            "storage-driver": $sd,
            "live-restore": true,
            "cgroup-parent": "",
            "log-level": "info",
            "log-driver": $ld,
            "data-root": $dr,
            "insecure-registries": [],
            "default-ulimits": {
                "nofile": {
                    "Name": "nofile",
                    "Soft": 64000,
                    "Hard": 64000
                }
            }
        }')

    if [[ "$log_driver" == "syslog" ]]; then
        base=$(echo "$base" | jq --arg addr "$syslog_address" \
            '. + {"log-opts": {"syslog-address": $addr}}')
    else
        base=$(echo "$base" | jq \
            '. + {"log-opts": {"max-size": "256m", "max-file": "3"}}')
    fi

    [[ "$DISABLE_ICC" == "true" ]] && base=$(echo "$base" | jq '. + {"icc": false}')

    echo "$base"
}

setup_rootless_docker() {
    print_status "Setting up rootless Docker for $DOCKER_USER..."

    local user_home
    user_home=$(getent passwd "$DOCKER_USER" | cut -d: -f6)

    if [[ -n "$CUSTOM_DATA_ROOT" ]]; then
        mkdir -p "$CUSTOM_DATA_ROOT"
        chown "$DOCKER_USER:$DOCKER_USER" "$CUSTOM_DATA_ROOT"
    fi

    local LOG_DRIVER
    LOG_DRIVER=$([[ "$USE_REMOTE_LOGGING" == "true" ]] && echo "syslog" || echo "local")

    if [[ -z "$STORAGE_DRIVER" ]]; then
        if [[ "$OS" =~ ubuntu|debian ]]; then
            STORAGE_DRIVER="overlay2"
        elif command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
            STORAGE_DRIVER="fuse-overlayfs"
        else
            STORAGE_DRIVER="overlay2"
        fi
    fi

    local DAEMON_JSON
    if [[ "$OS" =~ ubuntu|debian ]]; then
        DAEMON_JSON=$(build_daemon_json_ubuntu \
            "$STORAGE_DRIVER" "$LOG_DRIVER" "$REMOTE_SYSLOG_ADDRESS" "$CUSTOM_DATA_ROOT")
    else
        DAEMON_JSON=$(build_daemon_json_rhel \
            "$STORAGE_DRIVER" "$LOG_DRIVER" "$REMOTE_SYSLOG_ADDRESS" "$CUSTOM_DATA_ROOT")
    fi

    # Wipe old data before writing fresh config
    rm -rf "${user_home}/.local/share/docker" "${user_home}/.config/docker" || true

    # Write daemon.json as root
    mkdir -p "${user_home}/.config/docker"
    echo "$DAEMON_JSON" > "${user_home}/.config/docker/daemon.json"
    chown -R "$DOCKER_USER:$DOCKER_USER" "${user_home}/.config/docker"

    # Write systemd override as root BEFORE switching users
    local override_dir="${user_home}/.config/systemd/user/docker.service.d"
    mkdir -p "$override_dir"

    if [[ "$OS" =~ rhel|alma|centos|rocky|fedora ]]; then
        cat > "${override_dir}/override.conf" <<CONF_EOF
[Service]
Environment=DOCKER_IGNORE_BR_NETFILTER_ERROR=1
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns
CONF_EOF
    else
        cat > "${override_dir}/override.conf" <<CONF_EOF
[Service]
Environment=DOCKER_IGNORE_BR_NETFILTER_ERROR=1
CONF_EOF
    fi

    chown -R "$DOCKER_USER:$DOCKER_USER" "${user_home}/.config/systemd"

    # Now switch to user context
    run_as_user "$DOCKER_USER" <<'EOF'
set -eux
dockerd-rootless-setuptool.sh uninstall -f || true
dockerd-rootless-setuptool.sh install

systemctl --user reset-failed docker.service 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable docker
systemctl --user restart docker
docker context use rootless 2>/dev/null || true

if ! grep -q "XDG_RUNTIME_DIR" ~/.bash_profile; then
cat >> ~/.bash_profile <<BASHRC_EOF
# --- Rootless Docker Environment Variables ---
if [[ -z "\$XDG_RUNTIME_DIR" ]]; then
    export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=\${XDG_RUNTIME_DIR}/bus"
fi
BASHRC_EOF
fi
EOF
}


setup_nvidia_runtime() {
    [[ "$SETUP_NVIDIA_RUNTIME" != "true" ]] && return 0

    print_status "Configuring NVIDIA container runtime..."

    if ! command -v nvidia-ctk &>/dev/null; then
        print_error "nvidia-ctk not found — install the NVIDIA Container Toolkit first:"
        print_error "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
        return 1
    fi

    local user_home
    user_home=$(getent passwd "$DOCKER_USER" | cut -d: -f6)
    local daemon_json="${user_home}/.config/docker/daemon.json"

    if [[ ! -f "$daemon_json" ]]; then
        print_error "daemon.json not found at $daemon_json — run setup_rootless_docker first"
        return 1
    fi

    local nvidia_ctk_args=(
        runtime configure
        --runtime=docker
        --config="$daemon_json"
    )
    [[ "$NVIDIA_SET_DEFAULT_RUNTIME" == "true" ]] && nvidia_ctk_args+=(--set-as-default)

    sudo -H -u "$DOCKER_USER" nvidia-ctk "${nvidia_ctk_args[@]}"

    # Safe ownership fix — nvidia-ctk may write as a different uid depending on sudo context
    chown "$DOCKER_USER:$DOCKER_USER" "$daemon_json" 2>/dev/null || true

    print_success "NVIDIA runtime configured in $daemon_json"
    print_status "Restarting Docker for $DOCKER_USER to apply changes..."

    run_as_user "$DOCKER_USER" <<'EOF'
systemctl --user restart docker
EOF

    print_success "Docker restarted with NVIDIA runtime support"

    # Must run after restart per NVIDIA rootless docs — modifies /etc/nvidia-container-runtime/config.toml
    nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place

    print_status "Validating NVIDIA runtime registration..."

    run_as_user "$DOCKER_USER" <<'EOF'
if docker info 2>/dev/null | grep -i "nvidia" | grep -i "runtime"; then
    echo "[✓] NVIDIA runtime confirmed in docker info"
else
    echo "[!] NVIDIA runtime not detected — check daemon.json and restart manually if needed"
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

# NOTE: This is not very well tested.  It must be opted into.
setup_docker_audit_rules() {
    print_status "Configuring auditd rules for Docker (rootful + rootless)..."

    local RULE_FILE="/etc/audit/rules.d/docker-audit.rules"
    local TMP_FILE
    TMP_FILE=$(mktemp)

    add_rule() {
        local path="$1"
        local perms="${2:-wa}"
        local key="${3:-docker}"
        [[ -z "$path" ]] && return

        if ! grep -Fxq -- "-w $path -p $perms -k $key" "$TMP_FILE" 2>/dev/null; then
            echo "-w $path -p $perms -k $key" >> "$TMP_FILE"
        fi
    }

    # === Core binaries ===
    add_rule /usr/bin/docker
    add_rule /usr/bin/dockerd
    add_rule /usr/bin/dockerd-rootless.sh
    add_rule /usr/bin/containerd
    add_rule /usr/bin/containerd-shim
    add_rule /usr/bin/containerd-shim-runc-v1
    add_rule /usr/bin/containerd-shim-runc-v2
    add_rule /usr/bin/runc

    # === Rootful paths ===
    add_rule /var/lib/docker
    add_rule /etc/docker
    add_rule /etc/docker/daemon.json
    add_rule /etc/containerd/config.toml
    add_rule /etc/default/docker
    add_rule /etc/sysconfig/docker
    add_rule /usr/lib/systemd/system/docker.service
    add_rule /usr/lib/systemd/system/docker.socket
    add_rule /run/containerd
    add_rule /run/containerd/containerd.sock
    add_rule /var/run/docker.sock

    # === Rootless paths ===
    local user_home
    user_home=$(getent passwd "${DOCKER_USER}" | cut -d: -f6)
    if [[ -n "$user_home" ]]; then
	    #add_rule "$user_home/.local/share/docker"  # Enable if needed; may generate excess noise.
		#add_rule "/run/user/$uid/docker.sock" wa docker  # useful for partiy to rootful docker, but will be very noisy and not overly helpful.
        add_rule "$user_home/.config/docker"
        add_rule "$user_home/.config/systemd/user/docker.service"
        add_rule "$user_home/.config/systemd/user/docker.service.d"
    fi

    local uid
    uid=$(id -u "$DOCKER_USER" 2>/dev/null || true)
    if [[ -n "$uid" ]]; then
        add_rule "/run/user/$uid/docker.sock"
    fi

    # === Install ===
    sort -u "$TMP_FILE" > "$RULE_FILE"
    chmod 640 "$RULE_FILE"
    chown root:root "$RULE_FILE"
    rm -f "$TMP_FILE"

    if command -v augenrules >/dev/null; then
        augenrules --load
    else
        print_warning "augenrules not found — loading rules temporarily with auditctl"
        auditctl -R "$RULE_FILE"
    fi

    print_success "Auditd rules for Docker configured successfully"
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
    verify_network_driver
    setup_apparmor_profile
    fix_sysctl_namespace_conf
    configure_sysctls
    remove_docker_config
    setup_rootless_docker
	setup_nvidia_runtime 
    validate_setup

    if [[ "$SETUP_AUDIT_RULES" == "true" ]]; then
        setup_docker_audit_rules
    else
        print_warning "Skipping audit rule configuration (SETUP_AUDIT_RULES=false)"
    fi

    handle_selinux_end
    print_success "Setup complete! Access the user cleanly with: sudo su - $DOCKER_USER"
}


main "$@"
