import json
import re

with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'r', encoding='utf-8') as f:
    content = f.read()

# Find the JSON part - more robust
match = re.search(r'window\.I18N_DATA\s*=\s*(\{.*\});', content, re.DOTALL)
if match:
    json_str = match.group(1)
    try:
        data = json.loads(json_str)
        for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
            if lang in data:
                print(f'{lang}: {len(data[lang])} keys')
            else:
                print(f'{lang}: not found')
    except json.JSONDecodeError as e:
        print(f'JSON decode error: {e}')
        print(f'Error at position: {e.pos}')
        print(f'Context: {json_str[e.pos-50:e.pos+50]}')
else:
    print('Could not find JSON')
