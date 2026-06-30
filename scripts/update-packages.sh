#!/bin/bash
# Install and update third-party packages
# This script runs in openwrt/package/ directory, executed after feeds install

set -euo pipefail

# ==========================================
# Package Version Configuration
# ==========================================
# Uncomment and set specific commit/revision to lock package versions
# Example: PKG_<NAME>_REVISION="abc123def"

# PKG_ARGON_THEME_REVISION=""
# PKG_ARGON_CONFIG_REVISION=""
# PKG_PASSWALL2_REVISION=""
# PKG_PASSWALL_PACKAGES_REVISION=""

# ==========================================
# Helper Functions
# ==========================================

log_info() {
    echo "  [INFO] $*"
}

log_warn() {
    echo "  [WARN] $*"
}

log_error() {
    echo "  [ERROR] $*" >&2
}

log_section() {
    echo ""
    echo "=========================================="
    echo "$*"
    echo "=========================================="
}

# Git clone with retry mechanism
# Usage: git_clone_with_retry <clone_args...>
git_clone_with_retry() {
    local max_retries=3
    local retry_delay=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        log_info "Git clone attempt $attempt/$max_retries"
        if git clone "$@"; then
            log_info "Git clone succeeded"
            return 0
        fi

        if [ $attempt -lt $max_retries ]; then
            log_warn "Git clone failed, retrying in ${retry_delay}s..."
            sleep $retry_delay
        fi

        attempt=$((attempt + 1))
    done

    log_error "Git clone failed after $max_retries attempts"
    return 1
}

# ==========================================
# Package Update Function
# ==========================================

UPDATE_PACKAGE() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"
    local PKG_EXTRA_NAMES="${5:-}"

    # Build package list array
    local -a PKG_LIST=("$PKG_NAME")
    if [ -n "$PKG_EXTRA_NAMES" ]; then
        # shellcheck disable=SC2206
        PKG_LIST+=($PKG_EXTRA_NAMES)
    fi

    local REPO_NAME="${PKG_REPO#*/}"

    log_section "Processing: $PKG_NAME from $PKG_REPO"

    # Remove conflicting packages from feeds
    for NAME in "${PKG_LIST[@]}"; do
        log_info "Searching for existing: $NAME"
        local FOUND_DIRS
        FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null || true)

        if [ -n "$FOUND_DIRS" ]; then
            while read -r DIR; do
                if [ -n "$DIR" ]; then
                    rm -rf "$DIR"
                    log_info "Removed: $DIR"
                fi
            done <<< "$FOUND_DIRS"
        else
            log_info "No existing directory found: $NAME"
        fi
    done

    # Clone GitHub repository
    log_info "Cloning repository: $PKG_REPO (branch: $PKG_BRANCH)"

    local CLONE_CMD=("git" "clone" "--depth=1" "--single-branch" "--branch" "$PKG_BRANCH")

    # Check if specific revision is locked
    local REVISION_VAR="PKG_$(echo "$PKG_NAME" | tr '[:lower:]-' '[:upper:]_')_REVISION"
    local REVISION_VAL="${!REVISION_VAR:-}"

    if [ -n "$REVISION_VAL" ]; then
        log_info "Locked to revision: $REVISION_VAL"
        CLONE_CMD+=("--no-single-branch")
    fi

    CLONE_CMD+=("https://github.com/$PKG_REPO.git")

    if ! git_clone_with_retry "${CLONE_CMD[@]:2}"; then
        log_error "Failed to clone $PKG_REPO after retries"
        return 1
    fi

    # Checkout specific revision if locked
    if [ -n "$REVISION_VAL" ] && [ -d "$REPO_NAME" ]; then
        (
            cd "$REPO_NAME"
            git checkout "$REVISION_VAL"
        )
        log_info "Checked out revision: $REVISION_VAL"
    fi

    if [ ! -d "$REPO_NAME" ]; then
        log_error "Clone succeeded but directory not found: $REPO_NAME"
        return 1
    fi

    # Process cloned repository
    case "$PKG_SPECIAL" in
        pkg)
            # Extract specific package from monorepo
            log_info "Extracting package from monorepo..."
            find "./$REPO_NAME"/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
            rm -rf "./$REPO_NAME/"
            ;;
        name)
            # Rename repository
            log_info "Renaming to: $PKG_NAME"
            mv -f "$REPO_NAME" "$PKG_NAME"
            ;;
        *)
            # Keep as-is
            log_info "Keeping original directory name: $REPO_NAME"
            ;;
    esac

    log_info "Done: $PKG_NAME"
}

