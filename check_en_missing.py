import json
import re

def parse_ets_dict(content, dict_name):
    """Parse an ETS dictionary from the content"""
    result = {}
    pattern = rf"private static readonly {dict_name}: Map<string, string> = new Map<string, string>\(\[(.*?)\]\);"
    match = re.search(pattern, content, re.DOTALL)
    if match:
        dict_content = match.group(1)
        for line in dict_content.split('\n'):
            line = line.strip()
            if line.startswith("['") and "']" in line:
                key_match = re.match(r"\['([^']+)',\s*'([^']*)'\],?", line)
                if key_match:
                    key = key_match.group(1)
                    value = key_match.group(2)
                    result[key] = value
    return result

# Read HarmonyOS I18n.ets
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\I18n.ets', 'r', encoding='utf-8') as f:
    i18n_content = f.read()

# Extract zh and en dictionaries
zh_dict = parse_ets_dict(i18n_content, 'zh')
en_dict = parse_ets_dict(i18n_content, 'en')

# Find missing keys
zh_keys = set(zh_dict.keys())
en_keys = set(en_dict.keys())
missing_keys = sorted(zh_keys - en_keys)

print(f"HarmonyOS en dictionary missing {len(missing_keys)} keys:")
for key in missing_keys:
    print(f"  {key}: {zh_dict[key]}")