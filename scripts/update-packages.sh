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

	# 克隆 GitHub 仓库（带重试机制，最多重试2次，共3次尝试）
	local MAX_RETRIES=2
	local RETRY_COUNT=0
	local CLONE_SUCCESS=0

	while [ $RETRY_COUNT -le $MAX_RETRIES ]; do
		if [ $RETRY_COUNT -gt 0 ]; then
			echo "Retry $RETRY_COUNT/$MAX_RETRIES: cloning $PKG_REPO..."
			sleep 2
		fi
		git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"
		if [ -d "$REPO_NAME" ]; then
			CLONE_SUCCESS=1
			break
		fi
		RETRY_COUNT=$((RETRY_COUNT + 1))
	done

	if [ $CLONE_SUCCESS -eq 0 ]; then
		echo "ERROR: Failed to clone $PKG_REPO after $((MAX_RETRIES + 1)) attempts"
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

# 修复 nftables-nojson 递归依赖警告
# 移除 nftables-nojson 对 nftables 的反向依赖，打破 Kconfig 循环依赖
echo " "
echo "=========================================="
echo "Fixing nftables-nojson recursive dependency..."
echo "=========================================="

NFTABLES_MAKEFILE="../feeds/packages/net/nftables/Makefile"
if [ -f "$NFTABLES_MAKEFILE" ]; then
	# 移除 nftables-nojson 定义块中的 DEPENDS 行里的 +nftables 反向依赖
	sed -i '/define Package\/nftables-nojson/,/endef/{s/DEPENDS:=\(.*\)+nftables\(.*\)/DEPENDS:=\1\2/}' "$NFTABLES_MAKEFILE"
	# 清理可能产生的空 DEPENDS 行或多余空格
	sed -i '/define Package\/nftables-nojson/,/endef/{/^[[:space:]]*DEPENDS:[[:space:]]*$/d}' "$NFTABLES_MAKEFILE"
	echo "Fixed: removed reverse dependency from nftables-nojson to nftables"
else
	echo "WARNING: nftables Makefile not found, skip fix"
fi

# HomeProxy (代理软件) - 使用第5个参数指定额外要删除的包名
UPDATE_PACKAGE "homeproxy" "immortalwrt/homeproxy" "master"

# Docker管理插件
UPDATE_PACKAGE "luci-app-dockerman" "immortalwrt/luci" "master" "pkg"

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

echo " "
echo "=========================================="
echo "Package updates completed!"
echo "=========================================="