# ==========================================
# Main Script
# ==========================================

echo "Starting package updates..."

# First remove sing-box related packages from feeds to avoid conflicts
log_section "Removing conflicting sing-box packages from feeds"

rm -rf ../feeds/packages/net/sing-box 2>/dev/null || true
rm -rf ../package/feeds/packages/sing-box 2>/dev/null || true

log_info "Done removing sing-box from feeds"

# ==========================================
# Argon Theme
# ==========================================

log_section "Installing Argon Theme"

UPDATE_PACKAGE "luci-theme-argon" "jerrykuku/luci-theme-argon" "master"
UPDATE_PACKAGE "luci-app-argon-config" "jerrykuku/luci-app-argon-config" "master"

# Set default LuCI theme to Argon (keep bootstrap package for coexistence)
log_section "Setting default LuCI theme to argon"

COLLECTION_MAKEFILES=$(find ../feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null || true)

if [ -n "$COLLECTION_MAKEFILES" ]; then
    # shellcheck disable=SC2086
    sed -i "s/luci-theme-bootstrap/luci-theme-argon/g" $COLLECTION_MAKEFILES
    log_info "Default LuCI theme set to argon"
else
    log_warn "No LuCI collection Makefile found, skipping theme default patch"
fi

# ==========================================
# PassWall2 (Proxy Software - Lightweight)
# ==========================================

log_section "Installing PassWall2"

UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

# On OpenWrt 25.12, upstream archives for shadowsocksr-libev have changed,
# old MIRROR_HASH is invalid. Disable SSR component first to avoid download failures.
PASSWALL2_MAKEFILE="./luci-app-passwall2/Makefile"

if [ -f "$PASSWALL2_MAKEFILE" ]; then
    log_info "Patching PassWall2 defaults to disable broken ShadowsocksR components..."
    sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Client/,/default y/s/default y/default n/' "$PASSWALL2_MAKEFILE"
    sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Server/,/default n/s/default n/default n/' "$PASSWALL2_MAKEFILE"

    # Verify the patch was applied successfully
    if grep -q "INCLUDE_ShadowsocksR_Libev_Client" "$PASSWALL2_MAKEFILE"; then
        if grep -A5 "INCLUDE_ShadowsocksR_Libev_Client" "$PASSWALL2_MAKEFILE" | grep -q "default y"; then
            log_warn "ShadowsocksR Client patch may not have been applied correctly"
        else
            log_info "ShadowsocksR Client successfully disabled"
        fi
    fi

    log_info "PassWall2 SSR components disabled"
else
    log_warn "PassWall2 Makefile not found, skipping SSR patch"
fi

# ==========================================
# PassWall Dependencies (shared by PassWall and PassWall2)
# ==========================================

log_section "Installing PassWall dependencies"

if ! git_clone_with_retry --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"; then
    log_error "Failed to clone passwall-packages repository after retries"
    exit 1
fi

