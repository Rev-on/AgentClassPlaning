# -*- coding: utf-8 -*-
"""
生成《文档鉴别材料》Word 文档（.docx，可编辑）。

格式与程序鉴别材料一致：
  - 页眉左侧：Agent备课  V1.0
  - 页眉右侧：页码（自动域）
  - A4、正文小四、标题分级

内容依据：README.md + 源码（Prompts.ets / AiService.ets / I18n.ets /
          Seats.ets / rag.js / build-profile.json5 等）。

v2 修订：
  - 第五章「运行环境」大幅扩写：最低版本、SDK 版本、体积与存储、服务端部署要求
  - 第四章改为聚焦「设计决策与理由」（为什么这样做），工程细节下沉为支撑说明
"""
import os

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = r'C:\Users\laoyu\Desktop\Rev_Techingmaster'
OUT = os.path.join(ROOT, 'docs', '文档鉴别材料_Agent备课V1.0.docx')

APP = 'Agent备课'
VER = 'V1.0'
CN_FONT = '宋体'
CN_HEI = '黑体'
EN_FONT = 'Times New Roman'


# ---------------------------------------------------------------- 基础工具
def set_run(run, size=12, bold=False, cn=CN_FONT, en=EN_FONT, color=None):
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.name = en
    run._element.rPr.rFonts.set(qn('w:eastAsia'), cn)
    if color:
        run.font.color.rgb = RGBColor(*color)


def para(doc, text='', size=12, bold=False, align=None, indent=True,
         space_before=0, space_after=6, cn=CN_FONT, line=1.5):
    p = doc.add_paragraph()
    if align is not None:
        p.alignment = align
    pf = p.paragraph_format
    pf.space_before = Pt(space_before)
    pf.space_after = Pt(space_after)
    pf.line_spacing = line
    if indent and align is None:
        pf.first_line_indent = Pt(size * 2)
    if text:
        set_run(p.add_run(text), size=size, bold=bold, cn=cn)
    return p


def heading(doc, text, level=1):
    sizes = {0: 18, 1: 15, 2: 13.5, 3: 12}
    before = {0: 0, 1: 16, 2: 12, 3: 10}
    after = {0: 14, 1: 8, 2: 6, 3: 4}
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before = Pt(before[level])
    pf.space_after = Pt(after[level])
    pf.line_spacing = 1.4
    if level == 0:
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run(p.add_run(text), size=sizes[level], bold=True, cn=CN_HEI)
    ppr = p._p.get_or_add_pPr()
    ol = OxmlElement('w:outlineLvl')
    ol.set(qn('w:val'), str(max(0, level)))
    ppr.append(ol)
    return p


def add_field(paragraph, instr):
    r = paragraph.add_run()
    f1 = OxmlElement('w:fldChar')
    f1.set(qn('w:fldCharType'), 'begin')
    it = OxmlElement('w:instrText')
    it.set(qn('xml:space'), 'preserve')
    it.text = instr
    f2 = OxmlElement('w:fldChar')
    f2.set(qn('w:fldCharType'), 'separate')
    t = OxmlElement('w:t')
    t.text = '1'
    f3 = OxmlElement('w:fldChar')
    f3.set(qn('w:fldCharType'), 'end')
    for e in (f1, it, f2, t, f3):
        r._r.append(e)
    return r


def bullet(doc, text, size=12, bold_head=None):
    if not isinstance(size, int):
        bold_head, size = size, 12
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_after = Pt(3)
    pf.line_spacing = 1.5
    pf.left_indent = Pt(size * 2)
    pf.first_line_indent = Pt(-size)
    if bold_head:
        set_run(p.add_run('· '), size=size)
        set_run(p.add_run(bold_head), size=size, bold=True, cn=CN_HEI)
        set_run(p.add_run(text), size=size)
    else:
        set_run(p.add_run('· ' + text), size=size)
    return p


