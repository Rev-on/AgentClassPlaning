# -*- coding: utf-8 -*-
"""新课标 RAG 索引构建（学科索引 + 内容索引）

前置：先跑 tools/ocr_std.py 生成 OCR 文本缓存
用法：
    python tools/ocr_std.py 8                  # 1) OCR 课标 PDF（首次约 10 分钟）
    python tools/build_rag_index.py            # 2) 构建索引到 server/rag/

输入：<repo>/server/.ocr_cache/<doc>.jsonl（每行 {"page":n,"text":...}）
输出（写入 server/rag/）：
  subjects.json  学科索引：学科/别名/学段/核心素养/课程目标/学段目标/学业质量/章节大纲
  chunks.json    内容索引：条目化内容块（原文 + 学科 + 章节路径 + 页码 + aux 标记）
  meta.json      构建元信息（页数、块数、来源文件指纹、构建时间）

用法: python build_rag_index.py [--ocr DIR] [--out DIR]
"""
import os, re, sys, json, time, hashlib, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OCR = os.path.join(REPO, 'server', '.ocr_cache')
OUT = os.path.join(REPO, 'server', 'rag')

CJK = r'\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff'
PUNCT = r'（）〈〉《》「」『』【】〔〕、，。；：！？…—·～￥%‰""'',.;:!?()<>"\'\-'

