#!/bin/bash
# =============================================================================
# 脚本名称：patch-cpufreq-dts.sh
# 功能说明：给 Airoha AN7581 设备树（DTS）补 cpufreq 节点，让 airoha-cpufreq
#           驱动正常 probe，修复 CPU 频率显示 NA 的问题
# 实现方式：纯 awk 实现，不依赖其他工具
# 幂等设计：已包含 cpufreq 节点则跳过，不会重复添加
# 参考实现：基于 OpenWrt 主线 an7581.dtsi 的 cpufreq DTS 配置
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 第一步：查找 an7581.dtsi 文件
# ---------------------------------------------------------------------------
DTSI_FILE=""

# 优先在标准路径查找
if [ -f "target/linux/airoha/dts/an7581.dtsi" ]; then
    DTSI_FILE="target/linux/airoha/dts/an7581.dtsi"
elif [ $# -ge 1 ] && [ -f "$1" ]; then
    # 支持通过参数指定文件路径
    DTSI_FILE="$1"
else
    # 递归查找（兜底方案）
    DTSI_FILE=$(find . -name "an7581.dtsi" -path "*/airoha/*" 2>/dev/null | head -1)
fi

if [ -z "$DTSI_FILE" ] || [ ! -f "$DTSI_FILE" ]; then
    echo "[ERROR] 未找到 an7581.dtsi 文件"
    echo "[INFO] 请在 OpenWrt 源码根目录下运行本脚本，或通过参数指定 dtsi 文件路径"
    exit 1
fi

echo "[INFO] 目标文件: $DTSI_FILE"

# ---------------------------------------------------------------------------
# 第二步：使用 awk 处理 DTS 文件
# 功能：
#   1. 检查是否已有 cpufreq 节点（幂等判断）
#   2. 在 cpus 节点之后插入 cpufreq 节点、cpu_opp_table、cpu_smcc_opp_table
#   3. 给每个 cpu 节点补充 operating-points-v2 / clocks / power-domains 属性
# ---------------------------------------------------------------------------

awk '
# =========================================================================
# AWK 脚本主体
# =========================================================================

BEGIN {
    # ---- 状态变量初始化 ----
    line_num = 0           # 当前行号
    has_cpufreq = 0        # 是否已存在 cpufreq 节点
    has_cpu_opp = 0        # 是否已存在 cpu_opp_table
    has_smcc_opp = 0       # 是否已存在 cpu_smcc_opp_table

    # ---- cpus 节点跟踪 ----
    in_cpus = 0            # 是否在 cpus 节点内
    cpus_brace = 0         # cpus 节点的花括号深度
    cpus_end_line = 0      # cpus 节点结束的行号

    # ---- 单个 cpu 节点跟踪 ----
    in_cpu = 0             # 是否在某个 cpu 节点内
    cpu_brace = 0          # 当前 cpu 节点的花括号深度
    cpu_has_opp = 0        # 当前 cpu 是否已有 operating-points-v2
    cpu_has_clk = 0        # 当前 cpu 是否已有 clocks
    cpu_has_pd = 0         # 当前 cpu 是否已有 power-domains
    cpu_insert_line = 0    # cpu 节点内插入新属性的位置（enable-method之后）
    cpu_start_line = 0     # 当前 cpu 节点起始行号

    # ---- 输出缓冲区 ----
    # 我们需要先扫描整个文件（确定插入位置和是否需要补丁），
    # 然后再输出。因此先把所有行存到数组里。
}

# =========================================================================
# 主循环：逐行读取并分析
# =========================================================================
{
    line_num++
    lines[line_num] = $0

    # ---------------------------------------------------------------------
    # 幂等检查：检测是否已有 cpufreq 相关节点
    # ---------------------------------------------------------------------
    if ($0 ~ /cpufreq:[[:space:]]*cpufreq/ || $0 ~ /airoha,en7581-cpufreq/) {
        has_cpufreq = 1
    }
    if ($0 ~ /cpu_opp_table:/) {
        has_cpu_opp = 1
    }
    if ($0 ~ /cpu_smcc_opp_table:/) {
        has_smcc_opp = 1
    }

    # ---------------------------------------------------------------------
    # 跟踪 cpus 节点（找到其结束位置，用于插入 cpufreq 节点）
    # ---------------------------------------------------------------------
    if (!in_cpus && $0 ~ /^[[:space:]]*cpus[[:space:]]*\{/) {
        in_cpus = 1
        cpus_brace = 1
    } else if (in_cpus) {
        # 统计当前行的花括号增减
        tmp = $0
        open_cnt = 0
        close_cnt = 0
        while (index(tmp, "{")) {
            open_cnt++
            tmp = substr(tmp, index(tmp, "{") + 1)
        }
        tmp = $0
        while (index(tmp, "}")) {
            close_cnt++
            tmp = substr(tmp, index(tmp, "}") + 1)
        }
        cpus_brace += open_cnt - close_cnt

        if (cpus_brace == 0) {
            in_cpus = 0
            cpus_end_line = line_num
        }
    }

    # ---------------------------------------------------------------------
    # 跟踪单个 cpu 节点（检查是否需要补充属性）
    # ---------------------------------------------------------------------
    # 检测 cpu 节点开始：匹配 cpu@N { 或 cpuN: cpu@N {
    if (!in_cpu && $0 ~ /cpu[0-9]+:[[:space:]]*cpu@[0-9]+[[:space:]]*\{/) {
        in_cpu = 1
        cpu_brace = 1
        cpu_has_opp = 0
        cpu_has_clk = 0
        cpu_has_pd = 0
        cpu_insert_line = 0
        cpu_start_line = line_num
    } else if (in_cpu) {
        # 统计花括号深度
        tmp = $0
        open_cnt = 0
        close_cnt = 0
        while (index(tmp, "{")) {
            open_cnt++
            tmp = substr(tmp, index(tmp, "{") + 1)
        }
        tmp = $0
        while (index(tmp, "}")) {
            close_cnt++
            tmp = substr(tmp, index(tmp, "}") + 1)
        }
        cpu_brace += open_cnt - close_cnt

        # 检查 cpu 节点内是否已有相关属性
        if ($0 ~ /operating-points-v2/) {
            cpu_has_opp = 1
        }
        if ($0 ~ /^[[:space:]]*clocks[[:space:]]*=[[:space:]]*<&cpufreq>/) {
            cpu_has_clk = 1
        }
        if ($0 ~ /power-domains[[:space:]]*=[[:space:]]*<&cpufreq>/) {
            cpu_has_pd = 1
        }

        # 记录插入位置：在 enable-method = "psci"; 之后
        if ($0 ~ /enable-method[[:space:]]*=[[:space:]]*"psci"/ && cpu_insert_line == 0) {
            cpu_insert_line = line_num
        }

        # cpu 节点结束
        if (cpu_brace == 0) {
            in_cpu = 0
            # 如果这个 cpu 缺少属性，且找到了插入位置
            if ((!cpu_has_opp || !cpu_has_clk || !cpu_has_pd) && cpu_insert_line > 0) {
                # 记录需要修改的 cpu 节点信息
                cpu_mod_count++
                cpu_mod_lines[cpu_mod_count] = cpu_insert_line
                cpu_mod_opp[cpu_mod_count] = !cpu_has_opp
                cpu_mod_clk[cpu_mod_count] = !cpu_has_clk
                cpu_mod_pd[cpu_mod_count] = !cpu_has_pd
            }
        }
    }
}

# =========================================================================
# END 块：生成最终输出
# =========================================================================
END {
    # ---- 幂等判断：如果所有节点都已存在，且没有 cpu 需要修改，直接输出原文件 ----
    if (has_cpufreq && has_cpu_opp && has_smcc_opp && cpu_mod_count == 0) {
        print "[INFO] cpufreq DTS 节点已完整存在，跳过补丁（幂等）" > "/dev/stderr"
        for (i = 1; i <= line_num; i++) {
            print lines[i]
        }
        exit 0
    }

    if (cpus_end_line == 0) {
        print "[ERROR] 未找到 cpus 节点，无法插入 cpufreq 节点" > "/dev/stderr"
        exit 1
    }

    # ---- 统计补丁内容 ----
    patch_count = 0
    if (!has_cpufreq) patch_count++
    if (!has_cpu_opp) patch_count++
    if (!has_smcc_opp) patch_count++
    if (cpu_mod_count > 0) patch_count++

    print "[INFO] 开始应用 cpufreq DTS 补丁（共 " patch_count " 项）..." > "/dev/stderr"
    if (!has_cpufreq)    print "[INFO]   - 添加 cpufreq 节点" > "/dev/stderr"
    if (!has_cpu_opp)    print "[INFO]   - 添加 cpu_opp_table 节点" > "/dev/stderr"
    if (!has_smcc_opp)   print "[INFO]   - 添加 cpu_smcc_opp_table 节点" > "/dev/stderr"
    if (cpu_mod_count > 0) print "[INFO]   - 补充 " cpu_mod_count " 个 CPU 节点的 cpufreq 属性" > "/dev/stderr"

    # ---- 构建 cpufreq 节点内容 ----
    cpufreq_node = ""
    if (!has_cpufreq) {
        cpufreq_node = cpufreq_node "\tcpufreq: cpufreq {\n"
        cpufreq_node = cpufreq_node "\t\tcompatible = \"airoha,en7581-cpufreq\";\n"
        cpufreq_node = cpufreq_node "\t\toperating-points-v2 = <&cpu_smcc_opp_table>;\n"
        cpufreq_node = cpufreq_node "\t\t#power-domain-cells = <0>;\n"
        cpufreq_node = cpufreq_node "\t\t#clock-cells = <0>;\n"
        cpufreq_node = cpufreq_node "\t};\n"
    }

    # ---- 构建 cpu_opp_table 节点内容 ----
    cpu_opp_node = ""
    if (!has_cpu_opp) {
        cpu_opp_node = cpu_opp_node "\tcpu_opp_table: opp-table {\n"
        cpu_opp_node = cpu_opp_node "\t\tcompatible = \"operating-points-v2\";\n"
        cpu_opp_node = cpu_opp_node "\t\topp-shared;\n"

        # 15 个 OPP 级别：500MHz ~ 1200MHz，每 50MHz 一级
        split("500000000,550000000,600000000,650000000,700000000,750000000,800000000,850000000,900000000,950000000,1000000000,1050000000,1100000000,1150000000,1200000000", freqs, ",")

        for (i = 1; i <= 15; i++) {
            idx = i - 1
            cpu_opp_node = cpu_opp_node "\t\topp-" freqs[i] " {\n"
            cpu_opp_node = cpu_opp_node "\t\t\topp-hz = /bits/ 64 <" freqs[i] ">;\n"
            cpu_opp_node = cpu_opp_node "\t\t\trequired-opps = <&smcc_opp" idx ">;\n"
            cpu_opp_node = cpu_opp_node "\t\t};\n"
        }
        cpu_opp_node = cpu_opp_node "\t};\n"
    }

    # ---- 构建 cpu_smcc_opp_table 节点内容 ----
    smcc_opp_node = ""
    if (!has_smcc_opp) {
        smcc_opp_node = smcc_opp_node "\tcpu_smcc_opp_table: opp-table-cpu-smcc {\n"
        smcc_opp_node = smcc_opp_node "\t\tcompatible = \"operating-points-v2\";\n"

        for (i = 0; i < 15; i++) {
            smcc_opp_node = smcc_opp_node "\t\tsmcc_opp" i ": opp" i " {\n"
            smcc_opp_node = smcc_opp_node "\t\t\topp-level = <" i ">;\n"
            smcc_opp_node = smcc_opp_node "\t\t};\n"
        }
        smcc_opp_node = smcc_opp_node "\t};\n"
    }

    # ---- 输出最终内容 ----
    # 建立 cpu 修改行号的快速查找表
    for (i = 1; i <= cpu_mod_count; i++) {
        cpu_mod_lookup[cpu_mod_lines[i]] = i
    }

    for (i = 1; i <= line_num; i++) {
        # 检查当前行是否是某个 cpu 节点的插入位置
        if (i in cpu_mod_lookup) {
            idx = cpu_mod_lookup[i]
            # 先输出原行（enable-method 行）
            print lines[i]
            # 然后插入缺失的属性
            indent = "\t\t\t"  # cpu 节点内用三级缩进
            if (cpu_mod_opp[idx]) {
                print indent "operating-points-v2 = <&cpu_opp_table>;"
            }
            if (cpu_mod_clk[idx]) {
                print indent "clocks = <&cpufreq>;"
                print indent "clock-names = \"cpu\";"
            }
            if (cpu_mod_pd[idx]) {
                print indent "power-domains = <&cpufreq>;"
                print indent "power-domain-names = \"perf\";"
            }
            continue
        }

        # 输出当前行
        print lines[i]

        # 在 cpus 节点结束后插入 cpufreq 相关节点
        if (i == cpus_end_line && (!has_cpufreq || !has_cpu_opp || !has_smcc_opp)) {
            print ""
            if (!has_cpufreq) {
                printf "%s", cpufreq_node
                print ""
            }
            if (!has_cpu_opp) {
                printf "%s", cpu_opp_node
                print ""
            }
            if (!has_smcc_opp) {
                printf "%s", smcc_opp_node
                print ""
            }
        }
    }

    print "[INFO] cpufreq DTS 补丁应用完成" > "/dev/stderr"
}
' "$DTSI_FILE" > "${DTSI_FILE}.tmp"

# ---------------------------------------------------------------------------
# 第三步：替换原文件
# ---------------------------------------------------------------------------
mv "${DTSI_FILE}.tmp" "$DTSI_FILE"

echo "[INFO] 脚本执行成功"