def set_col_widths(table, widths_cm):
    """直接写 tblGrid + tcW 并固定布局，避免 Word 按内容自动分配导致超页。"""
    tbl = table._tbl
    tblPr = tbl.tblPr
    for tag in ('w:tblLayout', 'w:tblW'):
        for el in tblPr.findall(qn(tag)):
            tblPr.remove(el)
    layout = OxmlElement('w:tblLayout')
    layout.set(qn('w:type'), 'fixed')
    tblPr.append(layout)
    tw = OxmlElement('w:tblW')
    tw.set(qn('w:w'), str(int(sum(widths_cm) * 567)))
    tw.set(qn('w:type'), 'dxa')
    tblPr.append(tw)
    for g in tbl.findall(qn('w:tblGrid')):
        tbl.remove(g)
    grid = OxmlElement('w:tblGrid')
    for wcm in widths_cm:
        gc = OxmlElement('w:gridCol')
        gc.set(qn('w:w'), str(int(wcm * 567)))
        grid.append(gc)
    tbl.insert(list(tbl).index(tblPr) + 1, grid)
    for row in table.rows:
        for i, wcm in enumerate(widths_cm):
            if i >= len(row.cells):
                continue
            tcPr = row.cells[i]._tc.get_or_add_tcPr()
            for el in tcPr.findall(qn('w:tcW')):
                tcPr.remove(el)
            cw = OxmlElement('w:tcW')
            cw.set(qn('w:w'), str(int(wcm * 567)))
            cw.set(qn('w:type'), 'dxa')
            tcPr.append(cw)


def make_table(doc, headers, rows, widths=None, size=10.5):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    for i, h in enumerate(headers):
        c = t.rows[0].cells[i]
        c.text = ''
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(2)
        set_run(p.add_run(h), size=size, bold=True, cn=CN_HEI)
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ''
            p = cells[i].paragraphs[0]
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.25
            set_run(p.add_run(str(v)), size=size)
    if widths:
        set_col_widths(t, widths)
    tail = doc.add_paragraph()
    tail.paragraph_format.space_after = Pt(4)
    tail.paragraph_format.line_spacing = 1.0
    set_run(tail.add_run(''), size=6)
    return t


def setup_header_footer(doc):
    sec = doc.sections[0]
    sec.different_first_page_header_footer = False
    hp = sec.header.paragraphs[0]
    hp.paragraph_format.tab_stops.clear_all()
    usable = sec.page_width - sec.left_margin - sec.right_margin
    hp.paragraph_format.tab_stops.add_tab_stop(usable, WD_TAB_ALIGNMENT.RIGHT)
    hp.paragraph_format.space_after = Pt(2)
    set_run(hp.add_run('%s  %s' % (APP, VER)), size=10.5, bold=True, cn=CN_HEI)
    hp.add_run('\t')
    set_run(add_field(hp, ' PAGE '), size=10.5)
    ppr = hp._p.get_or_add_pPr()
    bd = OxmlElement('w:pBdr')
    bottom = OxmlElement('w:bottom')
    bottom.set(qn('w:val'), 'single')
    bottom.set(qn('w:sz'), '6')
    bottom.set(qn('w:space'), '1')
    bottom.set(qn('w:color'), '000000')
    bd.append(bottom)
    ppr.append(bd)
    sec.footer.paragraphs[0].text = ''


