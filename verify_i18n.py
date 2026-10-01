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

print("HarmonyOS I18n.ets:")
print(f"  zh: {len(zh_dict)} keys")
print(f"  en: {len(en_dict)} keys")

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

print(f"  ug: {len(ug_dict)} keys")

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

print(f"  bo: {len(bo_dict)} keys")

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

print(f"  mn: {len(mn_dict)} keys")

# Read Windows i18n-data.js
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'r', encoding='utf-8') as f:
    content = f.read()

# Parse the JSON
match = re.search(r'window\.I18N_DATA\s*=\s*(\{.*\});', content, re.DOTALL)
if match:
    json_str = match.group(1)
    data = json.loads(json_str)
    
    print("\nWindows i18n-data.js:")
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        if lang in data:
            print(f"  {lang}: {len(data[lang])} keys")
    
    # Verify all dictionaries have the same keys
    print("\nVerification:")
    all_keys = set(zh_dict.keys())
    
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        lang_keys = set(data.get(lang, {}).keys())
        missing = all_keys - lang_keys
        if missing:
            print(f"  {lang} missing {len(missing)} keys: {sorted(missing)[:5]}...")
        else:
            print(f"  {lang}: All {len(all_keys)} keys present ✓")
else:
    print('Could not find JSON')