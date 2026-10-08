"""
【Lead 独立验收】对实现方产出的真实 docx/pptx 做元数据核对。

与实现方工具链完全不同源：实现方用 JSZip（JS），本脚本用 Python zipfile + minidom。
目的：证明"产物里真的有 AI 生成标识，且包结构合法"，而不是只信任实现方的自述。

运行：python server/tools/lead_audit_export_artifacts.py
"""
import os
import re
import sys
import zipfile
import xml.dom.minidom

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "server", "tools", "out")

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


def text_of(zf, name):
    try:
        return zf.read(name).decode("utf-8", "replace")
    except KeyError:
        return ""


def audit(path, label, expect_pptx):
    print("\n" + "=" * 74)
    print("%s  %s (%d bytes)" % (label, os.path.basename(path), os.path.getsize(path)))
    print("=" * 74)

    if not os.path.exists(path):
        check(label + " 产物存在", False, path)
        return

    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        print("  条目数: %d" % len(names))

        # --- 1. ZIP 完整性 ---
        bad = zf.testzip()
        check(label + " ZIP 无坏条目（testzip）", bad is None, "坏条目: %s" % bad)

        # --- 2. docProps 部件存在 ---
        has_core = "docProps/core.xml" in names
        has_app = "docProps/app.xml" in names
        check(label + " 含 docProps/core.xml", has_core)
        check(label + " 含 docProps/app.xml", has_app)
        if not has_core:
            return

        core = text_of(zf, "docProps/core.xml")
        app = text_of(zf, "docProps/app.xml")
        ct = text_of(zf, "[Content_Types].xml")
        rl = text_of(zf, "_rels/.rels")

        # --- 3. 四个 XML 部件能被真解析器解析（不是正则） ---
        for part in ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "docProps/app.xml"]:
            body = text_of(zf, part)
            if not body:
                check(label + " " + part + " 存在", False)
                continue
            try:
                xml.dom.minidom.parseString(body)
                check(label + " " + part + " 可被 minidom 解析", True)
            except Exception as e:
                check(label + " " + part + " 可被 minidom 解析", False, str(e)[:120])

        # --- 4. AI 标识真实存在 ---
        has_zh = "AI 生成" in core or "AI 生成" in app or "AI生成" in core or "AI生成" in app
        check(label + " 元数据含中文 AI 标识", has_zh,
              "core/app 都没有「AI 生成」")
        creator = re.search(r"<dc:creator>([^<]*)</dc:creator>", core)
        cv = creator.group(1) if creator else ""
        check(label + " dc:creator 体现 AI 生成", "AI" in cv, "creator=%r" % cv)
        print("  dc:creator      = %s" % cv)

        for tag in ["dc:title", "dc:description", "cp:contentStatus", "cp:category"]:
            m = re.search(r"<" + tag + r"[^>]*>([^<]*)</" + tag + ">", core)
            print("  %-16s= %s" % (tag, m.group(1) if m else "(无)"))

        app_m = re.search(r"<Application>([^<]*)</Application>", app)
        comp_m = re.search(r"<Company>([^<]*)</Company>", app)
        print("  app.Application = %s" % (app_m.group(1) if app_m else "(无)"))
        print("  app.Company     = %s" % (comp_m.group(1) if comp_m else "(无)"))
        check(label + " app.xml 含 AI 标识",
              (app_m and "AI" in app_m.group(1)) or (comp_m and "AI" in comp_m.group(1)) or has_zh,
              "app.Application/Company 均无 AI")

        # --- 5. 三个注册点（Word 能否打开的硬要求） ---
        check(label + " [Content_Types].xml 注册 core.xml", "docProps/core.xml" in ct)
        check(label + " [Content_Types].xml 注册 app.xml", "docProps/app.xml" in ct)
        check(label + " _rels/.rels 指向 core.xml", "docProps/core.xml" in rl)
        check(label + " _rels/.rels 指向 app.xml", "docProps/app.xml" in rl)

        # 关系类型命名空间是否正确（core 用 package 前缀，app 用 officeDocument 前缀）
        check(label + " core 关系用 package 命名空间",
              "package/2006/relationships/metadata/core-properties" in rl)
        check(label + " app 关系用 officeDocument 命名空间",
              "officeDocument/2006/relationships/extended-properties" in rl)

        # --- 6. 无重复 Override / 重复 Id（非法包） ---
        overrides = re.findall(r'PartName="([^"]+)"', ct)
        check(label + " Content_Types 无重复 PartName",
              len(overrides) == len(set(overrides)),
              "重复: %s" % [p for p in set(overrides) if overrides.count(p) > 1])
        ids = re.findall(r'Id="([^"]+)"', rl)
        check(label + " .rels 无重复 Id",
              len(ids) == len(set(ids)),
              "重复: %s" % [i for i in set(ids) if ids.count(i) > 1])

        # --- 7. 反向断言：模板残留 / 占位符 ---
        allxml = core + app + ct + rl
        check(label + " 全包无 PptxGenJS 残留", "PptxGenJS" not in allxml)
        check(label + " 全包无未替换占位符",
              not re.search(r"\{\{|\}\}|\$\{", allxml))

        # --- 8. 时间戳格式（W3CDTF，无毫秒） ---
        stamps = re.findall(r"<dcterms:(?:created|modified)[^>]*>([^<]+)<", core)
        check(label + " 有 dcterms 时间戳", len(stamps) >= 1)
        for s in stamps:
            check(label + " 时间戳为 W3CDTF 无毫秒: " + s,
                  re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", s) is not None)
        check(label + " dcterms 带 xsi:type=W3CDTF",
              'xsi:type="dcterms:W3CDTF"' in core)

        # --- 9. 正文部件仍在（没把包弄坏） ---
        if expect_pptx:
            slides = [n for n in names if re.match(r"ppt/slides/slide\d+\.xml$", n)]
            check(label + " 含 ppt/slides/*.xml", len(slides) >= 1, "slides=%s" % slides)
            print("  slides: %s" % ", ".join(sorted(slides)))
            # 模板的其它部件应当保留
            check(label + " 保留了 ppt/presentation.xml", "ppt/presentation.xml" in names)
            check(label + " 保留了主题部件", any(n.startswith("ppt/theme/") for n in names))
        else:
            check(label + " 含 word/document.xml", "word/document.xml" in names)
            check(label + " 含 _rels/.rels", "_rels/.rels" in names)


print("=" * 74)
print("Lead 独立验收：导出产物 AI 生成元数据（Python zipfile + minidom，异源）")
print("=" * 74)

audit(os.path.join(OUT, "ai-metadata-real.docx"), "[DOCX]", False)
audit(os.path.join(OUT, "ai-metadata-real.pptx"), "[PPTX]", True)

# 骨架基线对比：确认 pptx 的 core.xml 确实被覆盖（而非原样保留）
print("\n" + "=" * 74)
print("骨架基线对比：确认 pptx 元数据被覆盖（不是原样保留模板）")
print("=" * 74)
skel = os.path.join(ROOT, "entry", "src", "main", "resources", "rawfile", "pptskel.pptx")
prod = os.path.join(OUT, "ai-metadata-real.pptx")
if os.path.exists(skel) and os.path.exists(prod):
    with zipfile.ZipFile(skel) as z1, zipfile.ZipFile(prod) as z2:
        c1 = z1.read("docProps/core.xml").decode("utf-8")
        c2 = z2.read("docProps/core.xml").decode("utf-8")
        check("骨架 core.xml 与产物 core.xml 不同（确已覆盖）", c1 != c2)
        check("骨架含 PptxGenJS（改造前基线）", "PptxGenJS" in c1)
        check("产物不含 PptxGenJS", "PptxGenJS" not in c2)
        n1 = len(z1.namelist())
        n2 = len(z2.namelist())
        print("  骨架条目数 %d → 产物条目数 %d" % (n1, n2))
        check("产物条目数 >= 骨架（包结构未损）", n2 >= n1)

print("\n" + "-" * 74)
if FAILURES:
    print("失败项：")
    for i, f in enumerate(FAILURES, 1):
        print("  %d. %s" % (i, f))
    print("-" * 74)
print("结果: 通过 %d / 共 %d 项" % (PASS, PASS + FAIL))
print("=" * 74)
sys.exit(0 if FAIL == 0 else 1)
