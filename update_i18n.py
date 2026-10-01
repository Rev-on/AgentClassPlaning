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

# Extract all dictionaries from I18n.ets
zh_dict = parse_ets_dict(i18n_content, 'zh')
en_dict = parse_ets_dict(i18n_content, 'en')

print(f"Extracted {len(zh_dict)} keys from I18n.ets zh dictionary")
print(f"Extracted {len(en_dict)} keys from I18n.ets en dictionary")

# Read UyghurDict.ets
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\UyghurDict.ets', 'r', encoding='utf-8') as f:
    ug_content = f.read()

ug_dict = {}
ug_match = re.search(r"static readonly dict: Map<string, string> = new Map<string, string>\(\[(.*?)\]\);", ug_content, re.DOTALL)
if ug_match:
    ug_content_dict = ug_match.group(1)
    for line in ug_content_dict.split('\n'):
        line = line.strip()
        if line.startswith("['") and "']" in line:
            key_match = re.match(r"\['([^']+)',\s*'([^']*)'\],?", line)
            if key_match:
                key = key_match.group(1)
                value = key_match.group(2)
                ug_dict[key] = value

print(f"Extracted {len(ug_dict)} keys from UyghurDict.ets")

# Read TibetanDict.ets
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\TibetanDict.ets', 'r', encoding='utf-8') as f:
    bo_content = f.read()

bo_dict = {}
bo_match = re.search(r"static readonly dict: Map<string, string> = new Map<string, string>\(\[(.*?)\]\);", bo_content, re.DOTALL)
if bo_match:
    bo_content_dict = bo_match.group(1)
    for line in bo_content_dict.split('\n'):
        line = line.strip()
        if line.startswith("['") and "']" in line:
            key_match = re.match(r"\['([^']+)',\s*'([^']*)'\],?", line)
            if key_match:
                key = key_match.group(1)
                value = key_match.group(2)
                bo_dict[key] = value

print(f"Extracted {len(bo_dict)} keys from TibetanDict.ets")

# Read MongolianDict.ets
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\MongolianDict.ets', 'r', encoding='utf-8') as f:
    mn_content = f.read()

mn_dict = {}
mn_match = re.search(r"static readonly dict: Map<string, string> = new Map<string, string>\(\[(.*?)\]\);", mn_content, re.DOTALL)
if mn_match:
    mn_content_dict = mn_match.group(1)
    for line in mn_content_dict.split('\n'):
        line = line.strip()
        if line.startswith("['") and "']" in line:
            key_match = re.match(r"\['([^']+)',\s*'([^']*)'\],?", line)
            if key_match:
                key = key_match.group(1)
                value = key_match.group(2)
                mn_dict[key] = value

print(f"Extracted {len(mn_dict)} keys from MongolianDict.ets")

# Read Windows i18n-data.js
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'r', encoding='utf-8') as f:
    content = f.read()

# Parse the JSON
match = re.search(r'window\.I18N_DATA\s*=\s*(\{.*\});', content, re.DOTALL)
if match:
    json_str = match.group(1)
    data = json.loads(json_str)
    
    # Find missing keys for each language
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        if lang in data:
            print(f'{lang}: {len(data[lang])} keys')
    
    # Get the reference dictionary (zh)
    ref_dict = zh_dict
    
    # Find missing keys for zh
    zh_keys = set(data.get('zh', {}).keys())
    all_zh_keys = set(ref_dict.keys())
    missing_zh_keys = sorted(all_zh_keys - zh_keys)
    
    print(f'\nMissing zh keys: {len(missing_zh_keys)}')
    
    # Add missing keys to each language
    # For zh
    for key in missing_zh_keys:
        data['zh'][key] = zh_dict[key]
    
    # For en
    en_keys = set(data.get('en', {}).keys())
    missing_en_keys = sorted(all_zh_keys - en_keys)
    print(f'Missing en keys: {len(missing_en_keys)}')
    
    for key in missing_en_keys:
        if key in en_dict:
            data['en'][key] = en_dict[key]
        else:
            # Fallback to zh value
            data['en'][key] = zh_dict[key]
    
    # For ug
    ug_keys = set(data.get('ug', {}).keys())
    missing_ug_keys = sorted(all_zh_keys - ug_keys)
    print(f'Missing ug keys: {len(missing_ug_keys)}')
    
    for key in missing_ug_keys:
        if key in ug_dict:
            data['ug'][key] = ug_dict[key]
        else:
            # Fallback to zh value
            data['ug'][key] = zh_dict[key]
    
    # For bo
    bo_keys = set(data.get('bo', {}).keys())
    missing_bo_keys = sorted(all_zh_keys - bo_keys)
    print(f'Missing bo keys: {len(missing_bo_keys)}')
    
    for key in missing_bo_keys:
        if key in bo_dict:
            data['bo'][key] = bo_dict[key]
        else:
            # Fallback to zh value
            data['bo'][key] = zh_dict[key]
    
    # For mn
    mn_keys = set(data.get('mn', {}).keys())
    missing_mn_keys = sorted(all_zh_keys - mn_keys)
    print(f'Missing mn keys: {len(missing_mn_keys)}')
    
    for key in missing_mn_keys:
        if key in mn_dict:
            data['mn'][key] = mn_dict[key]
        else:
            # Fallback to zh value
            data['mn'][key] = zh_dict[key]
    
    # Print final counts
    print('\nFinal counts:')
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        if lang in data:
            print(f'{lang}: {len(data[lang])} keys')
    
    # Write back the file
    # Convert to JSON string
    json_output = json.dumps(data, ensure_ascii=False, indent=2)
    
    # Reconstruct the file
    new_content = f'/* Auto-generated from HarmonyOS dictionaries */\nwindow.I18N_DATA = {json_output};'
    
    with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'w', encoding='utf-8') as f:
        f.write(new_content)
    
    print('\nFile updated successfully!')
else:
    print('Could not find JSON')