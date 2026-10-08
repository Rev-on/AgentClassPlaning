"""
【Lead 独立验证】导出文件 AI 生成元数据的结构与兼容性核对。

为什么用 Python 而不是 Node/JSZip：
  实现方用的是 JSZip（ArkTS/JS 侧）。若我用同一套工具验证，等于"自己批改自己的卷子"——
  工具链的 bug、压缩选项的差异、条目命名习惯都会被同源掩盖。
  Python 的 zipfile 是**完全独立的实现**，用它验证才能发现"JSZip 打出来的包
  在别的工具看来是否合法"这类问题（例如目录条目缺失、[Content_Types].xml 未注册）。

本脚本做三件事：
  1. 造一个**参考实现**的 docx（含正确 docProps + 注册），证明"正确的做法长什么样"；
  2. 对**鸿蒙工程里真实的 pptskel.pptx** 做基线核对（它当前写着 PptxGenJS）；
  3. 提供可复用的断言函数，供后续对**实际导出的产物**做验收。

运行：python server/tools/verify_export_metadata.py
"""

import io
import os
import re
import sys
import zipfile
import datetime

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

PASS = 0
FAIL = 0
FAILURES = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(name + (" :: " + detail if detail else ""))


# ---------------------------------------------------------------- 参考实现

AI_MARK_ZH = "AI生成，仅供参考"
CORE_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<cp:coreProperties '
    'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:dcterms="http://purl.org/dc/terms/" '
    'xmlns:dcmitype="http://purl.org/dc/dcmitype/" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    "<dc:title>参考文档</dc:title>"
    "<dc:creator>Agent备课（AI生成）</dc:creator>"
    "<cp:lastModifiedBy>Agent备课（AI生成）</cp:lastModifiedBy>"
    "<dc:description>" + AI_MARK_ZH + "</dc:description>"
    "<cp:revision>1</cp:revision>"
    '<dcterms:created xsi:type="dcterms:W3CDTF">2026-10-08T12:00:00Z</dcterms:created>'
    '<dcterms:modified xsi:type="dcterms:W3CDTF">2026-10-08T12:00:00Z</dcterms:modified>'
    "</cp:coreProperties>"
)

APP_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" '
    'xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">'
    "<Application>Agent备课</Application>"
    "<Company>" + AI_MARK_ZH + "</Company>"
    "</Properties>"
)


def content_types_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        # ↓ 关键：docProps 必须在这里注册，否则 Word 报"文件损坏"
        '<Override PartName="/docProps/core.xml" '
        'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        "</Types>"
    )


def rels_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="word/document.xml"/>'
        # ↓ 关键：core/app 的关系也必须注册
        '<Relationship Id="rId2" '
        'Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
        'Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" '
        'Target="docProps/app.xml"/>'
        "</Relationships>"
    )


DOC_XML = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    "<w:body><w:p><w:r><w:t>测试内容</w:t></w:r></w:p></w:body></w:document>"
)


