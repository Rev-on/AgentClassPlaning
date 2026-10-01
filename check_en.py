import re

# Read HarmonyOS I18n.ets
with open(r'C:\Users\laoyu\Desktop\Rev_Techingmaster\entry\src\main\ets\common\I18n.ets', 'r', encoding='utf-8') as f:
    content = f.read()

# Parse en dictionary - more robust parsing
en_start = content.find("private static readonly en: Map<string, string>")
if en_start < 0:
    print("Could not find en dictionary start")
    exit()

# Find the end of the en dictionary by counting brackets
balance = 0
pos = en_start
while pos < len(content):
    if content[pos] == '[':
        balance += 1
    elif content[pos] == ']':
        balance -= 1
        if balance == 0:
            en_end = pos + 1
            break
    pos += 1

if pos >= len(content):
    print("Could not find en dictionary end")
    exit()

en_content = content[en_start:en_end]

# Find all keys by parsing each line
# Handle both single quotes and double quotes
keys = []
lines = en_content.split('\n')
for i, line in enumerate(lines):
    line = line.strip()
    # Check for single quotes: ['key', 'value']
    if line.startswith("['"):
        # Find the first unescaped ' after the opening ['
        key_end = -1
        j = 2
        while j < len(line):
            if line[j] == "'" and (j == 0 or line[j-1] != '\\'):
                key_end = j
                break
            j += 1
        
        if key_end >= 0:
            key = line[2:key_end]
            keys.append(key)
    # Check for double quotes: ["key", "value"]
    elif line.startswith('["'):
        # Find the first unescaped " after the opening ["
        key_end = -1
        j = 2
        while j < len(line):
            if line[j] == '"' and (j == 0 or line[j-1] != '\\'):
                key_end = j
                break
            j += 1
        
        if key_end >= 0:
            key = line[2:key_end]
            keys.append(key)

print(f"Found {len(keys)} keys in en dictionary")

# Check for duplicates
from collections import Counter
key_counts = Counter(keys)
duplicates = {key: count for key, count in key_counts.items() if count > 1}
if duplicates:
    print(f"Duplicate keys: {len(duplicates)}")
    for key, count in duplicates.items():
        print(f"  {key}: {count} times")

# Check unique keys
unique_keys = set(keys)
print(f"Unique keys: {len(unique_keys)}")

# Check for specific keys
test_keys = ['def.researchInput', 'def.situation', 'splash.l2', 'watch.pushed', 'watch.pushFail']
print("\nChecking specific keys:")
for key in test_keys:
    if key in unique_keys:
        print(f"  {key}: FOUND")
    else:
        print(f"  {key}: NOT FOUND")
