#!/usr/bin/env python3
"""
waybar_manager.py: Robust scanner and non-destructive patcher for Waybar configs.
Supports JSON and JSONC (with comments, trailing commas).
Preserves existing comments, indentation, and formatting.
"""

import sys
import os
import re
import json

def strip_jsonc(text):
    """Strip // and /* */ comments and trailing commas for parsing."""
    def replacer(match):
        s = match.group(0)
        if s.startswith('/'):
            return " " * len(s)
        return s
    
    pattern = re.compile(
        r'//.*?$|/\*.*?\*/|\'(?:\\.|[^\\\'])*\'|"(?:\\.|[^\\"])*"',
        re.DOTALL | re.MULTILINE
    )
    no_comments = re.sub(pattern, replacer, text)
    no_trailing = re.sub(r',\s*([\]}])', r'\1', no_comments)
    return no_trailing

def parse_config(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        raw_text = f.read()
    
    clean_text = strip_jsonc(raw_text)
    try:
        data = json.loads(clean_text)
    except Exception as e:
        raise ValueError(f"Failed to parse {filepath}: {e}")
    
    return raw_text, data

def cmd_scan(config_path):
    if not os.path.isfile(config_path):
        print(json.dumps({"error": f"File not found: {config_path}"}))
        sys.exit(1)
        
    try:
        raw_text, data = parse_config(config_path)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
        
    is_array = isinstance(data, list)
    bars_list = data if is_array else [data]
    
    res_bars = []
    already_installed = False
    ym_modules = {"custom/mpris_heart", "custom/ym_mpris", "custom/ym_volume"}
    
    for idx, bar in enumerate(bars_list):
        output = bar.get("output", "all")
        if isinstance(output, list):
            output = ", ".join(output)
            
        m_left = bar.get("modules-left", [])
        m_center = bar.get("modules-center", [])
        m_right = bar.get("modules-right", [])
        
        all_mods = set(m_left + m_center + m_right)
        if ym_modules.intersection(all_mods):
            already_installed = True
            
        res_bars.append({
            "index": idx,
            "output": output,
            "modules-left": m_left,
            "modules-center": m_center,
            "modules-right": m_right
        })
        
    includes = []
    if is_array:
        for b in data:
            inc = b.get("include", [])
            if isinstance(inc, list): includes.extend(inc)
            elif isinstance(inc, str): includes.append(inc)
    else:
        inc = data.get("include", [])
        if isinstance(inc, list): includes.extend(inc)
        elif isinstance(inc, str): includes.append(inc)
        
    has_include = any("yamusic" in str(x) for x in includes)
    if has_include:
        already_installed = True
        
    result = {
        "is_array": is_array,
        "bar_count": len(res_bars),
        "bars": res_bars,
        "has_include": has_include,
        "already_installed": already_installed
    }
    
    print(json.dumps(result, indent=2, ensure_ascii=False))

def insert_include_in_bar(bar_text, include_path):
    if "yamusic-modules.json" in bar_text:
        return bar_text
        
    inc_match = re.search(r'("include"\s*:\s*\[)', bar_text)
    if inc_match:
        pos = inc_match.end()
        return bar_text[:pos] + f'\n        "{include_path}",' + bar_text[pos:]
    else:
        brace_pos = bar_text.find('{')
        if brace_pos != -1:
            snippet = f'\n    "include": ["{include_path}"],'
            return bar_text[:brace_pos+1] + snippet + bar_text[brace_pos+1:]
    return bar_text

def patch_section(bar_text, section, position, target_mod, mods_to_add):
    sec_regex = re.compile(rf'("{re.escape(section)}"\s*:\s*\[)(.*?)(\])', re.DOTALL)
    m = sec_regex.search(bar_text)
    if not m:
        brace_pos = bar_text.find('{')
        if brace_pos != -1:
            formatted_mods = ',\n        '.join(f'"{x}"' for x in mods_to_add)
            snippet = f'\n    "{section}": [\n        {formatted_mods}\n    ],'
            return bar_text[:brace_pos+1] + snippet + bar_text[brace_pos+1:]
        return bar_text

    start_header = m.group(1)
    inner = m.group(2)
    closing = m.group(3)
    
    mods_str = ',\n        '.join(f'"{x}"' for x in mods_to_add)
    
    if position == 'start':
        if inner.strip():
            new_inner = f'\n        {mods_str},\n' + inner.lstrip()
        else:
            new_inner = f'\n        {mods_str}\n    '
    elif position == 'end':
        trimmed_inner = inner.rstrip()
        if trimmed_inner.strip():
            last_char_idx = len(trimmed_inner) - 1
            while last_char_idx >= 0 and trimmed_inner[last_char_idx] in (' ', '\t', '\r', '\n'):
                last_char_idx -= 1
            if last_char_idx >= 0 and trimmed_inner[last_char_idx] != ',':
                trimmed_inner = trimmed_inner[:last_char_idx+1] + ',' + trimmed_inner[last_char_idx+1:]
            new_inner = trimmed_inner + f'\n        {mods_str}\n    '
        else:
            new_inner = f'\n        {mods_str}\n    '
    elif position in ('after', 'before') and target_mod:
        mod_regex = re.compile(rf'("[ \t]*{re.escape(target_mod)}[ \t]*")(,?)')
        target_m = mod_regex.search(inner)
        if target_m:
            if position == 'after':
                # Ensure the target item has a comma
                has_comma = bool(target_m.group(2))
                eol = inner.find('\n', target_m.end())
                if eol != -1:
                    insert_at = eol
                    if not has_comma:
                        # Insert comma before comment or newline
                        target_end = target_m.end()
                        inner = inner[:target_end] + ',' + inner[target_end:]
                        insert_at += 1
                    new_inner = inner[:insert_at] + f'\n        {mods_str},' + inner[insert_at:]
                else:
                    new_inner = inner[:target_m.end()] + f',\n        {mods_str}' + inner[target_m.end():]
            else: # before
                before_pos = target_m.start()
                new_inner = inner[:before_pos] + f'{mods_str},\n        ' + inner[before_pos:]
        else:
            new_inner = inner.rstrip() + f',\n        {mods_str}\n    '
    else:
        new_inner = inner.rstrip() + f',\n        {mods_str}\n    '
        
    return bar_text[:m.start()] + start_header + new_inner + closing + bar_text[m.end():]

def cmd_patch(config_path, bar_idx, section, position, target_mod, mods_csv, include_path):
    mods_to_add = [x.strip() for x in mods_csv.split(',') if x.strip()]
    if not mods_to_add:
        print("No modules specified to add.")
        sys.exit(1)
        
    raw_text, data = parse_config(config_path)
    is_array = isinstance(data, list)
    
    if not is_array:
        res_text = insert_include_in_bar(raw_text, include_path)
        res_text = patch_section(res_text, section, position, target_mod, mods_to_add)
    else:
        res_text = raw_text
        if "yamusic-modules.json" not in res_text:
            bracket_pos = res_text.find('[')
            if bracket_pos != -1:
                brace_pos = res_text.find('{', bracket_pos)
                if brace_pos != -1:
                    res_text = res_text[:brace_pos+1] + f'\n        "include": ["{include_path}"],' + res_text[brace_pos+1:]
        res_text = patch_section(res_text, section, position, target_mod, mods_to_add)
        
    try:
        clean = strip_jsonc(res_text)
        json.loads(clean)
    except Exception as e:
        print(f"Error: generated patched config is invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)
        
    with open(config_path, 'w', encoding='utf-8') as f:
        f.write(res_text)
        
    print("SUCCESS")

def cmd_unpatch(config_path, include_filename="yamusic-modules.json"):
    raw_text, data = parse_config(config_path)
    
    ym_mods = [
        r'[ \t]*"custom/mpris_heart",?[ \t]*\n?',
        r'[ \t]*"custom/ym_mpris",?[ \t]*\n?',
        r'[ \t]*"custom/ym_volume",?[ \t]*\n?'
    ]
    
    text = raw_text
    for ym in ym_mods:
        text = re.sub(ym, '', text)
        
    text = re.sub(rf'[ \t]*"[^"]*{include_filename}"[ \t]*,?\n?', '', text)
    text = re.sub(r'"include"\s*:\s*\[\s*\]\s*,?\n?', '', text)
    
    # Strip any trailing commas before closing bracket (even with comments)
    pattern = re.compile(r',([ \t]*(?://[^\r\n]*|/\*.*?\*/)?\s*[\]}])')
    text = pattern.sub(r'\1', text)
    
    try:
        clean = strip_jsonc(text)
        json.loads(clean)
    except Exception as e:
        print(f"Error validating unpatched config: {e}", file=sys.stderr)
        sys.exit(1)
        
    with open(config_path, 'w', encoding='utf-8') as f:
        f.write(text)
        
    print("SUCCESS")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: waybar_manager.py scan|patch|unpatch ...")
        sys.exit(1)
        
    action = sys.argv[1]
    if action == "scan":
        cmd_scan(sys.argv[2])
    elif action == "patch":
        cmd_patch(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8])
    elif action == "unpatch":
        cmd_unpatch(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "yamusic-modules.json")
    else:
        print(f"Unknown action: {action}")
        sys.exit(1)