SUBJECTS = [
    {'id': 'general', 'name': '课程方案', 'file': '义务教育课程方案（2022年版）.pdf',
     'kind': 'general', 'stages': [],
     'aliases': ['课程方案', '培养目标', '课程设置', '教学建议', '评价建议', '课程实施',
                 '核心素养', '学业质量', '跨学科主题学习', '课时', '课程理念', '义务教育课程',
                 '有理想', '有本领', '有担当']},
    {'id': 'morality', 'name': '道德与法治', 'file': '义务教育道德与法治课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-9年级'],
     'aliases': ['道德与法治', '道法', '思想政治', '思想品德', '法治教育', '道德教育', '政治认同',
                 '道德修养', '法治观念', '健全人格', '责任意识']},
    {'id': 'chinese', 'name': '语文', 'file': '义务教育语文课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['语文', '小学语文', '初中语文', '汉语', '识字与写字', '阅读理解', '习作',
                 '写作', '古诗文', '文言文', '整本书阅读', '语言文字', '文化自信', '语言运用',
                 '思维能力', '审美创造']},
    {'id': 'english', 'name': '英语', 'file': '义务教育英语课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['英语', '英文', 'English', '外语', '听说读写', '语篇', '词汇', '语法', '主题语境',
                 '语言能力', '文化意识', '思维品质', '学习能力']},
    {'id': 'math', 'name': '数学', 'file': '义务教育数学课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['数学', '小学数学', '初中数学', '数与代数', '图形与几何', '统计与概率',
                 '综合与实践', '数感', '量感', '符号意识', '运算能力', '几何直观', '空间观念',
                 '推理意识', '推理能力', '数据意识', '数据观念', '模型意识', '模型观念',
                 '应用意识', '创新意识', '抽象能力', '方程', '函数', '三角形', '四边形', '圆']},
    {'id': 'history', 'name': '历史', 'file': '义务教育历史课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['7-9年级'],
     'aliases': ['历史', '初中历史', '中国古代史', '中国近代史', '中国现代史', '世界历史',
                 '世界古代史', '世界近代史', '世界现代史', '唯物史观', '时空观念', '史料实证',
                 '历史解释', '家国情怀', '鸦片战争', '辛亥革命', '抗日战争', '改革开放']},
    {'id': 'biology', 'name': '生物学', 'file': '义务教育生物学课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['7-9年级'],
     'aliases': ['生物学', '生物', '初中生物', '生命观念', '细胞', '生物体的结构层次',
                 '生物的多样性', '生物与环境', '植物的生活', '人体生理与健康', '遗传与进化',
                 '生态系统', '光合作用', '呼吸作用', '传染病', '免疫', '显微镜']},
    {'id': 'art', 'name': '艺术', 'file': '义务教育艺术课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['艺术', '音乐', '美术', '舞蹈', '戏剧', '影视', '书法', '艺术实践', '审美',
                 '审美感知', '艺术表现', '创意实践', '文化理解']},
    {'id': 'science', 'name': '科学', 'file': '义务教育科学课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['科学', '小学科学', '初中科学', '自然科学', '科学探究', '物质科学',
                 '生命科学', '地球与宇宙', '技术与工程', '科学观念', '科学思维', '探究实践',
                 '态度责任']},
    {'id': 'physics', 'name': '物理', 'file': '义务教育物理课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['7-9年级'],
     'aliases': ['物理', '初中物理', '八年级物理', '九年级物理', '力学', '电学', '磁学',
                 '声现象', '光现象', '热学', '物态变化', '压强', '浮力', '欧姆定律',
                 '电功率', '机械运动', '力和运动', '功和机械能', '内能', '透镜', '物理观念',
                 '科学思维', '科学探究', '科学态度与责任', '电和磁', '质量与密度']},
    {'id': 'chemistry', 'name': '化学', 'file': '义务教育化学课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['7-9年级'],
     'aliases': ['化学', '初中化学', '化学式', '酸碱盐', '元素', '原子', '分子', '化学方程式',
                 '氧气', '二氧化碳', '金属', '溶液', '化学实验', '燃烧', '质量守恒', '化学观念',
                 '科学探究与实践', '科学态度与责任', '物质的组成', '物质的变化']},
    {'id': 'geography', 'name': '地理', 'file': '义务教育地理课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['7-9年级'],
     'aliases': ['地理', '中国地理', '世界地理', '区域地理', '地图', '气候', '地形',
                 '人口', '自然环境', '乡土地理', '人地协调观', '综合思维', '区域认知', '地理实践力']},
    {'id': 'labor', 'name': '劳动', 'file': '义务教育劳动课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['劳动', '劳动教育', '劳动技术', '综合实践', '日常生活劳动', '生产劳动',
                 '服务性劳动', '劳动素养', '劳动课程', '劳动观念', '劳动能力', '劳动习惯',
                 '劳动精神', '烹饪', '种植', '公益劳动']},
    {'id': 'it', 'name': '信息科技', 'file': '义务教育信息科技课程标准（2022年版）.pdf',
     'kind': 'subject', 'stages': ['1-2年级', '3-4年级', '5-6年级', '7-9年级'],
     'aliases': ['信息科技', '信息技术', '计算机', '编程', '算法', '人工智能', '数据',
                 '网络', '信息安全', '信息意识', '计算思维', '数字化学习', '物联网',
                 '信息社会责任', '过程与控制', '互联网应用']},
]

STAGE_GRADES = {'第一学段': (1, 2), '第二学段': (3, 4), '第三学段': (5, 6),
                '第四学段': (7, 9), '第五学段': (10, 12)}

# 各课标的学段划分并不统一（如艺术为 1-2 / 3-5 / 6-7 / 8-9），
# 因此从章节标题里实测各学科的"第X学段(……年级)"，而不是套用统一表
STAGE_RANGE_RE = re.compile(
    r'第\s*([一二三四五])\s*学\s*段\s*[(（]?\s*([1-9])\s*[~～\-—–一至到]\s*([1-9])\s*年级')

AUX_KEYS = ('前言', '修订原则', '主要变化', '目录')

# ---------------- 文本清洗 ----------------

NUM_ONLY_RE = re.compile(r'^[\s\d\.\-—·、]+$')
DOTLEAD_RE = re.compile(r'[.．]{3,}|…{2,}')


