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

    if ! "${CLONE_CMD[@]}"; then
        log_error "Failed to clone $PKG_REPO"
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
    log_info "PassWall2 SSR components disabled"
else
    log_warn "PassWall2 Makefile not found, skipping SSR patch"
fi

# ==========================================
# PassWall Dependencies (shared by PassWall and PassWall2)
# ==========================================

log_section "Installing PassWall dependencies"

if ! git clone --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"; then
    log_error "Failed to clone passwall-packages repository"
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
# Summary
# ==========================================

log_section "Package updates completed!"

echo ""
echo "Summary:"
echo "  - Argon theme and config installed"
echo "  - Default LuCI theme set to Argon"
echo "  - PassWall2 installed (SSR disabled)"
echo "  - PassWall dependencies installed"
echo ""