# ---------------------------------------------------------------- 文档内容
def build():
    doc = Document()
    sec = doc.sections[0]
    sec.page_width = Cm(21.0)
    sec.page_height = Cm(29.7)
    sec.top_margin = Cm(2.4)
    sec.bottom_margin = Cm(2.4)
    sec.left_margin = Cm(2.6)
    sec.right_margin = Cm(2.6)
    sec.header_distance = Cm(1.4)

    st = doc.styles['Normal']
    st.font.name = EN_FONT
    st.font.size = Pt(12)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), CN_FONT)

    setup_header_footer(doc)

    # ============================ 封面 ============================
    heading(doc, '文档鉴别材料', 0)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_after = Pt(4)
    set_run(p.add_run('Agent备课  V1.0'), size=14, bold=True, cn=CN_HEI)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_after = Pt(18)
    set_run(p.add_run('初中教学备课智能体 · 软件设计说明书'), size=12)

    # ============================ 一、概述 ============================
    heading(doc, '一、软件概述', 1)
    para(doc, 'Agent备课（Rev TechingMaster）V1.0 是一款面向初中教师的 AI 教学备课智能体，'
              '采用鸿蒙原生 ArkTS（Stage 模型）开发，同步产出 Android（ArkUI-X）与 '
              'Windows（Electron）桌面版本。软件以“AI 生成初稿、教师修改使用”为核心设计理念，'
              '把教案撰写、课件大纲、分层练习、教研科研、学情分析、智能排座、家校沟通等'
              '日常教学事务集成于一个应用，教师经简单填空即可获得可直接使用的教学材料。')

    heading(doc, '1.1 设计目标', 2)
    bullet(doc, '把 AI 能力嵌入教师真实工作流，减少重复性文书劳动。', '降本增效：')
    bullet(doc, '所有 AI 生成内容统一标注“（AI生成，仅供参考）”，首次启动弹出 5 秒倒计时'
                '免责声明，明确人机责任边界。', '责任可溯：')
    bullet(doc, '班级名单、成绩、历史记录全部保存在本机，不上传云端。', '数据本地优先：')
    bullet(doc, '内置中、英、维吾尔、藏、蒙古五种语言界面，并为少数民族文字提供专门的'
                '字体与排版支持。', '多语言无障碍：')

    heading(doc, '1.2 总体架构', 2)
    para(doc, '软件分为客户端与服务端两部分。客户端负责界面交互、内容渲染与文档导出；'
              '服务端（server/）为自建 Node.js 中转代理，持有 DeepSeek API Key 并向模型'
              '转发请求，同时承担新课标检索增强（RAG）与后台生成任务队列。'
              '应用本身不包含任何密钥明文。')
    make_table(doc,
               ['层次', '组成', '主要职责'],
               [
                   ['界面层', 'pages/ 共 16 个页面',
                    '首页工作台、7 大 AI 功能页、排座、班级管理、历史、设置等'],
                   ['服务层', 'common/ 68 个模块',
                    'AI 调用、任务调度、会话恢复、文档导出、多语言、主题与字体'],
                   ['代理层', 'server/src/*.js',
                    '密钥托管、请求转发、SSE 流式输出、任务队列、新课标检索注入'],
                   ['模型层', 'DeepSeek',
                    '按提示词生成教案、课件大纲、练习、报告等结构化内容'],
               ],
               widths=[2.2, 4.2, 8.6])

    # ============================ 二、七大 AI 功能 ============================
    heading(doc, '二、七大 AI 功能详述', 1)
    para(doc, '软件共提供七大 AI 生成功能，均可通过首页“备课助手”“家校沟通”两个页签进入。'
              '每项功能均由独立的系统提示词（Prompts.ets）约束角色、输出结构与格式，'
              '保证生成内容直接可用、无需二次排版。')

    heading(doc, '2.1 功能一：智能教案生成', 2)
    para(doc, '教师填写学科、教材版本、年级、课题、课时、课型等基本信息，'
              '并可补充“备注”（如班级学情、教学风格），点击生成后由 AI 输出完整教案。')
    bullet(doc, '资深初中教研员。', '提示词角色：')
    bullet(doc, '基本信息、教学目标（三维目标、行为可测）、教学重难点、教学准备、'
                '教学过程（分环节、标注时间与师生活动）、板书设计（文字线框图）、'
                '分层作业（基础/提高/拓展）、教学反思要点，共八个部分。', '输出结构：')
    bullet(doc, '生成结果可直接导出 Word、保存到历史，或一键跳转至“课件生成”页，'
                '把本教案作为上下文继续生成配套课件。', '后续衔接：')

    heading(doc, '2.2 功能二：课件大纲生成与 PPTX 导出', 2)
    para(doc, '为给定课题生成逐页课件大纲，并可直接导出为 PowerPoint 文件。')
    bullet(doc, '每一页严格包含 type（页面类型）、title（标题）、notes（讲解提示）、'
                'body（正文要点）四个字段，页数 8–14 页。', '结构化输出：')
    bullet(doc, '封面 → 导入 → 讲解（按重难点拆 3–5 页）→ 例题 → 练习 → 小结 → 作业。',
           '固定页序：')
    bullet(doc, '软件内置单页 PPTX 模板（pptskel.pptx），导出时逐页复制展开并注入内容，'
                '生成标准 16:9 幻灯片；配色、版式由客户端统一装配，AI 只负责内容质量。',
           'PPTX 导出：')
    bullet(doc, '大纲同时支持导出为 JSON 文件，便于在其它课件工具或脚本中二次加工'
                '（详见 docs/课件大纲JSON-使用教程.md）。', 'JSON 导出：')

    heading(doc, '2.3 功能三：分层练习命题', 2)
    para(doc, '按课题命制三层难度练习，满足班级内不同能力层级学生的需求。')
    bullet(doc, '基础巩固（2–3 题）、能力提升（2–3 题）、拓展挑战（2–3 题）。', '三层结构：')
    bullet(doc, '【题目】【答案】【解析】【对应知识点】。', '每题含四项信息：')
    bullet(doc, '题干严谨、数值自洽，解析须指向对应知识点，便于教师直接印发或改写。',
           '质量约束：')

    heading(doc, '2.4 功能四：教研科研辅助', 2)
    para(doc, '面向教师专业发展，提供三种教研写作辅助，页面底部设有学术诚信警示水印。')
    make_table(doc,
               ['子功能', '输入', '输出'],
               [
                   ['选题建议', '研究兴趣方向、学段学科',
                    '3 个可操作论文选题，各含研究价值、研究问题、研究方法、可行性、检索关键词'],
                   ['论文大纲', '论文主题',
                    '六部分大纲：引言、研究背景与问题、研究设计/实践、结果与分析、'
                    '结论与建议、参考文献方向'],
                   ['摘要润色', '原始摘要',
                    '润色后摘要（150–250 字，含背景-方法-结果-结论）+ 3 条修改说明 + 3 个关键词'],
               ],
               widths=[2.6, 4.4, 8.0])

    heading(doc, '2.5 功能五：学情分析与报告生成', 2)
    para(doc, '支持粘贴成绩数据或通过 Excel 文件导入，由 AI 生成班级学情分析报告。')
    bullet(doc, '整体概况（均分/及格率/优秀率/分布）、知识点掌握（依数据推断薄弱点）、'
                '学生个体分析（典型 2–4 名）、教学建议（3–5 条可操作）、分层教学方案。',
           '报告结构：')
    bullet(doc, '结论必须基于所给数据，不得编造。', '数据约束：')
    bullet(doc, '成绩数据仅在本次请求中传输用于分析，报告生成后保存于本机历史记录。',
           '数据流向：')

    heading(doc, '2.6 功能六：智能排座', 2)
    para(doc, '根据学生身高与教室座位布局（排数 × 每排人数）自动生成座位表，'
              '并支持手动微调。该功能为确定性算法，不消耗 AI 调用。')
    bullet(doc, '身高升序排序 → 蛇形填充（保证同排左右相邻身高差最小）→ '
                '逐列前后排矫正（前排不高于后排）迭代至稳定。', '优化贪心算法：')
    bullet(doc, '可单独指定讲台两侧的两个座位，由最矮的两名学生就座。', '特殊座位：')
    bullet(doc, '点击任意两个座位即可互换学生，再次点击同一座位取消选中。', '手动互换：')
    bullet(doc, '支持复制为表格、导出 Word、保存到历史记录。', '结果输出：')

    heading(doc, '2.7 功能七：家校沟通话术与个性化学情报告', 2)
    para(doc, '针对家校沟通场景提供两类 AI 辅助：面向沟通困难的应对话术，'
              '以及面向家长的学生个性化报告。')

    heading(doc, '2.7.1 沟通话术建议', 3)
    bullet(doc, '学习退步沟通、课堂表现反馈、作业问题沟通、考试后安抚、家长会发言。',
           '预置场景：')
    bullet(doc, '温和沟通、正式规范、激励引导。', '三种语气：')
    bullet(doc, '开场、话术版本 A/B/C（各 80–150 字）、避坑提示（3–5 条）。', '输出结构：')
    bullet(doc, '家校合作立场；多事实少评价；尊重家长与孩子；引导后续行动。', '立场约束：')

    heading(doc, '2.7.2 个性化学情报告', 3)
    para(doc, '面向家长生成单个学生的学情报告，包含成绩概况、优势表现、薄弱环节、'
              '原因分析、家校配合建议、下一步计划六个部分。语言要求温暖有建设性，'
              '描述薄弱环节时“温和不贴标签”，仅依据所给数据，避免伤害学生与家长情感。')

    # ============================ 三、多语言 ============================
    heading(doc, '三、多语言适配与民族地区教学支持', 1)
    para(doc, '软件原生支持五种界面语言，并在文字排版层面为少数民族语言做了专门处理，'
              '使民族地区教师可以直接使用本民族语言文字进行操作，无需依赖汉语界面。')

    heading(doc, '3.1 支持语言', 2)
    make_table(doc,
               ['语言', '代码', '界面文本条数', '专用字体'],
               [
                   ['简体中文', 'zh', '372', '系统默认中文字体'],
                   ['English', 'en', '372', '系统默认西文字体'],
                   ['维吾尔语（ئۇيغۇرچە）', 'ug', '372', 'UKIJMejT.ttf'],
                   ['藏语（བོད་སྐད།）', 'bo', '372', 'ctrc-uchen.ttf'],
                   ['蒙古语（ᠮᠣᠩᠭᠣᠯ ᠬᠡᠯᠡ）', 'mn', '372', '蒙古文专用字体'],
               ],
               widths=[4.6, 1.6, 3.2, 5.6])
    para(doc, '五种语言的界面文本条数完全一致（各 372 条，逐键对齐），'
              '不存在“某种语言缺条目导致显示为中文”的情况。', size=11)

    heading(doc, '3.2 语言切换机制', 2)
    bullet(doc, '首次启动时自动跟随系统语言；用户一旦在设置页手动选定语言，'
                '此后即固定使用所选语言。', '跟随系统：')
    bullet(doc, '切换语言后界面文案即时刷新，无需重启应用。', '即时生效：')
    bullet(doc, '语言选择项以各语言自身文字书写（如 ئۇيغۇرچە、བོད་སྐད།、ᠮᠣᠩᠭᠣᠯ ᠬᠡᠯᠡ），'
                '不随当前界面语言变化，便于不识汉语的用户找到自己的语言。', '语言自名：')

    heading(doc, '3.3 少数民族文字的排版支持', 2)
    para(doc, '维吾尔语、藏语、蒙古语的文字形态与汉语差异很大，软件针对性做了以下处理：')
    bullet(doc, '按当前语言自动切换字体族：维吾尔语用 UKIJMejT、藏语用 ctrc-uchen、'
                '蒙古语用专用字体，避免出现方框或乱码。', '字体随语言切换：')
    bullet(doc, '蒙古文为传统竖排书写，软件提供专门的竖排文本组件'
                '（VerticalMongolianText），标题、正文说明、免责声明等均采用竖排渲染，'
                '符合蒙古文阅读习惯。', '蒙古文竖排：')
    bullet(doc, '维吾尔语为自右向左书写，软件对文本对齐与布局方向做了适配处理，'
                '保证阅读顺序正确。', '从右向左排版：')
    bullet(doc, '内置字体随应用一同分发，不依赖设备预装字体，'
                '在未预装少数民族字体的设备上同样可以正常显示。', '字体内置：')

    heading(doc, '3.4 AI 生成内容的多语言输出', 2)
    para(doc, '多语言不仅作用于界面文字，也覆盖 AI 生成的内容本身。'
              '系统提示词中包含统一的“输出语言”约束（Prompts.ets 中的 langRule），'
              '要求整篇内容一律使用当前界面语言撰写，仅专有名词、公式与 JSON 键名保持英文，'
              '且不得混用其它语言。')
    para(doc, '因此，教师把界面切换为维吾尔语后，生成的教案、练习、报告等正文内容'
              '同样以维吾尔语输出，可直接用于民族语言授课场景。'
              '课件大纲等结构化输出虽然内容按当前语言生成，但字段键名'
              '（page/type/title/points/visual）始终保持英文不变，'
              '以保证程序仍能正确解析与导出 PPTX。')
    bullet(doc, '界面文字、AI 生成正文、导出文档（Word/PPTX）三处语言保持一致，'
                '导出时会标注文本语言，保证换行与字体正确。', '三处一致：')

    heading(doc, '3.5 对民族地区教学的实际价值', 2)
    bullet(doc, '民族地区教师可用本民族语言操作软件并生成教案，'
                '降低工具使用门槛，避免因语言障碍放弃信息化备课手段。', '降低使用门槛：')
    bullet(doc, '在民族语言授课班级，教师可直接获得本民族语言的教案与练习，'
                '无需先以汉语生成再人工翻译，节省大量时间。', '直接产出可用材料：')
    bullet(doc, '同一份教案可在汉语班与民族语言班之间切换语言重新生成，'
                '便于开展双语教学与民族团结教育。', '支持双语教学：')
    bullet(doc, '蒙古文竖排、维吾尔文右起等排版细节均按民族文字习惯处理，'
                '生成材料可直接打印使用，符合民族地区教学材料的规范要求。', '符合书写习惯：')

    # ============================ 四、设计决策（重写） ============================
    heading(doc, '四、关键设计决策与理由', 1)
    para(doc, '本章说明软件在若干关键问题上为什么这样设计。'
              '每个决策都针对初中教师备课场景下的具体约束，'
              '并在实现中形成了对应的技术取舍。')

    heading(doc, '4.1 为什么把 AI 任务放到服务端后台执行', 2)
    para(doc, '问题：教案、课件大纲等长文本生成通常需要数十秒到数分钟。'
              '若在客户端同步等待，教师一旦切到其它应用、接听电话或锁屏，'
              '生成就会中断，需从头再来，等待时间被重复消耗。')
    para(doc, '决策：采用“提交后台任务 + 流式回传 + 轮询兜底”的模式。'
              '客户端提交任务后立即返回任务编号，生成由服务端继续执行；'
              '教师可离开页面甚至关闭应用，回来后结果仍在。')
    bullet(doc, '采用 SSE（Server-Sent Events）而非 WebSocket。理由是本场景的数据流'
                '是**单向**的——只需服务端把生成增量推给客户端，客户端不需要在同一连接上'
                '持续发送数据。SSE 基于普通 HTTP、无需握手升级与心跳保活协议，'
                '在移动网络切换、代理转发场景下更易穿透，实现与排障成本都更低。',
           '为什么选 SSE 而不是 WebSocket：')
    bullet(doc, 'SSE 依赖一条长连接，移动网络下断线不可避免。'
                '因此保留轮询作为兜底：一旦流式连接断开或 30 秒无数据，'
                '自动转为按任务编号轮询查询结果，保证在任何网络条件下都能拿到最终内容，'
                '不会出现“一直转圈但永远没结果”。', '为什么还要保留轮询：')
    bullet(doc, '任务在服务端完成的结果会写入客户端本地历史记录。'
                '即使应用进程被系统回收，下次启动时也会静默取回并入库，'
                '教师不会丢失已生成的成果。', '为什么能在杀进程后恢复：')

    heading(doc, '4.2 为什么使用服务端代理而不是客户端直连大模型', 2)
    para(doc, '问题：若由客户端直接调用大模型接口，API Key 必须随安装包分发。'
              '安装包一旦被解包，密钥即泄露，可能被盗用产生费用。')
    para(doc, '决策：客户端不持有任何密钥，统一请求自建代理服务，'
              '由服务端在环境变量中保存密钥并注入鉴权头。')
    bullet(doc, '安装包内不含密钥明文，反编译也无法取得；密钥可在服务端随时轮换而无需'
                '重新发布应用。', '密钥不出服务端：')
    bullet(doc, '代理层统一承载新课标检索、任务队列、限流与超时控制，'
                '客户端保持轻量，后续调整策略无需发版。', '策略集中可控：')
    bullet(doc, '服务端可配置共享令牌防止被他人当作免费代理滥用，'
                '并可配合 HTTPS 反向代理保护传输内容。', '防滥用：')

    heading(doc, '4.3 为什么选择“模板 + 结构化输出”而非让模型直接排版', 2)
    para(doc, '问题：若让模型直接输出 Word 或 PPT 的完整文件，'
              '其版式、字体、配色会随每次生成而漂移，同一课题两次生成的课件风格不一致；'
              '模型也容易产出不符合 OOXML 规范的字节，导致文件打不开或提示“需要修复”。')
    para(doc, '决策：把“内容”和“版式”分离。模型只负责结构化内容，'
              '版式由客户端确定性装配。')
    bullet(doc, '课件输出为逐页结构化片段，每页严格含 type/title/notes/body 四字段；'
                '客户端以内置单页模板逐页展开，生成风格统一、必定合规的 PPTX。'
                '同一课题多次生成，排版完全一致。', '课件（PPTX）：')
    bullet(doc, '要求模型输出受限的富文本标签集（标题、段落、加粗、斜体、下划线、'
                '颜色），并明确禁止 Markdown 与表格、代码块等复杂标签。'
                '这样既能保留必要的强调效果，又能被渲染组件与导出器稳定处理。',
           '正文富文本：')
    bullet(doc, '课件大纲除 PPTX 外还支持导出 JSON，字段键名固定为英文，'
                '便于教师在其它课件工具或脚本中二次加工，不被本应用锁定。',
           '开放性：')

    heading(doc, '4.4 为什么把课标原文检索后注入提示词', 2)
    para(doc, '问题：大模型可能凭记忆引用课程标准条文，出现条文编号或原文不准确的情况；'
              '而教学设计又确实需要“有据可依”，才能经得起教研审核。')
    para(doc, '决策：在服务端离线构建新课标索引，生成教学设计类内容时检索相关课标原文，'
              '以“课标依据”块注入提示词，让模型基于给定原文而非记忆作答。')
    bullet(doc, '索引来自 14 份《义务教育课程方案和课程标准（2022 年版）》，'
                '共 1428 个条目块，覆盖 13 个学科课标与课程方案。', '数据来源：')
    bullet(doc, '采用零外部依赖的纯内存 BM25 检索，部署简单、无额外服务，'
                '单机即可支撑，适合赛事与校级部署场景。', '为什么用 BM25 而非向量检索：')
    bullet(doc, '并非所有请求都注入课标。仅教学设计类任务注入学科课标；'
                '学科只是被顺带提及时不注入；对课标库中尚未收录的学科，'
                '软件**不套用其它学科条文**，而是明确告知并硬性禁止编造课标内容。'
                '这一闸门避免了“串学科”与“虚构条文”两类错误。', '注入闸门：')

    heading(doc, '4.5 为什么数据默认保存在本地而不是云同步', 2)
    para(doc, '问题：班级名单、学生成绩、家长沟通记录属敏感信息。'
              '若无必要地上传云端，一旦泄露会直接影响学生与家长；'
              '同时教师也常在不稳定网络环境下备课。')
    para(doc, '决策：班级名单、成绩、历史记录一律保存在设备本地，应用不提供云同步。')
    bullet(doc, '学生信息不出设备，从设计上消除集中泄露风险，'
                '也更容易通过学校与家长的数据安全审查。', '隐私优先：')
    bullet(doc, '无网络时仍可查看历史教案、管理名单、排座位表，'
                '仅 AI 生成功能需要联网。', '离线可用：')
    bullet(doc, '本地数据以结构化文本保存，不依赖外部数据库，'
                '教师可通过导出功能自行备份成果。', '可控可导出：')

    heading(doc, '4.6 为什么统一标注“AI 生成”并设置免责声明', 2)
    para(doc, '问题：AI 生成内容可能存在事实性错误或不适合具体班级的表述。'
              '若教师直接使用而未加审校，责任边界不清。')
    para(doc, '决策：所有 AI 生成内容在服务层统一追加“（AI生成，仅供参考）”标注'
              '（唯一例外是需要机器解析的课件 JSON）；首次启动时弹出免责声明，'
              '需阅读 5 秒后方可同意，不同意则退出应用。')
    bullet(doc, '标注在服务层自动追加而非依赖各页面自行处理，'
                '避免新增功能时遗漏。', '统一而非分散：')
    bullet(doc, '提示教师对内容负有最终审核责任，'
                '同时明确软件定位为“辅助备课工具”而非“替代教师”。', '责任清晰：')

    # ============================ 五、运行环境（扩写） ============================
    heading(doc, '五、运行环境', 1)
    para(doc, '本章列出各端的版本要求、资源占用与部署条件，供安装与验收参考。')

    heading(doc, '5.1 客户端运行环境', 2)
    make_table(doc,
               ['项目', '要求'],
               [
                   ['支持平台', 'HarmonyOS 手机 / 平板 / 2in1（笔记本形态）/ 穿戴设备；'
                    '另可经 ArkUI-X 产出 Android 版本，经 Electron 产出 Windows 桌面版'],
                   ['鸿蒙 SDK 版本', '编译与目标 SDK：6.0.0(20)；hvigor 构建模型版本 26.0.0'],
                   ['开发工具', 'DevEco Studio（含 HarmonyOS SDK 与 hvigor 构建链）'],
                   ['构建依赖', 'ohpm 安装 @archermind/exceljs（^1.0.0）、@ohos/jszip（^1.0.1）'],
                   ['安装包体积', '签名的 HAP 约 11.6 MB'],
                   ['运行时存储占用', '安装后约 12–20 MB；历史记录上限 50 条，'
                    '另含每页结果草稿文件'],
                   ['网络要求', '仅 AI 生成功能需要联网（访问自建代理服务）；'
                    '历史查看、名单管理、排座等可离线使用'],
                   ['权限要求', '网络访问、麦克风（语音转备注）、震动（手表上课提醒）、'
                    '分布式数据同步（结果流转）'],
               ],
               widths=[3.4, 11.6])

    heading(doc, '5.2 服务端运行环境', 2)
    para(doc, '服务端为大模型访问代理，同时承担新课标检索与后台任务队列。'
              '若仅使用离线功能（历史、名单、排座），可不部署服务端。')
    make_table(doc,
               ['项目', '要求'],
               [
                   ['运行时', 'Node.js 18 及以上'],
                   ['依赖组件', '仅 3 个运行时依赖：Express 4（Web 框架）、cors（跨域）、'
                    'dotenv（环境变量），体量极小'],
                   ['外部数据库', '无需数据库。任务与设备信息以 JSON 文件落盘保存'],
                   ['磁盘占用', '程序源码约 0.1 MB（依赖部署时安装）；'
                    '新课标索引（rag/）约 3.1 MB；'
                    '运行期任务数据随使用量增长，建议定期清理 data/ 目录'],
                   ['内存占用', '常驻约 100–200 MB（课标索引全量载入内存以加速检索）'],
                   ['必需配置项', 'DEEPSEEK_API_KEY（大模型密钥）；'
                    '强烈建议同时设置 PROXY_TOKEN（防滥用共享令牌）'],
                   ['网络要求', '需可访问大模型上游接口；对外需放行服务端口'],
                   ['HTTPS', '建议经 Nginx/Caddy 配置 HTTPS 反向代理，避免明文传输'],
               ],
               widths=[3.4, 11.6])

    heading(doc, '5.3 部署方式', 2)
    bullet(doc, '适用于有云服务器的场景，支持 Docker Compose 一键部署，'
                '或按手册手动部署（含证书与端口配置说明）。', '服务端：')
    bullet(doc, '使用 PM2 或 systemd 保持进程常驻，服务器重启后自动拉起。',
           '进程守护：')
    bullet(doc, '注意 Docker 与 PM2 两种方式二选一，不要同时运行，'
                '以免端口冲突。', '注意事项：')

    heading(doc, '5.4 构建产物', 2)
    make_table(doc,
               ['端', '产物', '说明'],
               [
                   ['鸿蒙', 'entry-default-signed.hap',
                    '经 hvigor assembleHap 构建并自动签名，可安装到真机'],
                   ['Android', 'APK 安装包', '经 ArkUI-X 交叉构建产出'],
                   ['Windows', 'NSIS 安装包', '经 electron-builder 打包，含桌面与开始菜单快捷方式'],
                   ['服务端', 'Node 应用目录', '可直接运行，或以容器镜像方式部署'],
               ],
               widths=[2.6, 5.0, 7.4])

    # ============================ 六、结语 ============================
    heading(doc, '六、结语', 1)
    para(doc, 'Agent备课 V1.0 以教师真实工作场景为出发点，把大模型能力封装为'
              '“填空即用”的教学工具，覆盖备课、命题、教研、学情、排座、家校沟通等'
              '日常事务。软件在提供便利的同时，通过统一的责任标注、免责声明与'
              '本地化数据存储，明确了 AI 辅助与教师主导之间的边界。')
    para(doc, '在语言层面，软件对汉语与维吾尔语、藏语、蒙古语提供同等完整的支持，'
              '并将多语言能力从界面文字延伸到 AI 生成正文与导出文档，'
              '为民族地区的双语教学与信息化备课提供了切实可用的工具支撑。')

    doc.save(OUT)
    print('saved:', OUT)
    print('size : %.1f KB' % (os.path.getsize(OUT) / 1024))


if __name__ == '__main__':
    build()