def norm_text(t):
    t = t.replace('\u3000', ' ').replace('\xa0', ' ')
    pat = re.compile(r'([' + CJK + PUNCT + r'])[ \t]+(?=[' + CJK + PUNCT + r'])')
    for _ in range(4):
        nt = pat.sub(r'\1', t)
        if nt == t:
            break
        t = nt
    return re.sub(r'[ \t]{2,}', ' ', t).strip()


def is_noise(line):
    s = line.strip()
    if s == '':
        return True
    if NUM_ONLY_RE.match(s):
        return True
    # 扫描件页边的装饰字常被 OCR 单独识别成一两个字（如"督""相""目"）
    if len(s) == 1:
        return True
    flat = re.sub(r'\s+', '', s)
    if len(flat) <= 26 and ('课程标准' in flat or '课程方案' in flat) and re.search(r'20\s*2\s*2', flat):
        return True
    return False


def clean_heading(s):
    """标题行常与页边装饰字粘连（如"三、课程目标 | 督"），去掉竖线之后的内容"""
    s = re.split(r'[|丨│]', s)[0]
    s = re.sub(r'\s+', ' ', s).strip()
    return s.strip('、，。；：·-—～')


def is_toc_page(raw):
    """目录页：出现点线引导符（降为 2 行，部分课标目录尾页点线很少）"""
    hits = 0
    for line in raw.split('\n'):
        if DOTLEAD_RE.search(line):
            hits += 1
    return hits >= 2


def appendix_start_page(pages):
    """附录起始页：各课标页眉都印有"附录"二字，取正文过半后首次出现页
       （附录内部的标题会覆盖章节栈，只靠章节路径判断附录并不可靠）"""
    n = len(pages)
    for i, (pno, txt) in enumerate(pages):
        if i < n * 0.4:
            continue
        for ln in txt.split('\n'):
            s = re.sub(r'[\s|丨│]', '', ln)
            if s.startswith('附录') and '标准' not in s:
                return pno
    return None


def split_heading(line):
    """(level, title)；1=章 2=括号节 3=目/学段。过于句式的行不当作标题"""
    s = line.strip()
    if s == '' or len(s) > 34 or '。' in s:
        return None
    if re.match(r'^(前\s*言|目\s*录|附\s*录\s*[A-Z\d一二三四五六七八九十]*)', s):
        return (1, s)
    if re.match(r'^[一二三四五六七八九十]+\s*[、.．]', s):
        return (1, s)
    if re.match(r'^[（(]\s*[一二三四五六七八九十]+\s*[)）]', s):
        return (2, s)
    if re.match(r'^第\s*[一二三四五六七八九十]+\s*学\s*段', s):
        return (3, s)
    if re.match(r'^\d+\.\d+\s*[\u4e00-\u9fff]', s) and len(s) <= 22:
        return (3, s)
    # 数字条目：短、不以连接词结尾、不含"，"过多
    if re.match(r'^\d+\s*[、.]\s*[\u4e00-\u9fff]', s) and len(s) <= 22:
        if s[-1] in '等的了和与及或，,、；;：:':
            return None
        return (3, s)
    return None


def page_blocks(raw):
    blocks = []
    buf = []
    for rawline in raw.split('\n'):
        line = norm_text(rawline)
        if line == '' or is_noise(line):
            continue
        h = split_heading(line)
        if h is not None:
            title = clean_heading(h[1])
            if len(title) >= 2:
                if buf:
                    blocks.append(('p', ' '.join(buf)))
                    buf = []
                blocks.append(('h%d' % h[0], title))
                continue
        buf.append(line)
    if buf:
        blocks.append(('p', ' '.join(buf)))
    return blocks


# ---------------- 分块 ----------------

