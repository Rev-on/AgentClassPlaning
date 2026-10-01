import json
import re

# Read HarmonyOS I18n.ets to get zh dictionary
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\I18n.ets', 'r', encoding='utf-8') as f:
    i18n_content = f.read()

# Extract zh dictionary from I18n.ets
zh_dict = {}
zh_match = re.search(r"private static readonly zh: Map<string, string> = new Map<string, string>\(\[(.*?)\]\);", i18n_content, re.DOTALL)
if zh_match:
    zh_content = zh_match.group(1)
    # Parse key-value pairs
    for line in zh_content.split('\n'):
        line = line.strip()
        if line.startswith("['") and "']" in line:
            # Extract key and value
            key_match = re.match(r"\['([^']+)',\s*'([^']*)'\],?", line)
            if key_match:
                key = key_match.group(1)
                value = key_match.group(2)
                zh_dict[key] = value

print(f"Extracted {len(zh_dict)} keys from I18n.ets zh dictionary")

# Read Windows i18n-data.js
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'r', encoding='utf-8') as f:
    content = f.read()

# Parse the JSON
match = re.search(r'window\.I18N_DATA\s*=\s*(\{.*\});', content, re.DOTALL)
if match:
    json_str = match.group(1)
    data = json.loads(json_str)
    
    # Print current keys for each language
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        if lang in data:
            print(f'{lang}: {len(data[lang])} keys')
    
    # Find missing keys for zh
    zh_keys = set(data.get('zh', {}).keys())
    all_zh_keys = set(zh_dict.keys())
    missing_zh_keys = all_zh_keys - zh_keys
    print(f'\nMissing zh keys: {len(missing_zh_keys)}')
    
    # Print missing keys
    for key in sorted(missing_zh_keys):
        print(f'  {key}: {zh_dict[key]}')