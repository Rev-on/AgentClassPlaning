import json
import re

# Read Windows i18n-data.js
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\Windows\renderer\js\i18n-data.js', 'r', encoding='utf-8') as f:
    content = f.read()

# Parse the JSON
match = re.search(r'window\.I18N_DATA\s*=\s*(\{.*\});', content, re.DOTALL)
if match:
    json_str = match.group(1)
    data = json.loads(json_str)
    
    print("Windows i18n-data.js final key counts:")
    for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
        if lang in data:
            print(f"  {lang}: {len(data[lang])} keys")
    
    # Verify specific keys
    print("\nVerifying specific keys:")
    test_keys = ['btn.continue', 'err.export', 'cont.title', 'cont.hint', 'cont.empty', 
                 'watch.pushed', 'watch.pushFail', 'err.continuationFail']
    
    for key in test_keys:
        print(f"\n  {key}:")
        for lang in ['zh', 'en', 'ug', 'bo', 'mn']:
            if lang in data and key in data[lang]:
                print(f"    {lang}: {data[lang][key][:50]}...")
            else:
                print(f"    {lang}: NOT FOUND")
else:
    print('Could not find JSON')