def build_chunks(doc_name, subject, pages, app_start=None, max_len=760, min_len=120, overlap=90):
    chunks = []
    path = {1: '', 2: '', 3: ''}
    cur = []
    cur_len = 0
    cur_page = 1

    def sec_path():
        return ' > '.join([p for p in (path[1], path[2], path[3]) if p != ''])

    def flush():
        nonlocal cur, cur_len
        body = ' '.join(cur).strip()
        if len(body) >= min_len:
            sec = sec_path()
            chunks.append({'s': subject, 'd': doc_name, 'sec': sec,
                           'p': cur_page, 't': body,
                           'aux': 1 if any(k in sec for k in AUX_KEYS) else 0,
                           'app': 1 if (app_start and cur_page >= app_start) else 0})
        cur = []
        cur_len = 0

    for pno, page_text in pages:
        for kind, text in page_blocks(page_text):
            if kind.startswith('h'):
                lv = int(kind[1])
                if cur_len >= max_len:
                    flush()
                # 同一标题重复出现（如页眉/页脚残留）时不清空更深层，避免丢掉已定位的小节
                if path[lv] != text:
                    path[lv] = text
                    for deeper in (1, 2, 3):
                        if deeper > lv:
                            path[deeper] = ''
                if len(cur) == 0:
                    cur_page = pno
                continue
            if len(cur) == 0:
                cur_page = pno
            if cur_len + len(text) > max_len and cur_len >= min_len:
                tail = ' '.join(cur)[-overlap:]
                flush()
                cur = [tail]
                cur_len = len(tail)
                cur_page = pno
            cur.append(text)
            cur_len += len(text)
    flush()
    return chunks


# ---------------- 结构化抽取 ----------------

def sections_of(chunks):
    sections = {}
    order = []
    for c in chunks:
        k = c['sec']
        if k not in sections:
            sections[k] = {'sec': k, 'text': [], 'p': c['p'], 'ids': [], 'aux': c['aux']}
            order.append(k)
        sections[k]['text'].append(c['t'])
        sections[k]['ids'].append(c['i'])
    for k in sections:
        sections[k]['full'] = ' '.join(sections[k]['text'])
    return sections, order


CORE_SENT_RE = re.compile(r'核心素养[^。；;]{0,20}(主要包括|主要是指|主要指|包括|是由[^。；;]{0,8}构成)')
CORE_HEAD_RE = re.compile(r'核心素养内涵|素养内涵')
CORE_DEF_MARK = ('正确价值观', '必备品格', '关键能力')

# 抽取结果的语义起点锚点（按优先级排列；块会跨小节，开头常残留上一节文字，需对齐裁掉）
CORE_START_RE = [
    r'核心素养[^。；;]{0,8}(主要包括|主要是指|主要指|包括)',
    r'核心素养是',
    r'核心素养内涵',
    r'要培养的[^。；;]{0,6}核心素养',
]
GOAL_START_RE = [r'总目标', r'目标要求', r'学生应通过本课程的学习', r'课程目标']
QUALITY_START_RE = [r'学业质量内涵', r'学业质量是', r'学业质量']
STAGE_START_RE = [r'学段目标', r'第\s*[一二三四五]\s*学段', r'[1-9]\s*年级']


def cut_at(text, patterns):
    """按优先级找语义起点，裁掉其前面的跨节残留"""
    for p in patterns:
        m = re.search(p, text)
        if m and m.start() > 0:
            return text[m.start():].strip()
    return text.strip()


