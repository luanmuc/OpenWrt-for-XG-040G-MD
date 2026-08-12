#!/usr/bin/env python3
"""
Fix the 310-10 patch file: convert from new multi-PCS API to old single-PCS callback API.

This script modifies the 310-10 patch file directly so that when applied,
the resulting code uses the old single-PCS API compatible with kernel 6.12.
"""

import re
import sys

def fix_310_10_patch(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original = content

    # Step 1: Replace #include <linux/pcs/pcs.h> with nothing (remove it)
    # In the patch, it looks like: +#include <linux/pcs/pcs.h>
    content = re.sub(r'\+#include <linux/pcs/pcs\.h>\n', '', content)
    print("Step 1: Removed #include <linux/pcs/pcs.h> from patch")

    # Step 2: Remove airoha_fill_available_pcs function from the patch
    # The function in the patch looks like:
    # +static int airoha_fill_available_pcs(struct phylink_config *config,
    # +				     struct phylink_pcs **available_pcs,
    # +				     unsigned int num_possible_pcs)
    # +{
    # +	struct device *dev = config->dev;
    # +
    # +	return fwnode_phylink_pcs_parse(dev_fwnode(dev), available_pcs,
    # +					&num_possible_pcs);
    # +}
    # +
    func_pattern = r'\+static int airoha_fill_available_pcs\([^)]+\)\s*\+\{[^}]*\+\}\n\+\n'
    content, count = re.subn(func_pattern, '', content, flags=re.DOTALL)
    if count > 0:
        print(f"Step 2: Removed airoha_fill_available_pcs() from patch ({count} occurrence(s))")
    else:
        print("Step 2: airoha_fill_available_pcs() not found in patch (may have different format)")
        # Try more flexible pattern - find the function and remove it
        lines = content.split('\n')
        new_lines = []
        skip = False
        brace_count = 0
        for i, line in enumerate(lines):
            if '+static int airoha_fill_available_pcs' in line:
                skip = True
                brace_count = 0
                continue
            if skip:
                if '{' in line:
                    brace_count += line.count('{')
                if '}' in line:
                    brace_count -= line.count('}')
                    if brace_count <= 0:
                        # Skip this line too (the closing brace)
                        # Also skip the next empty line if there is one
                        skip = False
                        continue
                continue
            new_lines.append(line)
        content = '\n'.join(new_lines)
        print("Step 2: Removed airoha_fill_available_pcs() (flexible line-by-line mode)")

    # Step 3: Add airoha_phylink_pcs_create function before airoha_setup_phylink
    # We need to add it in the patch, before the airoha_setup_phylink function
    pcs_create_func = '''+static struct phylink_pcs *airoha_phylink_pcs_create(struct phylink_config *config,
+\t\t\t\t\t     phy_interface_t iface)
+{
+\treturn airoha_pcs_create(config->dev);
+}
+
'''

    # Find the line with airoha_setup_phylink function definition in the patch
    insert_pos = content.find('+static int airoha_setup_phylink')
    if insert_pos != -1:
        # Check if we already added it
        if 'airoha_phylink_pcs_create' not in content[:insert_pos]:
            content = content[:insert_pos] + pcs_create_func + content[insert_pos:]
            print("Step 3: Added airoha_phylink_pcs_create() to patch")
        else:
            print("Step 3: airoha_phylink_pcs_create() already exists, skipping")
    else:
        print("Step 3: ERROR: Could not find airoha_setup_phylink in patch")
        return False

    # Step 4: Remove fwnode_phylink_pcs_parse call from airoha_setup_phylink
    # In the patch, it looks like:
    # +		err = fwnode_phylink_pcs_parse(dev_fwnode(config->dev), NULL,
    # +					       &dev->phylink_config.num_available_pcs);
    # +		if (err)
    # +			return err;
    old_parse_pattern = r'\+\s*err = fwnode_phylink_pcs_parse\([^)]+\);\s*\n\+\s*if \(err\)\s*\n\+\s*return err;\s*\n'
    content, count = re.subn(old_parse_pattern, '', content, flags=re.DOTALL)
    if count > 0:
        print(f"Step 4a: Removed fwnode_phylink_pcs_parse() call from patch ({count} occurrence(s))")
    else:
        print("Step 4a: fwnode_phylink_pcs_parse() not found (may have different format)")
        # Try line by line
        lines = content.split('\n')
        new_lines = []
        skip_next = 0
        for i, line in enumerate(lines):
            if skip_next > 0:
                skip_next -= 1
                continue
            if 'fwnode_phylink_pcs_parse' in line and line.startswith('+'):
                # Skip this line and the next few (if (err) return err;)
                skip_next = 3  # skip the call line + if line + return line
                continue
            new_lines.append(line)
        content = '\n'.join(new_lines)
        print("Step 4a: Removed fwnode_phylink_pcs_parse() (line-by-line mode)")

    # Step 4b: Remove config->fill_available_pcs assignment
    content, count = re.subn(r'\+\s*config->fill_available_pcs = airoha_fill_available_pcs;\s*\n', '', content)
    if count > 0:
        print(f"Step 4b: Removed config->fill_available_pcs from patch ({count} occurrence(s))")
    else:
        print("Step 4b: config->fill_available_pcs not found")

    # Step 4c: Remove phy_interface_copy call
    old_phy_copy_pattern = r'\+\s*phy_interface_copy\(config->pcs_interfaces,\s*\n\+\s*config->supported_interfaces\);\s*\n'
    content, count = re.subn(old_phy_copy_pattern, '', content, flags=re.DOTALL)
    if count > 0:
        print(f"Step 4c: Removed phy_interface_copy() from patch ({count} occurrence(s))")
    else:
        print("Step 4c: phy_interface_copy() not found (may have different format)")
        # Try line by line
        lines = content.split('\n')
        new_lines = []
        skip_next = 0
        for i, line in enumerate(lines):
            if skip_next > 0:
                skip_next -= 1
                continue
            if 'phy_interface_copy' in line and line.startswith('+'):
                skip_next = 1  # skip this line and the next
                continue
            new_lines.append(line)
        content = '\n'.join(new_lines)
        print("Step 4c: Removed phy_interface_copy() (line-by-line mode)")

    # Step 4d: Add pcs_create and pcs_destroy callbacks
    # Add after mac_capabilities line
    # Find: config->mac_capabilities = MAC_ASYM_PAUSE | ...
    # Add after it: config->pcs_create = ... and config->pcs_destroy = ...
    mac_cap_pattern = r'(\+\t\tconfig->mac_capabilities = MAC_ASYM_PAUSE[^;]+;)'
    replacement = r'\1\n+\n+\t\tconfig->pcs_create = airoha_phylink_pcs_create;\n+\t\tconfig->pcs_destroy = airoha_pcs_destroy;'
    content, count = re.subn(mac_cap_pattern, replacement, content)
    if count > 0:
        print(f"Step 4d: Added pcs_create/pcs_destroy callbacks to patch ({count} occurrence(s))")
    else:
        print("Step 4d: Could not find mac_capabilities line, trying alternative")
        # Try to find the first __set_bit after mac_capabilities
        alt_pattern = r'(\+\t\t__set_bit\(PHY_INTERFACE_MODE_SGMII,)'
        replacement = r'+\t\tconfig->pcs_create = airoha_phylink_pcs_create;\n+\t\tconfig->pcs_destroy = airoha_pcs_destroy;\n\1'
        content, count = re.subn(alt_pattern, replacement, content)
        if count > 0:
            print(f"Step 4d: Added callbacks before __set_bit (alternative) ({count} occurrence(s))")
        else:
            print("Step 4d: ERROR: Could not find position to add callbacks")
            return False

    # Write back
    with open(filepath, 'w') as f:
        f.write(content)

    # Verify changes
    if content != original:
        print("\n✅ 310-10 patch fix applied successfully!")
        print(f"   File: {filepath}")
        print(f"   Original size: {len(original)} bytes")
        print(f"   New size: {len(content)} bytes")
        return True
    else:
        print("\n⚠️  No changes were made to the patch")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: fix-310-10-patch.py <path-to-310-10-patch-file>")
        sys.exit(1)

    filepath = sys.argv[1]
    success = fix_310_10_patch(filepath)
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()