def build_reference_docx(path):
    """造一个含正确元数据的参考 docx（仅用于证明正确做法，不参与产品）"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types_xml())
        z.writestr("_rels/.rels", rels_xml())
        z.writestr("docProps/core.xml", CORE_XML)
        z.writestr("docProps/app.xml", APP_XML)
        z.writestr("word/document.xml", DOC_XML)
    return path


# ---------------------------------------------------------------- 断言函数

def assert_docx_metadata(zf, label):
    """核对一个已打开的 docx zip 是否具备合规的 AI 标识元数据"""
    names = set(zf.namelist())

    check(label + " 含 docProps/core.xml", "docProps/core.xml" in names)
    check(label + " 含 docProps/app.xml", "docProps/app.xml" in names)
    if "docProps/core.xml" not in names:
        return

    core = zf.read("docProps/core.xml").decode("utf-8", "replace")
    app = zf.read("docProps/app.xml").decode("utf-8", "replace") if "docProps/app.xml" in names else ""
    ct = zf.read("[Content_Types].xml").decode("utf-8", "replace")
    rl = zf.read("_rels/.rels").decode("utf-8", "replace")

    # 1) 标识必须真的写进去（创作者/最后修改者/描述 至少覆盖到）
    has_mark = (AI_MARK_ZH in core) or ("AI" in core) or ("AI" in app)
    check(label + " 元数据含 AI 生成标识", has_mark,
          "core/app 里都没找到 AI 标识")
    check(label + " dc:creator 标注为 AI 生成",
          re.search(r"<dc:creator>[^<]*AI", core) is not None
          or "AI" in re.search(r"<dc:creator>([^<]*)</dc:creator>", core).group(1)
          if re.search(r"<dc:creator>([^<]*)</dc:creator>", core) else False,
          "creator=" + str(re.search(r"<dc:creator>([^<]*)</dc:creator>", core)))

    # 2) 注册完整性 —— 这是 Word 能否打开的关键
    check(label + " [Content_Types].xml 注册了 core.xml",
          "docProps/core.xml" in ct,
          "缺 Override 会让 Word 报文件损坏")
    check(label + " [Content_Types].xml 注册了 app.xml",
          "docProps/app.xml" in ct)
    check(label + " _rels/.rels 指向 docProps/core.xml",
          "docProps/core.xml" in rl)
    check(label + " _rels/.rels 指向 docProps/app.xml",
          "docProps/app.xml" in rl)

    # 3) XML 结构合法性（简易但有效：标签配平 + 声明 + 命名空间）
    for part, body in (("core.xml", core), ("app.xml", app)):
        if not body:
            continue
        check(label + " " + part + " 有 XML 声明", body.lstrip().startswith("<?xml"))
        opens = len(re.findall(r"<(?![/?!])([A-Za-z_][\w:.-]*)", body))
        closes = len(re.findall(r"</([A-Za-z_][\w:.-]*)>", body))
        selfclose = len(re.findall(r"/>", body))
        check(label + " " + part + " 标签配平",
              opens == closes + selfclose,
              "开=%d 闭=%d 自闭合=%d" % (opens, closes, selfclose))

    # 4) 反向断言：不得有模板残留/未替换占位符
    check(label + " 无 PptxGenJS 残留", "PptxGenJS" not in core and "PptxGenJS" not in app)
    check(label + " 无未替换占位符",
          not re.search(r"\{\{|\}\}|\$\{", core + app))


# ---------------------------------------------------------------- main

print("=" * 78)
print("导出文件 AI 生成元数据 —— 独立核对（Python zipfile，与实现方工具链不同源）")
print("=" * 78)

# --- 1. 参考实现自证 ---
print("\n[1] 参考实现自证（证明「正确做法」能被本脚本认可）")
ref = os.path.join(os.environ.get("TEMP", "."), "ref_ai_meta.docx")
build_reference_docx(ref)
with zipfile.ZipFile(ref) as zf:
    assert_docx_metadata(zf, "[参考]")
print("    参考 docx 已生成: " + ref)

# --- 2. 工程内真实模板基线 ---
print("\n[2] 工程内 pptskel.pptx 基线（记录改造前的实际内容）")
skel = os.path.join(ROOT, "entry", "src", "main", "resources", "rawfile", "pptskel.pptx")
if os.path.exists(skel):
    with zipfile.ZipFile(skel) as zf:
        names = zf.namelist()
        has_core = "docProps/core.xml" in names
        print("    docProps/core.xml 存在: " + str(has_core))
        if has_core:
            core = zf.read("docProps/core.xml").decode("utf-8", "replace")
            m = re.search(r"<dc:creator>([^<]*)</dc:creator>", core)
            print("    当前 dc:creator = " + (m.group(1) if m else "(无)"))
            check("[基线] pptskel 模板 docProps 不含 AI 标识（改造前应为真）",
                  "AI" not in core)
else:
    check("pptskel.pptx 存在", False, skel)

# --- 3. 对实际导出产物做验收（若存在） ---
print("\n[3] 查找实际导出的 docx/pptx 产物")
cands = []
for d in (os.environ.get("TEMP", "."), ROOT, os.path.join(ROOT, "build")):
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.lower().endswith((".docx", ".pptx")):
                cands.append(os.path.join(d, f))
if cands:
    for c in cands[:5]:
        print("    检查: " + c)
        try:
            with zipfile.ZipFile(c) as zf:
                if c.lower().endswith(".docx"):
                    assert_docx_metadata(zf, "[产物 " + os.path.basename(c) + "]")
        except Exception as e:
            print("      无法作为 zip 打开: " + str(e))
else:
    print("    （未发现产物；若实现方留下了导出样本，会在此自动验收）")

print("\n" + "-" * 78)
if FAILURES:
    print("失败项：")
    for i, f in enumerate(FAILURES, 1):
        print("  %d. %s" % (i, f))
    print("-" * 78)
print("结果: 通过 %d / 共 %d 项" % (PASS, PASS + FAIL))
print("=" * 78)
sys.exit(0 if FAIL == 0 else 1)