def extract_core(chunks, sections, order, self_name, dims):
    """核心素养抽取：优先用章节树（小节标题已被切走，正文里查不到"核心素养内涵"），
       再用正文锚点兜底，最后按"维度词命中数 + 素养定义句 + 非前言块"打分择优"""
    cands = []

    # A. 章节路径中含"核心素养"的子树（合并同前缀的各条，得到完整素养内涵小节）
    prefixes = {}
    for k in order:
        parts = k.split(' > ')
        for i, p in enumerate(parts):
            if '核心素养' in p:
                prefixes.setdefault(' > '.join(parts[:i + 1]), []).append(k)
                break
    for pre, ks in prefixes.items():
        text = ' '.join(sections[k]['full'] for k in ks)
        if len(text) < 300:
            continue
        sc = 6
        if any(mark in text for mark in CORE_DEF_MARK):
            sc += 2
        sc += min(sum(1 for d in dims if len(d) >= 3 and d in text), 5)
        if any(sections[k]['aux'] for k in ks):
            sc -= 5
        cands.append((sc, -sections[ks[0]]['ids'][0], text, sections[ks[0]]['p'], pre))

    # B. 正文锚点
    for idx, c in enumerate(chunks):
        t = c['t']
        for anc in (CORE_HEAD_RE, CORE_SENT_RE):
            for m in anc.finditer(t):
                s0 = m.start()
                pre = t[max(0, s0 - 10):s0]
                if '中国学生' in pre or '学生发展' in pre:
                    continue
                win = t[max(0, s0 - 20):s0 + 420]
                sc = 2 if anc is CORE_HEAD_RE else 1
                if any(mark in win for mark in CORE_DEF_MARK):
                    sc += 3
                if self_name in win:
                    sc += 2
                if '课程' in t[max(0, s0 - 24):s0]:
                    sc += 1
                sc += min(sum(1 for d in dims if len(d) >= 3 and d in win), 5)
                if c['aux']:
                    sc -= 5
                text = t[max(0, s0 - 40):]
                j = idx + 1
                while len(text) < 1500 and j < len(chunks):
                    text += ' ' + chunks[j]['t']
                    j += 1
                cands.append((sc, -idx, text[:1700], c['p'], c['sec']))

    if not cands:
        return None
    cands.sort(key=lambda x: (x[0], x[1]), reverse=True)
    _, _, text, page, sec = cands[0]
    return {'section': sec, 'text': cut_at(text, CORE_START_RE)[:1700], 'p': page}


def norm_head(s):
    """去掉标题前的编号，便于比对（如"(二)目标要求" -> "目标要求"）"""
    t = re.sub(r'^[\s（(【\[]*', '', s)
    t = re.sub(r'^[一二三四五六七八九十\d]+\s*[）)】\]]*\s*[、.．]?\s*', '', t)
    return t.strip()


def extract_grouped(sections, order, keys, starts=None, min_len=240, max_len=2600):
    """按"任意层级标题命中关键词"聚合该子树全文。

    课标里课程目标/学业质量这类章节的父标题常被 OCR 与正文粘连（甚至丢失），
    只剩下一堆子条目，此时按标题栈精确取小节会取不到；按子树聚合更稳。
    keys 按优先级排列，取文档顺序中第一个命中的子树。
    """
    prefixes = {}
    for k in order:
        parts = k.split(' > ')
        for i, p in enumerate(parts):
            np = norm_head(p)
            if any(x in np for x in keys):
                prefixes.setdefault(' > '.join(parts[:i + 1]), []).append(k)
                break
    for pre, ks in prefixes.items():
        # 目录残留拼出的假标题（点线引导符、省略号、过长）排除
        if DOTLEAD_RE.search(pre) or '…' in pre or len(pre) > 46:
            continue
        if all(sections[k]['aux'] for k in ks):
            continue
        text = ' '.join(sections[k]['full'] for k in ks)
        if min_len <= len(text):
            body = cut_at(text, starts) if starts else text
            return {'section': pre, 'text': body[:max_len], 'p': sections[ks[0]]['p']}
    return None


def extract_cultivate_goal(chunks):
    """课程方案的「培养目标」（有理想 / 有本领 / 有担当）"""
    for idx, c in enumerate(chunks):
        if c['aux']:
            continue
        m = re.search(r'有理想|有本领|有担当', c['t'])
        if not m:
            continue
        text = c['t'][max(0, m.start() - 60):]
        j = idx + 1
        while len(text) < 1500 and j < len(chunks):
            text += ' ' + chunks[j]['t']
            j += 1
        return {'section': c['sec'], 'text': cut_at(text, [r'有理想'])[:1700], 'p': c['p']}
    return None


