#!/usr/bin/env python3
"""
Fix PCS API in airoha_eth.c: convert from new multi-PCS API to old single-PCS callback API.

This script fixes the pcs.h compilation error by:
1. Removing #include <linux/pcs/pcs.h>
2. Removing airoha_fill_available_pcs() function
3. Adding airoha_phylink_pcs_create() callback function
4. Modifying airoha_setup_phylink() to use old single-PCS API
"""

import re
import sys

def fix_airoha_eth(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original = content

    # Step 1: Remove #include <linux/pcs/pcs.h>
    content = re.sub(r'#include <linux/pcs/pcs\.h>\n', '', content)
    print("Step 1: Removed #include <linux/pcs/pcs.h>")

    # Step 2: Remove airoha_fill_available_pcs function
    # The function looks like:
    # static int airoha_fill_available_pcs(struct phylink_config *config,
    #                                      struct phylink_pcs **available_pcs,
    #                                      unsigned int num_possible_pcs)
    # {
    #     struct device *dev = config->dev;
    #
    #     return fwnode_phylink_pcs_parse(dev_fwnode(dev), available_pcs,
    #                                     &num_possible_pcs);
    # }
    func_pattern = r'static int airoha_fill_available_pcs\([^)]+\)\s*\{[^}]*\}\n\n'
    content, count = re.subn(func_pattern, '', content, flags=re.DOTALL)
    if count > 0:
        print(f"Step 2: Removed airoha_fill_available_pcs() function ({count} occurrence(s))")
    else:
        print("Step 2: airoha_fill_available_pcs() function not found (may have different format)")
        # Try a more flexible pattern
        func_start = content.find('airoha_fill_available_pcs')
        if func_start != -1:
            # Find the function start (look backwards for 'static')
            func_start = content.rfind('static int', 0, func_start)
            # Find the matching closing brace
            brace_count = 0
            i = content.find('{', func_start)
            while i < len(content):
                if content[i] == '{':
                    brace_count += 1
                elif content[i] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        # Remove from function start to closing brace + newline
                        end = i + 1
                        # Also remove trailing newlines
                        while end < len(content) and content[end] == '\n':
                            end += 1
                        content = content[:func_start] + content[end:]
                        print("Step 2: Removed airoha_fill_available_pcs() function (flexible match)")
                        break
                i += 1

    # Step 3: Add airoha_phylink_pcs_create function before airoha_setup_phylink
    pcs_create_func = '''static struct phylink_pcs *airoha_phylink_pcs_create(struct phylink_config *config,
                                                             phy_interface_t iface)
{
\treturn airoha_pcs_create(config->dev);
}

'''

    # Find where to insert: before airoha_setup_phylink function
    insert_pos = content.find('static int airoha_setup_phylink')
    if insert_pos != -1:
        # Check if we already added it
        if 'airoha_phylink_pcs_create' not in content[:insert_pos]:
            content = content[:insert_pos] + pcs_create_func + content[insert_pos:]
            print("Step 3: Added airoha_phylink_pcs_create() function")
        else:
            print("Step 3: airoha_phylink_pcs_create() already exists, skipping")
    else:
        print("Step 3: ERROR: Could not find airoha_setup_phylink function")
        return False

    # Step 4: Modify airoha_setup_phylink function
    # Find the function
    func_start = content.find('static int airoha_setup_phylink')
    if func_start == -1:
        print("Step 4: ERROR: Could not find airoha_setup_phylink function")
        return False

    # Find the function body
    brace_start = content.find('{', func_start)
    brace_count = 0
    func_end = brace_start
    while func_end < len(content):
        if content[func_end] == '{':
            brace_count += 1
        elif content[func_end] == '}':
            brace_count -= 1
            if brace_count == 0:
                break
        func_end += 1

    func_body = content[brace_start:func_end+1]

    # 4a: Remove fwnode_phylink_pcs_parse call and error handling
    # Pattern:
    # err = fwnode_phylink_pcs_parse(dev_fwnode(config->dev), NULL,
    #                                &dev->phylink_config.num_available_pcs);
    # if (err)
    #     return err;
    old_parse_pattern = r'\n\s*err = fwnode_phylink_pcs_parse\([^)]+\);\s*\n\s*if \(err\)\s*\n\s*return err;\s*\n'
    new_body, count = re.subn(old_parse_pattern, '\n', func_body, flags=re.DOTALL)
    if count > 0:
        print(f"Step 4a: Removed fwnode_phylink_pcs_parse() call ({count} occurrence(s))")
    else:
        print("Step 4a: fwnode_phylink_pcs_parse() not found (may have different format)")
        # Try simpler pattern
        new_body = re.sub(r'\n[^\n]*fwnode_phylink_pcs_parse[^\n]*\n', '\n', new_body)
        # Also remove the if (err) return err; that follows
        new_body = re.sub(r'\n\s*if \(err\)\s*\n\s*return err;\s*\n', '\n', new_body, count=1)
        print("Step 4a: Removed fwnode_phylink_pcs_parse() (simple match)")

    # 4b: Remove config->fill_available_pcs assignment
    new_body, count = re.subn(r'\n\s*config->fill_available_pcs = airoha_fill_available_pcs;\s*\n', '\n', new_body)
    if count > 0:
        print(f"Step 4b: Removed config->fill_available_pcs assignment ({count} occurrence(s))")
    else:
        print("Step 4b: config->fill_available_pcs not found")

    # 4c: Remove phy_interface_copy call
    new_body, count = re.subn(r'\n\s*phy_interface_copy\(config->pcs_interfaces,\s*\n\s*config->supported_interfaces\);\s*\n', '\n', new_body)
    if count > 0:
        print(f"Step 4c: Removed phy_interface_copy() call ({count} occurrence(s))")
    else:
        print("Step 4c: phy_interface_copy() not found (may have different format)")
        # Try simpler pattern
        new_body = re.sub(r'\n[^\n]*phy_interface_copy[^\n]*\n', '\n', new_body)
        print("Step 4c: Removed phy_interface_copy() (simple match)")

    # 4d: Add pcs_create and pcs_destroy callbacks
    # Add after the mac_capabilities line, or before the __set_bit calls
    # Find the position: after config->mac_capabilities = ... line
    insert_pattern = r'(config->mac_capabilities = MAC_ASYM_PAUSE[^;]+;)'
    replacement = r'\1\n\n\tconfig->pcs_create = airoha_phylink_pcs_create;\n\tconfig->pcs_destroy = airoha_pcs_destroy;'
    new_body, count = re.subn(insert_pattern, replacement, new_body)
    if count > 0:
        print(f"Step 4d: Added config->pcs_create and pcs_destroy callbacks ({count} occurrence(s))")
    else:
        print("Step 4d: Could not find mac_capabilities line, trying alternative position")
        # Try adding before the first __set_bit
        alt_pattern = r'(\n\t__set_bit\(PHY_INTERFACE_MODE_SGMII,)'
        replacement = r'\n\tconfig->pcs_create = airoha_phylink_pcs_create;\n\tconfig->pcs_destroy = airoha_pcs_destroy;\1'
        new_body, count = re.subn(alt_pattern, replacement, new_body)
        if count > 0:
            print(f"Step 4d: Added callbacks before __set_bit (alternative position) ({count} occurrence(s))")
        else:
            print("Step 4d: ERROR: Could not find position to add callbacks")
            return False

    # Replace the function body
    content = content[:brace_start] + new_body + content[func_end+1:]
    print("Step 4: Modified airoha_setup_phylink() function")

    # Write back
    with open(filepath, 'w') as f:
        f.write(content)

    # Verify changes
    if content != original:
        print("\n✅ PCS API fix applied successfully!")
        print(f"   File: {filepath}")
        print(f"   Original size: {len(original)} bytes")
        print(f"   New size: {len(content)} bytes")
        return True
    else:
        print("\n⚠️  No changes were made")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: fix-pcs-api.py <path-to-airoha_eth.c>")
        sys.exit(1)

    filepath = sys.argv[1]
    success = fix_airoha_eth(filepath)
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()