if [ -d "openwrt-passwall-packages" ]; then
    for pkg in openwrt-passwall-packages/*/; do
        pkg_name=$(basename "$pkg")
        if [ -d "$pkg" ] && [ -f "$pkg/Makefile" ]; then
            log_info "Installing: $pkg_name"
            rm -rf "./$pkg_name"
            cp -rf "$pkg" ./
        fi
    done
    rm -rf openwrt-passwall-packages
    log_info "PassWall dependencies installed"
else
    log_error "passwall-packages directory not found after clone"
    exit 1
fi

# ==========================================
# dllkids Software Feed (Runtime)
# ==========================================
log_section "Setting up dllkids software feed (runtime)"

# Create files directory structure (will be copied to firmware rootfs)
mkdir -p ../files/etc/apk/keys
mkdir -p ../files/etc/uci-defaults

# Write public key for apk signature verification
cat > ../files/etc/apk/keys/dllkids-feed.pub.pem << 'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwTKjlQgSu4H+uwQt5PlHsFsxMehB
JVXQOIgHzb6TOgvxY6nhY+e9SDWguPidN9V1o/6INgP/KT+yNvZo6ArTtg==
-----END PUBLIC KEY-----
EOF

# Write uci-defaults script to add feed on first boot
cat > ../files/etc/uci-defaults/99-add-dllkids-feed << 'EOF'
#!/bin/sh
# Add dllkids OpenWrt feed (runtime software source)
# This script runs once on first boot and then auto-deletes

# Get OpenWrt version from os-release
OWRT_VERSION=""
if [ -f /etc/os-release ]; then
    OWRT_VERSION=$(grep -m1 'VERSION_ID' /etc/os-release | cut -d'"' -f2)
fi

# Only add feed for 25.12 (dllkids only supports 24.10 and 25.12)
if [ "$OWRT_VERSION" != "25.12" ]; then
    exit 0
fi

# Detect architecture - prefer DISTRIB_ARCH from openwrt_release
# Reason: apk --print-arch only returns CPU family (e.g. aarch64)
# but feed directories use full arch with subtarget (e.g. aarch64_cortex-a53)
ARCH=""
if [ -f /etc/openwrt_release ]; then
    ARCH=$(sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release | head -n1)
fi
if [ -z "$ARCH" ]; then
    ARCH=$(apk --print-arch 2>/dev/null)
fi
if [ -z "$ARCH" ]; then
    exit 0
fi

# Feed URL - point directly to packages.adb (apk-tools v3 standard format)
# Using directory format causes 404 warnings from v2 APKINDEX.tar.gz fallback
FEED_URL="https://down.dllkids.xyz/openwrt-feed/25.12/${ARCH}/packages.adb"

# Use repositories.d for cleaner separation (doesn't modify main repositories file)
FEEDS_FILE="/etc/apk/repositories.d/customfeeds.list"

# Check if already added (avoid duplicates)
if grep -q "dllkids.xyz" "$FEEDS_FILE" 2>/dev/null; then
    exit 0
fi

# Create directory and add feed
mkdir -p "$(dirname "$FEEDS_FILE")"
echo "${FEED_URL}" >> "$FEEDS_FILE"

exit 0
EOF

chmod +x ../files/etc/uci-defaults/99-add-dllkids-feed

log_info "dllkids software feed configured (runtime)"
log_info "  - Public key: /etc/apk/keys/dllkids-feed.pub.pem"
log_info "  - Auto-add script: /etc/uci-defaults/99-add-dllkids-feed"
log_info "  - Feed activates automatically on first boot"

# ==========================================
# MAC Address Fix for XG-040G-MD
# ==========================================
log_section "Setting up MAC address fix for XG-040G-MD"

# Ensure uci-defaults directory exists
mkdir -p ../files/etc/uci-defaults

# Write uci-defaults script to fix MAC address on first boot
cat > ../files/etc/uci-defaults/99-fix-mac-address << 'FIXMAC_EOF'
#!/bin/sh
# Fix MAC address randomization on Bell XG-040G-MD
# This script runs once on first boot and then auto-deletes
# SAFETY: This script only reads factory data, never writes to U-Boot or hardware

. /lib/functions.sh
. /lib/functions/system.sh

log() {
    logger -t "mac-fix" "$*"
    echo "[mac-fix] $*"
}

# Only run on XG-040G-MD
BOARD=$(board_name)
if [ "$BOARD" != "bell,xg-040g-md" ]; then
    exit 0
fi

log "Starting MAC address fix for $BOARD"

# ==========================================
# Helper: Check if MAC address is valid
# ==========================================
is_valid_mac() {
    local mac="$1"
    # Must be 6 colon-separated hex bytes
    if ! echo "$mac" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; then
        return 1
    fi
    # Must not be all zeros
    if [ "$mac" = "00:00:00:00:00:00" ]; then
        return 1
    fi
    # Must not be broadcast/multicast (LSB of first byte is 0 for unicast)
    local first_byte
    first_byte=$(echo "$mac" | cut -d: -f1)
    if [ $((0x$first_byte & 1)) -eq 1 ]; then
        return 1
    fi
    return 0
}

# ==========================================
# Helper: Generate stable random MAC from machine-id
# ==========================================
generate_stable_mac() {
    local seed=""
    
    # Try to get unique identifier from machine-id
    if [ -f /etc/machine-id ]; then
        seed=$(cat /etc/machine-id)
    fi
    
    # Fallback: use kernel command line or other sources
    if [ -z "$seed" ]; then
        seed=$(cat /proc/cmdline | md5sum | cut -d' ' -f1)
    fi
    
    if [ -z "$seed" ]; then
        # Last resort: truly random (will be different each boot, but saved to config)
        seed=$(head -c 16 /dev/urandom | hexdump -n 16 -e '4/4 "%08x"' | head -n1)
    fi
    
    # Generate MAC from seed (use Airoha OUI prefix: 00:0C:43 or similar)
    # We'll use a locally administered address (bit 1 of first byte = 1)
    # to avoid conflicts with real OUI
    local mac
    mac=$(echo "$seed" | md5sum | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5:\6/')
    
    # Set locally administered bit and clear multicast bit
    # First byte: xx | 0x02 (locally admin) & 0xFE (not multicast)
    local first_byte
    first_byte=$(echo "$mac" | cut -d: -f1)
    first_byte=$(printf '%02x' $(( (0x$first_byte | 0x02) & 0xfe )))
    mac="${first_byte}:$(echo "$mac" | cut -d: -f2-)"
    
    echo "$mac"
}

# ==========================================
# Step 1: Try to read factory MAC from various sources
# ==========================================
WAN_MAC=""
LAN_MAC=""

# Method 1: Try fw_printenv (if available and working)
if command -v fw_printenv >/dev/null 2>&1; then
    log "Trying fw_printenv..."
    WAN_MAC=$(fw_printenv -n ethaddr 2>/dev/null)
    WAN_MAC=$(macaddr_canonicalize "$WAN_MAC")
    if [ -n "$WAN_MAC" ] && is_valid_mac "$WAN_MAC"; then
        log "Found MAC via fw_printenv: $WAN_MAC"
    else
        WAN_MAC=""
    fi
fi

# Method 2: Try reading directly from "env" MTD partition
if [ -z "$WAN_MAC" ]; then
    log "Trying direct MTD read from env partition..."
    ENV_IDX=$(find_mtd_index env 2>/dev/null || true)
    if [ -n "$ENV_IDX" ] && [ -b "/dev/mtdblock$ENV_IDX" ]; then
        WAN_MAC=$(strings "/dev/mtdblock$ENV_IDX" 2>/dev/null | sed -n 's/^ethaddr=//p' | head -n1)
        WAN_MAC=$(macaddr_canonicalize "$WAN_MAC")
        if [ -n "$WAN_MAC" ] && is_valid_mac "$WAN_MAC"; then
            log "Found MAC via MTD env partition: $WAN_MAC"
        else
            WAN_MAC=""
        fi
    fi
fi

# Method 3: Try reading from "factory" partition (common on many devices)
if [ -z "$WAN_MAC" ]; then
    log "Trying factory partition..."
    FACTORY_IDX=$(find_mtd_index factory 2>/dev/null || true)
    if [ -n "$FACTORY_IDX" ] && [ -b "/dev/mtdblock$FACTORY_IDX" ]; then
        # Try to find MAC in factory data (common patterns)
        WAN_MAC=$(hexdump -C "/dev/mtdblock$FACTORY_IDX" 2>/dev/null | grep -oE '([0-9a-fA-F]{2} ){5}[0-9a-fA-F]{2}' | head -n1 | tr ' ' ':')
        WAN_MAC=$(macaddr_canonicalize "$WAN_MAC")
        if [ -n "$WAN_MAC" ] && is_valid_mac "$WAN_MAC"; then
            log "Found MAC via factory partition: $WAN_MAC"
        else
            WAN_MAC=""
        fi
    fi
fi

# ==========================================
# Step 2: If no factory MAC found, generate stable one
# ==========================================
if [ -z "$WAN_MAC" ] || ! is_valid_mac "$WAN_MAC"; then
    log "No factory MAC found, generating stable MAC..."
    WAN_MAC=$(generate_stable_mac)
    log "Generated stable WAN MAC: $WAN_MAC"
fi

# ==========================================
# Step 3: Derive LAN MAC (WAN + 1)
# ==========================================
if is_valid_mac "$WAN_MAC"; then
    LAN_MAC=$(macaddr_add "$WAN_MAC" 1)
    log "Derived LAN MAC: $LAN_MAC"
fi

# ==========================================
# Step 4: Check if current config already has valid MACs
# ==========================================
CURRENT_WAN_MAC=""
CURRENT_LAN_MAC=""

# Get current WAN MAC from config
if uci get network.wan.macaddr >/dev/null 2>&1; then
    CURRENT_WAN_MAC=$(uci get network.wan.macaddr)
fi

# Get current LAN bridge MAC
if uci get network.@device[0].macaddr >/dev/null 2>&1; then
    CURRENT_LAN_MAC=$(uci get network.@device[0].macaddr 2>/dev/null || true)
fi

# Check if we need to update
NEED_UPDATE=false

if [ -n "$WAN_MAC" ] && is_valid_mac "$WAN_MAC"; then
    if [ "$CURRENT_WAN_MAC" != "$WAN_MAC" ]; then
        NEED_UPDATE=true
    fi
fi

if [ -n "$LAN_MAC" ] && is_valid_mac "$LAN_MAC"; then
    if [ "$CURRENT_LAN_MAC" != "$LAN_MAC" ]; then
        NEED_UPDATE=true
    fi
fi

if [ "$NEED_UPDATE" = false ]; then
    log "MAC addresses already configured correctly, no changes needed"
    exit 0
fi

# ==========================================
# Step 5: Apply MAC addresses to network config
# ==========================================
log "Applying MAC addresses to network configuration..."

# Set WAN MAC
if [ -n "$WAN_MAC" ] && is_valid_mac "$WAN_MAC"; then
    uci set network.wan.macaddr="$WAN_MAC"
    log "  WAN MAC set to: $WAN_MAC"
fi

# Set LAN MAC on the bridge device
# Find the br-lan device section
if [ -n "$LAN_MAC" ] && is_valid_mac "$LAN_MAC"; then
    # Try to find existing device section for br-lan
    DEVICE_IDX=""
    for i in $(seq 0 9); do
        DEV_NAME=$(uci get network.@device[$i].name 2>/dev/null || true)
        if [ "$DEV_NAME" = "br-lan" ]; then
            DEVICE_IDX=$i
            break
        fi
    done
    
    if [ -n "$DEVICE_IDX" ]; then
        uci set network.@device[$DEVICE_IDX].macaddr="$LAN_MAC"
        log "  LAN MAC set on br-lan device[$DEVICE_IDX]: $LAN_MAC"
    else
        # Create new device section for br-lan
        uci add network device
        uci set network.@device[-1].name="br-lan"
        uci set network.@device[-1].macaddr="$LAN_MAC"
        log "  Created br-lan device section with MAC: $LAN_MAC"
    fi
fi

# Commit changes
uci commit network
log "MAC address configuration saved"

log "MAC address fix completed successfully"

exit 0
FIXMAC_EOF

chmod +x ../files/etc/uci-defaults/99-fix-mac-address
log_info "MAC address fix configured"
log_info "  - Script: /etc/uci-defaults/99-fix-mac-address"
log_info "  - Runs once on first boot, then auto-deletes"
log_info "  - SAFETY: Only reads factory data, never modifies U-Boot or hardware"
log_info "  - Features: Multiple MAC detection methods + stable fallback"

# ==========================================
# Summary
# ==========================================

log_section "Package updates completed!"

echo ""
echo "Summary:"
echo "  - Argon theme and config installed"
echo "  - Default LuCI theme set to Argon"
echo "  - PassWall2 installed (SSR disabled)"
echo "  - PassWall dependencies installed"
echo "  - dllkids software feed preset (runtime)"
echo "  - MAC address fix for XG-040G-MD"
echo ""