def extract_by_anchor(chunks, anchor, span=1500):
    """按正文锚点抽取（标题未识别时的兜底）"""
    for idx, c in enumerate(chunks):
        if c['aux']:
            continue
        m = re.search(anchor, c['t'])
        if not m:
            continue
        text = c['t'][m.start():]
        j = idx + 1
        while len(text) < span - 200 and j < len(chunks):
            text += ' ' + chunks[j]['t']
            j += 1
        return {'section': c['sec'], 'text': text[:span], 'p': c['p']}
    return None


def extract_by_head(sections, order, keys, min_len=200, max_len=2600, sub_only=False, starts=None):
    for k in order:
        parts = k.split(' > ')
        if sub_only and len(parts) < 2:
            continue
        tail = parts[-1]
        if any(x in tail for x in keys):
            full = sections[k]['full']
            if min_len <= len(full):
                body = cut_at(full, starts) if starts else full
                return {'section': k, 'text': body[:max_len], 'p': sections[k]['p']}
    return None


def extract_goals(sections, order, chunks):
    r = extract_grouped(sections, order, ['总目标', '目标要求'], GOAL_START_RE, 240, 2600)
    if r is None:
        r = extract_by_head(sections, order, ['总目标', '目标要求'], 200, 2600, True, GOAL_START_RE)
    if r is None:
        r = extract_by_anchor(chunks, r'总目标', 1500)
    return r


def extract_quality(sections, order):
    r = extract_grouped(sections, order, ['学业质量'], QUALITY_START_RE, 240, 2400)
    if r is None:
        r = extract_by_head(sections, order, ['学业质量'], 240, 2400, False, QUALITY_START_RE)
    return r


def extract_stage_goals(sections, order):
    out = []
    for k in order:
        parts = k.split(' > ')
        if not any('课程目标' in p for p in parts):
            continue
        tail = parts[-1]
        ok = ('学段目标' in tail) or re.search(r'第\s*[一二三四五]\s*学段', tail)
        if not ok:
            continue
        full = sections[k]['full']
        if len(full) < 260:
            continue
        label = tail
        for p in reversed(parts[:-1]):
            if re.search(r'第\s*[一二三四五]\s*学段', p) or '学段目标' in p:
                label = p + ' · ' + tail
                break
        out.append({'label': label, 'text': cut_at(full, STAGE_START_RE)[:4200], 'p': sections[k]['p']})
    return out


def extract_stage_map(chunks):
    """从章节标题实测该学科的学段→年级区间（各课标划分不同，不能套用统一表）"""
    m = {}
    for c in chunks:
        for mm in STAGE_RANGE_RE.finditer(c['sec'] or ''):
            key = '第' + mm.group(1) + '学段'
            lo, hi = int(mm.group(2)), int(mm.group(3))
            if lo > hi:
                lo, hi = hi, lo
            if key not in m or (hi - lo) > (m[key][1] - m[key][0]):
                m[key] = [lo, hi]
    return m


def extract_outline(sections, order):
    out = []
    for k in order:
        if k == '':
            continue
        head = sections[k]['full'][:110]
        if DOTLEAD_RE.search(head):
            continue
        parts = k.split(' > ')
        if len(parts) < 2 and len(k) < 6:
            continue
        out.append({'sec': k, 'p': sections[k]['p'], 'ids': sections[k]['ids'], 'head': head})
    return out


# ---------------- 主流程 ----------------

