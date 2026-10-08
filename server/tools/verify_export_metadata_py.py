"""
【工程师自验】用 Python zipfile 独立核对**真实导出产物**的元数据与包合法性。

为什么必须换工具链：
   实现用的是 JSZip（ArkTS / Electron 两侧）。若我也用 JSZip 解包验证，等于
   "自己批改自己的卷子" —— 压缩选项、条目命名、目录条目的差异会被同源掩盖。
   Python 的 zipfile 是**完全独立的实现**，并且这里额外用 xml.dom.minidom
   做**真正的 XML 解析**（而不是正则配平），能发现正则看不到的问题。

本脚本读 server/tools/out/ 下由 test_export_ai_metadata.js 产出的**真实文件**：
   · ai-metadata-real.docx / .pptx

核对点：
   1. zipfile 能打开（testzip() 无坏条目）
   2. docProps/core.xml 与 app.xml 存在
   3. [Content_Types].xml 有 docProps 的 Override
   4. _rels/.rels 有指向 docProps 的 Relationship
   5. 四个 XML 部件都能被 minidom **真正解析**（命名空间、标签配平、属性引号）
   6. core.xml 含「AI 生成」中文标识
   7. 反向：全包任何 XML 部件都不得含 "PptxGenJS"
   8. 反向：不得含未替换占位符
   9. W3CDTF 时间戳格式
  10. pptx 的 docProps 与模板骨架**不同**（证明确实被覆盖）

运行：python server/tools/verify_export_metadata_py.py
"""

import os
import re
import sys
import zipfile
import datetime
from xml.dom import minidom
from xml.parsers.expat import ExpatError

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "server", "tools", "out")
SKEL = os.path.join(ROOT, "entry", "src", "main", "resources", "rawfile", "pptskel.pptx")

passed = 0
failures = []


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
        print("  PASS  " + name)
    else:
        failures.append(name + (("  -> " + str(detail)) if detail else ""))
        print("  FAIL  " + name + (("  -> " + str(detail)) if detail else ""))


def read_xml(zf, name):
    """解出某部件文本；不存在返回 None"""
    try:
        return zf.read(name).decode("utf-8")
    except KeyError:
        return None


def parse_xml(text, label):
    """用 minidom 真正解析；成功返回 doc，失败返回 None 并打印原因"""
    try:
        return minidom.parseString(text.encode("utf-8"))
    except ExpatError as e:
        print("      ! {} XML 解析失败: {}".format(label, e))
        return None


print("=" * 78)
print("真实产物独立核对（Python zipfile + minidom，与 JSZip 不同源）")
print("=" * 78)

DOCX = os.path.join(OUT, "ai-metadata-real.docx")
PPTX = os.path.join(OUT, "ai-metadata-real.pptx")

if not os.path.exists(DOCX):
    print("✗ 找不到真实产物 {}，请先运行 node server/tools/test_export_ai_metadata.js".format(DOCX))
    sys.exit(1)

