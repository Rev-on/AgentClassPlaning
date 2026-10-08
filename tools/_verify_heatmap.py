# -*- coding: utf-8 -*-
"""验证 HeatMap 的列识别与归一化逻辑（复刻 ArkTS 实现）。"""
import math
import re

DERIVED = ['总分','总成绩','合计','平均','均分','均值','排名','名次','序号','学号',
           '班级','年级','考试','日期','备注','等级','总评',
           'total','average','avg','mean','rank','score','no','id',
           'class','grade','exam','date','remark','level']
NAMES = ['姓名','学生姓名','名字','学生','同学','名称','name','student','studentname']


def is_name(h):
    s = (h or '').strip().lower()
    return s != '' and any(k in s for k in NAMES)


def is_derived(h):
    s = (h or '').strip().lower()
    return s != '' and any(k in s for k in DERIVED)


def to_number(raw):
    s = (raw or '').strip()
    if s == '':
        return None
    c = re.sub(r'[分％%\s]', '', s)
    if not re.fullmatch(r'[+-]?\d+(\.\d+)?', c):
        return None
    return float(c)


def build(headers, rows):
    name_col = -1
    for j, h in enumerate(headers):
        if is_name(h):
            name_col = j
            break

    subjects = []
    for j, h in enumerate(headers):
        if j == name_col or (h or '').strip() == '' or is_derived(h):
            continue
        num = 0
        total = 0
        for r in rows:
            raw = r[j] if j < len(r) else ''
            if (raw or '').strip() == '':
                continue
            total += 1
            if to_number(raw) is not None:
                num += 1
        if total > 0 and num * 2 >= total:
            subjects.append({'col': j, 'name': h, 'min': None, 'max': None})

    for sub in subjects:
        vals = []
        for r in rows:
            raw = r[sub['col']] if sub['col'] < len(r) else ''
            v = to_number(raw)
            if v is not None:
                vals.append(v)
        sub['min'] = min(vals) if vals else None
        sub['max'] = max(vals) if vals else None

    out = []
    for i, r in enumerate(rows):
        cells = []
        for sub in subjects:
            raw = r[sub['col']] if sub['col'] < len(r) else ''
            v = to_number(raw)
            lvl = -1.0
            if v is not None:
                if sub['min'] is None or sub['max'] is None or sub['max'] == sub['min']:
                    lvl = 0.5
                else:
                    lvl = (v - sub['min']) / (sub['max'] - sub['min'])
                    lvl = max(0.0, min(1.0, lvl))
            cells.append({'raw': raw, 'v': v, 'level': lvl})
        student = ''
        if name_col >= 0 and name_col < len(r):
            student = (r[name_col] or '').strip()
        if student == '':
            student = '#' + str(i + 1)
        out.append({'student': student, 'cells': cells})
    return {'nameCol': name_col, 'subjects': subjects, 'rows': out}


passed = 0
failed = 0


def check(name, cond, detail=''):
    global passed, failed
    if cond:
        passed += 1
        print('  ✔ ' + name)
    else:
        failed += 1
        print('  ✘ ' + name + ('  ' + detail if detail else ''))


print('=== 用例1：标准成绩表（含总分/排名等派生列）===')
headers = ['姓名', '语文', '数学', '英语', '物理', '总分', '排名']
rows = [
    ['张三', '88', '92', '85', '90', '355', '1'],
    ['李四', '75', '68', '72', '70', '285', '3'],
    ['王五', '60', '55', '58', '52', '225', '5'],
]
r = build(headers, rows)
subs = [s['name'] for s in r['subjects']]
print('  识别科目: ' + str(subs))
check('只取 4 个单科，排除总分/排名', subs == ['语文', '数学', '英语', '物理'], str(subs))
check('姓名列定位正确', r['nameCol'] == 0)
check('最高分归一化为 1.0', abs(r['rows'][0]['cells'][0]['level'] - 1.0) < 1e-9)
check('最低分归一化为 0.0', abs(r['rows'][2]['cells'][0]['level'] - 0.0) < 1e-9)

print()
print('=== 用例2：含缺失值（缺考/横杠）===')
headers2 = ['姓名', '语文', '数学']
rows2 = [
    ['张三', '88', '缺考'],
    ['李四', '75', ''],
    ['王五', '60', '91'],
]
r2 = build(headers2, rows2)
check('数学列仍被识别（2/3 是数字，过半数）',
      [s['name'] for s in r2['subjects']] == ['语文', '数学'])
check('"缺考" 标记为缺失 level=-1',
      r2['rows'][0]['cells'][1]['level'] == -1)
check('空串标记为缺失', r2['rows'][1]['cells'][1]['level'] == -1)
check('王五数学=91 是该列唯一值 -> level=0.5（等值保护）',
      abs(r2['rows'][2]['cells'][1]['level'] - 0.5) < 1e-9)

print()
print('=== 用例3：无姓名列的表（统计表，合法输入）===')
headers3 = ['语文', '数学']
rows3 = [['90', '80'], ['70', '95']]
r3 = build(headers3, rows3)
check('无姓名列时回退为 #行号', r3['rows'][0]['student'] == '#1')
check('科目正常识别', len(r3['subjects']) == 2)

print()
print('=== 用例4：整列同值（避免除零）===')
headers4 = ['姓名', '语文']
rows4 = [['张三', '80'], ['李四', '80']]
r4 = build(headers4, rows4)
check('等值列统一 0.5',
      abs(r4['rows'][0]['cells'][0]['level'] - 0.5) < 1e-9 and
      abs(r4['rows'][1]['cells'][0]['level'] - 0.5) < 1e-9)

print()
print('=== 用例5：带单位/百分号的成绩 ===')
headers5 = ['姓名', '语文', '数学']
rows5 = [['张三', '88分', '92%'], ['李四', '75分', '68%']]
r5 = build(headers5, rows5)
check('"88分" 解析为 88', r5['rows'][0]['cells'][0]['v'] == 88.0)
check('"92%" 解析为 92', r5['rows'][0]['cells'][1]['v'] == 92.0)

print()
print('=== 用例6：区间值不应被当作数字 ===')
check('"90-100" 不解析为数字', to_number('90-100') is None)
check('"优" 不解析为数字', to_number('优') is None)
check('"88.5" 解析正确', to_number('88.5') == 88.5)

print()
print('=== 用例7：色阶单调性 ===')
def color_of(level):
    if level < 0:
        return '#EEF1F5'
    r0, g0, b0 = 0xEA, 0xF3, 0xFC
    r1, g1, b1 = 0x1B, 0x5F, 0xA8
    t = max(0.0, min(1.0, level))
    return '#%02X%02X%02X' % (round(r0 + (r1 - r0) * t),
                              round(g0 + (g1 - g0) * t),
                              round(b0 + (b1 - b0) * t))

c0 = color_of(0.0)
c1 = color_of(1.0)
cm = color_of(0.5)
print('  0.0 -> %s   0.5 -> %s   1.0 -> %s' % (c0, cm, c1))
check('0.0 是浅色', c0 == '#EAF3FC')
check('1.0 是深色', c1 == '#1B5FA8')
def brightness(hexs):
    return int(hexs[1:3], 16) + int(hexs[3:5], 16) + int(hexs[5:7], 16)
check('色阶随 level 单调变深',
      brightness(c0) > brightness(cm) > brightness(c1))

print()
print('=' * 56)
print('通过 %d / 失败 %d' % (passed, failed))