def main():
    os.makedirs(OUT, exist_ok=True)
    all_chunks = []
    subjects = []
    files_meta = []
    for sd in SUBJECTS:
        path = os.path.join(OCR, sd['file'] + '.jsonl')
        if not os.path.exists(path):
            print('[缺失] %s' % sd['file'])
            continue
        pages = []
        toc_skip = 0
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line == '':
                    continue
                o = json.loads(line)
                if is_toc_page(o['text']):
                    toc_skip += 1
                    continue
                pages.append((o['page'], o['text']))
        doc = os.path.splitext(sd['file'])[0]
        app_start = appendix_start_page(pages)
        chunks = build_chunks(doc, sd['id'], pages, app_start)
        for c in chunks:
            c['i'] = len(all_chunks)
            all_chunks.append(c)
        sections, order = sections_of(chunks)

        core = extract_core(chunks, sections, order, sd['name'], sd['aliases'])
        if core is None and sd['kind'] == 'general':
            core = extract_cultivate_goal(chunks)
        entry = {
            'id': sd['id'], 'name': sd['name'], 'doc': doc, 'kind': sd['kind'],
            'stages': sd['stages'], 'aliases': sd['aliases'],
            'chunkStart': chunks[0]['i'] if chunks else -1,
            'chunkEnd': chunks[-1]['i'] if chunks else -1,
            'chunkCount': len(chunks),
            'stageMap': extract_stage_map(chunks),
            'core': core,
            'goals': extract_goals(sections, order, chunks),
            'stageGoals': extract_stage_goals(sections, order),
            'quality': extract_quality(sections, order),
            'outline': extract_outline(sections, order)
        }
        subjects.append(entry)
        files_meta.append({'file': sd['file'], 'pages': len(pages), 'tocSkipped': toc_skip,
                           'chunks': len(chunks),
                           'md5': hashlib.md5(open(path, 'rb').read()).hexdigest()[:12]})
        print('%-10s 页%4d(跳目录%d) 块%4d 附录起于%s 素养%s 学段目标%d 质量%s 大纲%d 学段划分%s' % (
            sd['name'], len(pages), toc_skip, len(chunks),
            ('p%s' % app_start) if app_start else '无',
            '有' if entry['core'] else '无', len(entry['stageGoals']),
            '有' if entry['quality'] else '无', len(entry['outline']),
            ','.join('%s:%s' % (k.replace('学段', ''), v[0]) for k, v in entry['stageMap'].items())))

    with open(os.path.join(OUT, 'chunks.json'), 'w', encoding='utf-8') as f:
        json.dump({'chunks': all_chunks}, f, ensure_ascii=False, separators=(',', ':'))
    with open(os.path.join(OUT, 'subjects.json'), 'w', encoding='utf-8') as f:
        json.dump({'subjects': subjects}, f, ensure_ascii=False, indent=1)
    with open(os.path.join(OUT, 'meta.json'), 'w', encoding='utf-8') as f:
        json.dump({'builtAt': time.strftime('%Y-%m-%d %H:%M:%S'),
                   'standard': '义务教育课程方案和课程标准（2022年版）',
                   'source': 'teching/ 目录下 11 份 PDF（扫描件，经 OCR 提取文字）',
                   'totalChunks': len(all_chunks),
                   'totalPages': sum(m['pages'] for m in files_meta),
                   'auxChunks': sum(1 for c in all_chunks if c['aux']),
                   'files': files_meta}, f, ensure_ascii=False, indent=1)
    cs = os.path.getsize(os.path.join(OUT, 'chunks.json'))
    ss = os.path.getsize(os.path.join(OUT, 'subjects.json'))
    print('chunks.json %.2f MB  subjects.json %.2f KB  共 %d 块 %d 页' % (
        cs / 1048576, ss / 1024, len(all_chunks), sum(m['pages'] for m in files_meta)))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--ocr', default=OCR, help='OCR 文本缓存目录，默认 server/.ocr_cache')
    ap.add_argument('--out', default=OUT, help='索引输出目录，默认 server/rag')
    _a = ap.parse_args()
    OCR = _a.ocr
    OUT = _a.out
    main()