for label, path in (("docx", DOCX), ("pptx", PPTX)):
    print("\n" + "-" * 78)
    print("[{}] {}".format(label, path))
    print("-" * 78)

    if not os.path.exists(path):
        check(label + " 产物存在", False, path)
        continue

    zf = zipfile.ZipFile(path)
    names = zf.namelist()

    # 1. 包完整性：Python 独立实现能否无错读取
    bad = zf.testzip()
    check(label + ": zipfile.testzip() 无坏条目（独立实现可读）", bad is None, "坏条目: " + str(bad))

    # 2. 部件存在
    core = read_xml(zf, "docProps/core.xml")
    app = read_xml(zf, "docProps/app.xml")
    ct = read_xml(zf, "[Content_Types].xml")
    rels = read_xml(zf, "_rels/.rels")
    check(label + ": docProps/core.xml 存在", core is not None)
    check(label + ": docProps/app.xml 存在", app is not None)
    check(label + ": [Content_Types].xml 存在", ct is not None)
    check(label + ": _rels/.rels 存在", rels is not None)

    if core is None or app is None or ct is None or rels is None:
        continue

    # 3. 三个注册点
    check(label + ": [Content_Types].xml 注册了 core.xml 的 Override",
          'PartName="/docProps/core.xml"' in ct)
    check(label + ": [Content_Types].xml 注册了 app.xml 的 Override",
          'PartName="/docProps/app.xml"' in ct)
    check(label + ": [Content_Types].xml 内 PartName 无重复",
          len(re.findall(r'PartName="', ct)) == len(set(re.findall(r'PartName="([^"]+)"', ct))))
    check(label + ": _rels/.rels 有指向 docProps/core.xml 的 Relationship",
          re.search(r'<Relationship[^>]*Target="docProps/core\.xml"', rels) is not None)
    check(label + ": _rels/.rels 有指向 docProps/app.xml 的 Relationship",
          re.search(r'<Relationship[^>]*Target="docProps/app\.xml"', rels) is not None)
    check(label + ": _rels/.rels 内 Id 无重复",
          len(re.findall(r'Id="', rels)) == len(set(re.findall(r'Id="([^"]+)"', rels))))

    # 4. minidom 真解析（比正则配平更强的合法性证据）
    ok_core = parse_xml(core, label + " core.xml") is not None
    ok_app = parse_xml(app, label + " app.xml") is not None
    ok_ct = parse_xml(ct, label + " [Content_Types].xml") is not None
    ok_rels = parse_xml(rels, label + " _rels/.rels") is not None
    check(label + ": core.xml 可被 minidom 解析", ok_core)
    check(label + ": app.xml 可被 minidom 解析", ok_app)
    check(label + ": [Content_Types].xml 可被 minidom 解析", ok_ct)
    check(label + ": _rels/.rels 可被 minidom 解析", ok_rels)

    # 5. 标识内容
    check(label + ": core.xml 含中文「AI 生成」标识", "AI 生成" in core)
    creator = re.search(r"<dc:creator>([^<]*)</dc:creator>", core)
    check(label + ": dc:creator 含「AI 生成」",
          creator is not None and "AI 生成" in creator.group(1),
          creator.group(1) if creator else "缺 dc:creator")
    check(label + ": app.xml 含中文「AI 生成」标识", "AI 生成" in app)

    # 6. 时间戳
    ts = re.search(r'<dcterms:created[^>]*>([^<]*)</dcterms:created>', core)
    val = ts.group(1) if ts else ""
    check(label + ": dcterms:created 是 W3CDTF UTC",
          re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", val) is not None, val)
    try:
        datetime.datetime.strptime(val, "%Y-%m-%dT%H:%M:%SZ")
        check(label + ": dcterms:created 是真实可解析时间", True)
    except ValueError:
        check(label + ": dcterms:created 是真实可解析时间", False, val)

    # 7. 反向断言：全包任何 XML 部件不得有 PptxGenJS / 占位符
    offenders = []
    placeholder = []
    for n in names:
        if n.endswith(".xml") or n.endswith(".rels"):
            try:
                t = zf.read(n).decode("utf-8")
            except Exception:
                continue
            if "PptxGenJS" in t:
                offenders.append(n)
            if re.search(r"\{\{|\$\{|%s", t):
                placeholder.append(n)
    check(label + ": 全包无 PptxGenJS 残留", not offenders, ", ".join(offenders))
    check(label + ": 全包无未替换占位符", not placeholder, ", ".join(placeholder))

    # 8. 目录条目不应被计入"部件清单"断言，但也不应破坏包
    check(label + ": 包内条目数合理（>= 4）", len(names) >= 4, str(len(names)))

print("\n" + "-" * 78)
print("[pptx] 与模板骨架对比：docProps 必须已被覆盖")
print("-" * 78)
if os.path.exists(SKEL) and os.path.exists(PPTX):
    skel_core = zipfile.ZipFile(SKEL).read("docProps/core.xml").decode("utf-8")
    out_core = zipfile.ZipFile(PPTX).read("docProps/core.xml").decode("utf-8")
    check("骨架 core.xml 确实含 PptxGenJS（前置事实）", "PptxGenJS" in skel_core)
    check("产物 core.xml 已不含 PptxGenJS", "PptxGenJS" not in out_core)
    check("产物 core.xml 与骨架 core.xml 内容不同（确被覆盖）", skel_core != out_core)
    check("产物 core.xml 含 AI 生成标识", "AI 生成" in out_core)

print("\n" + "=" * 78)
if failures:
    print("失败项（{}）：".format(len(failures)))
    for i, f in enumerate(failures, 1):
        print("  {}. {}".format(i, f))
print("结果: 通过 {} / 共 {} 项".format(passed, passed + len(failures)))
print("=" * 78)
sys.exit(0 if not failures else 1)
