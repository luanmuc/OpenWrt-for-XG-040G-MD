#!/bin/bash
# 安装和更新第三方软件包
# 此脚本在 openwrt/package/ 目录下运行，在 feeds install 之后执行

UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}

	echo " "
	echo "=========================================="
	echo "Processing: $PKG_NAME from $PKG_REPO"
	echo "=========================================="

	# 删除 feeds 中可能存在的同名软件包
	for NAME in "${PKG_LIST[@]}"; do
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"

	if [ ! -d "$REPO_NAME" ]; then
		echo "ERROR: Failed to clone $PKG_REPO"
		return 1
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		# 从大杂烩仓库中提取特定包
		find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf ./$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		# 重命名仓库
		mv -f $REPO_NAME $PKG_NAME
	fi

	echo "Done: $PKG_NAME"
}

echo "Starting package updates..."

# 首先删除 feeds 中的 sing-box 相关包，避免与第三方包冲突
echo " "
echo "=========================================="
echo "Removing conflicting sing-box packages from feeds..."
echo "=========================================="
rm -rf ../feeds/packages/net/sing-box
rm -rf ../package/feeds/packages/sing-box
echo "Done removing sing-box from feeds"

# Argon 主题
UPDATE_PACKAGE "luci-theme-argon" "jerrykuku/luci-theme-argon" "master"
UPDATE_PACKAGE "luci-app-argon-config" "jerrykuku/luci-app-argon-config" "master"

# 修改 LuCI 默认主题为 Argon（保留 bootstrap 包可共存）
echo " "
echo "=========================================="
echo "Setting default LuCI theme to argon..."
echo "=========================================="
COLLECTION_MAKEFILES=$(find ../feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$COLLECTION_MAKEFILES" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-argon/g" $COLLECTION_MAKEFILES
	echo "Done setting default LuCI theme to argon"
else
	echo "WARNING: No LuCI collection Makefile found, skip theme default patch"
fi

# PassWall2 (代理软件 - 轻量版)
echo " "
echo "=========================================="
echo "Installing PassWall2..."
echo "=========================================="
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

# OpenWrt 25.12 下 shadowsocksr-libev 的上游归档内容已变化，旧 MIRROR_HASH 失效。
# 先禁用 SSR 组件，避免 passwall2 选择该包导致下载阶段直接失败。
PASSWALL2_MAKEFILE="./luci-app-passwall2/Makefile"
if [ -f "$PASSWALL2_MAKEFILE" ]; then
	echo "Patching PassWall2 defaults to disable broken ShadowsocksR components..."
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Client/,/default y/s/default y/default n/' "$PASSWALL2_MAKEFILE"
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR_Libev_Server/,/default n/s/default n/default n/' "$PASSWALL2_MAKEFILE"
fi

# PassWall 依赖包（PassWall 和 PassWall2 共享依赖）
echo " "
echo "=========================================="
echo "Installing PassWall dependencies..."
echo "=========================================="
git clone --depth=1 --single-branch --branch main "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
if [ -d "openwrt-passwall-packages" ]; then
	for pkg in openwrt-passwall-packages/*/; do
		pkg_name=$(basename "$pkg")
		if [ -d "$pkg" ] && [ -f "$pkg/Makefile" ]; then
			echo "Installing: $pkg_name"
			rm -rf "./$pkg_name"
			cp -rf "$pkg" ./
		fi
	done
	rm -rf openwrt-passwall-packages
fi

echo " "
echo "=========================================="
echo "Package updates completed!"
echo "=========================================="
