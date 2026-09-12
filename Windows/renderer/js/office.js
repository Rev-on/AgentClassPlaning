/* ============================================================
 * Rev TechingMaster Windows 版 · 文档引擎（纯前端，无 Node 依赖）
 *  - docxFromMarkdown  : 教案/报告/历史 → Word(.docx)
 *  - pptxFromCourseware: 课件大纲 JSON → PowerPoint(.pptx)，复用鸿蒙 pptskel.pptx 骨架
 *  - xlsxToRows        : 读取 Excel 首个工作表 → {sheetName, rows:string[][]}
 *  - docxToPlain       : 解析 Word 名单 → 纯文本
 * 依赖：window.JSZip（js/vendor/jszip.min.js）、window.rtmNative.skeleton()（骨架二进制）
 * ============================================================ */
window.RTM_OFFICE = (function () {
  'use strict';
  var JSZip = window.JSZip;

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function unesc(s) {
    return String(s == null ? '' : s)
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  }
  function sanitizeName(name) {
    return String(name == null ? '' : name).replace(/[\\/:*?"<>|\r\n]+/g, '_').slice(0, 80).replace(/\.(docx|pptx)$/i, '');
  }

  /* ============================================================
   * Markdown → OOXML（省略 styles.xml 的最小合法 docx）
   * ============================================================ */
  function inlineRuns(text) {
    if (!text) return '<w:r><w:t></w:t></w:r>';
    var out = '', last = 0, m;
    var re = /(\*\*[^*]+\*\*|`[^`]*`)/g;
    while ((m = re.exec(text)) !== null) {
      out += '<w:r><w:t>' + esc(text.slice(last, m.index)) + '</w:t></w:r>';
      var tok = m[0];
      if (tok.charCodeAt(0) === 96) { // backtick
        out += '<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/></w:rPr><w:t>' + esc(tok.slice(1, -1)) + '</w:t></w:r>';
      } else {
        out += '<w:r><w:rPr><w:b/></w:rPr><w:t>' + esc(tok.slice(2, -2)) + '</w:t></w:r>';
      }
      last = m.index + m[0].length;
    }
    out += '<w:r><w:t>' + esc(text.slice(last)) + '</w:t></w:r>';
    return out;
  }
  function para(text) {
    return '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>' + inlineRuns(text) + '</w:p>';
  }
  function heading(level, text) {
    var sz = level <= 2 ? 30 : level === 3 ? 28 : 24;
    return '<w:p><w:pPr><w:spacing w:before="200" w:after="120"/><w:outlineLvl w:val="' + (level - 1) + '"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="' + sz + '"/><w:szCs w:val="' + sz + '"/></w:rPr><w:t>' + esc(text) + '</w:t></w:r></w:p>';
  }
  function listItem(text) {
    return '<w:p><w:pPr><w:ind w:left="420"/><w:spacing w:line="320" w:lineRule="auto"/></w:pPr><w:r><w:t>\u2022 ' + esc(text) + '</w:t></w:r></w:p>';
  }
  function codeBlock(codeLines) {
    return '<w:p><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/></w:rPr><w:t>' + esc(codeLines.join('\n')) + '</w:t></w:r></w:p>';
  }
  function tableBlock(rows) {
    var x = [];
    x.push('<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>' +
      '<w:top w:val="single" w:sz="4" w:color="999999"/><w:left w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:bottom w:val="single" w:sz="4" w:color="999999"/><w:right w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:insideH w:val="single" w:sz="4" w:color="999999"/><w:insideV w:val="single" w:sz="4" w:color="999999"/>' +
      '</w:tblBorders></w:tblPr>');
    rows.forEach(function (row, ri) {
      x.push('<w:tr>');
      row.forEach(function (cell) {
        var shd = ri === 0 ? '<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="EDF2F9"/></w:tcPr>' : '';
        var bold = ri === 0 ? '<w:rPr><w:b/></w:rPr>' : '';
        x.push('<w:tc>' + shd + '<w:p><w:r>' + bold + '<w:t>' + esc(cell) + '</w:t></w:r></w:p></w:tc>');
      });
      x.push('</w:tr>');
    });
    x.push('</w:tbl><w:p/>');
    return x.join('');
  }

  function mdToParagraphs(md) {
    var out = [];
    var lines = String(md == null ? '' : md).split(/\r?\n/);
    var i = 0, inCode = false, codeBuf = [];
    while (i < lines.length) {
      var ln = lines[i], t = ln.trim();
      if (inCode) {
        if (/^```/.test(t)) { inCode = false; out.push(codeBlock(codeBuf)); codeBuf = []; }
        else { codeBuf.push(ln); }
        i++; continue;
      }
      if (/^```/.test(t)) { inCode = true; codeBuf = []; i++; continue; }
      if (/^\|/.test(t)) {
        var tbl = [];
        while (i < lines.length && /^\|/.test(lines[i].trim())) {
          var raw = lines[i].trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(function (s) { return s.trim(); });
          var isSep = raw.length > 0 && raw.every(function (c) { return /^:?-+:?$/.test(c); });
          if (!isSep) tbl.push(raw);
          i++;
        }
        if (tbl.length) out.push(tableBlock(tbl));
        continue;
      }
      var h = t.match(/^(#{1,6})\s+(.*)$/);
      if (h) { out.push(heading(parseInt(h[1], 10), h[2].replace(/^#+\s*/, ''))); i++; continue; }
      if (/^[-*]\s+/.test(t)) { out.push(listItem(t.replace(/^[-*]\s+/, ''))); i++; continue; }
      if (/^\d+[.、]\s+/.test(t)) { out.push(listItem(t.replace(/^\d+[.、]\s+/, ''))); i++; continue; }
      if (t === '') { i++; continue; }
      out.push(para(ln));
      i++;
    }
    if (inCode) out.push(codeBlock(codeBuf));
    return out;
  }

  function docxFromMarkdown(md, fileName) {
    var body = mdToParagraphs(md).join('\n');
    var documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
      body +
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>' +
      '</w:body></w:document>';
    var ct =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
      '</Types>';
    var rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
      '</Relationships>';
    var zip = new JSZip();
    zip.file('[Content_Types].xml', ct);
    zip.file('_rels/.rels', rels);
    zip.file('word/document.xml', documentXml);
    return zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE' }).then(function (buf) {
      return { name: sanitizeName(fileName) + '.docx', data: buf };
    });
  }

  /* ============================================================
   * 富文本编辑(HTML) → Word(.docx)：保留 粗/斜/下/删/颜色/代码
   * 供预览框生成后直接编辑再导出（DOM 遍历，原生安全解析）
   * ============================================================ */
  function richColor(el) {
    var style = String((el.getAttribute && el.getAttribute('style')) || '');
    var m = style.match(/color\s*:\s*(#[0-9a-fA-F]{3,8}|rgb\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\))/);
    if (!m) return '';
    var c = m[1];
    if (/^#/.test(c)) {
      var hex = c.slice(1);
      if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
      return hex.slice(0, 6).toUpperCase();
    }
    var nums = c.match(/\d+/g);
    if (nums && nums.length >= 3) {
      var n = ((+nums[0]) << 16) | ((+nums[1]) << 8) | (+nums[2]);
      var hx = n.toString(16);
      while (hx.length < 6) hx = '0' + hx;
      return hx.toUpperCase();
    }
    return '';
  }
  function richRun(pr, text) {
    return '<w:r>' + (pr ? '<w:rPr>' + pr + '</w:rPr>' : '') +
      '<w:t xml:space="preserve">' + esc(text || '') + '</w:t></w:r>';
  }
  function richNode(n) {
    if (n.nodeType === 3) return richRun('', n.textContent.replace(/\u00a0/g, ' '));
    if (n.nodeType !== 1) return '';
    var tag = n.tagName.toLowerCase();
    if (tag === 'br') return '<w:r><w:br/></w:r>';
    var pr = '';
    if (tag === 'strong' || tag === 'b') pr += '<w:b/>';
    if (tag === 'em' || tag === 'i') pr += '<w:i/>';
    if (tag === 'u') pr += '<w:u w:val="single"/>';
    if (tag === 'del' || tag === 's' || tag === 'strike') pr += '<w:strike/>';
    if (tag === 'code') pr += '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/>';
    var col = '';
    if (tag === 'span') { var sc = richColor(n); if (sc) col = '<w:color w:val="' + sc + '"/>'; }
    if (tag === 'font') {
      var fc = n.getAttribute && n.getAttribute('color');
      if (fc) { var hex = String(fc).replace('#', '').slice(0, 6).toUpperCase(); if (hex) col = '<w:color w:val="' + hex + '"/>'; }
    }
    if (!pr && !col) {
      var flat = '';
      for (var k = 0; k < n.childNodes.length; k++) flat += richNode(n.childNodes[k]);
      return flat;
    }
    // 带格式节点：整段作为一个 run，合并其全部 rPr（足够覆盖工具栏编辑的选区）
    return richRun(pr + col, n.textContent.replace(/\u00a0/g, ' '));
  }
  function richInline(n) {
    var out = '';
    for (var i = 0; i < n.childNodes.length; i++) out += richNode(n.childNodes[i]);
    return out;
  }
  function htmlTableBlock(tbl) {
    var x = '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>' +
      '<w:top w:val="single" w:sz="4" w:color="999999"/><w:left w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:bottom w:val="single" w:sz="4" w:color="999999"/><w:right w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:insideH w:val="single" w:sz="4" w:color="999999"/><w:insideV w:val="single" w:sz="4" w:color="999999"/>' +
      '</w:tblBorders></w:tblPr>';
    var rows = tbl.querySelectorAll('tr');
    for (var i = 0; i < rows.length; i++) {
      var cell = rows[i].children;
      x += '<w:tr>';
      for (var j = 0; j < cell.length; j++) {
        var ctag = cell[j].tagName.toLowerCase();
        if (ctag !== 'td' && ctag !== 'th') continue;
        var pr = ctag === 'th' ? '<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="EDF2F9"/></w:tcPr>' : '';
        x += '<w:tc>' + pr + '<w:p>' + richRun(ctag === 'th' ? '<w:b/>' : '', cell[j].textContent.trim()) + '</w:p></w:tc>';
      }
      x += '</w:tr>';
    }
    return x + '</w:tbl><w:p/>';
  }
  function htmlBodyBlocks(body) {
    var blocks = [];
    body.childNodes.forEach(function (n) {
      if (n.nodeType === 3) {
        var t = n.textContent.replace(/\s+/g, ' ').trim();
        if (t) blocks.push('<w:p>' + richRun('', t) + '</w:p>');
        return;
      }
      if (n.nodeType !== 1) return;
      var tag = n.tagName.toLowerCase();
      if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') {
        var lvl = parseInt(tag.charAt(1), 10);
        var sz = lvl <= 2 ? 30 : lvl === 3 ? 28 : lvl === 4 ? 26 : 24;
        blocks.push('<w:p><w:pPr><w:spacing w:before="200" w:after="120"/><w:outlineLvl w:val="' + (lvl - 1) + '"/></w:pPr>' +
          richRun('<w:b/><w:sz w:val="' + sz + '"/><w:szCs w:val="' + sz + '"/>', n.textContent) + '</w:p>');
        return;
      }
      if (tag === 'p') { blocks.push('<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>' + richInline(n) + '</w:p>'); return; }
      if (tag === 'ul' || tag === 'ol') {
        n.childNodes.forEach(function (li) {
          if (li.nodeType === 1 && li.tagName.toLowerCase() === 'li') {
            blocks.push('<w:p><w:pPr><w:ind w:left="420"/><w:spacing w:line="320" w:lineRule="auto"/></w:pPr>' +
              richRun('', '\u2022 ') + richInline(li) + '</w:p>');
          }
        });
        return;
      }
      if (tag === 'pre') {
        blocks.push('<w:p><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>' +
          richRun('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/>', n.textContent) + '</w:p>');
        return;
      }
      if (tag === 'table') { blocks.push(htmlTableBlock(n)); return; }
      blocks.push('<w:p>' + richInline(n) + '</w:p>');
    });
    return blocks;
  }
  function docxFromHtml(htmlText, fileName) {
    var doc = new DOMParser().parseFromString(htmlText, 'text/html');
    var body = doc.body || doc.documentElement;
    var bodyXml = htmlBodyBlocks(body).join('\n');
    var documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
      bodyXml +
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>' +
      '</w:body></w:document>';
    var ct =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
      '</Types>';
    var rels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
      '</Relationships>';
    var zip = new JSZip();
    zip.file('[Content_Types].xml', ct);
    zip.file('_rels/.rels', rels);
    zip.file('word/document.xml', documentXml);
    return zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE' }).then(function (buf) {
      return { name: sanitizeName(fileName) + '.docx', data: buf };
    });
  }

  /* ============================================================
   * 课件 JSON → PPTX（复用鸿蒙 pptskel.pptx 骨架）
   * JSON: { title, pages:[{title, points:[], notes?, suggestion?}] }
   * ============================================================ */
  var EMU_W = 12192000, EMU_H = 6858000;

  function pText(text, size, bold, color) {
    return '<a:p><a:r><a:rPr lang="zh-CN" altLang="en-US" sz="' + size + '" b="' + (bold ? 1 : 0) + '" dirty="0"><a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/></a:rPr><a:t>' + esc(text) + '</a:t></a:r></a:p>';
  }
  function pBullet(text, size, color) {
    var lines = String(text == null ? '' : text).split('\n');
    var x = '';
    lines.forEach(function (ln, idx) {
      x += '<a:p><a:pPr marL="342900" indent="-342900">' +
        '<a:buChar char="\u2022" type="bullet"/>' +
        '</a:pPr><a:r><a:rPr lang="zh-CN" altLang="en-US" sz="' + size + '" b="0" dirty="0"><a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/></a:rPr><a:t>' + esc(ln === '' ? ' ' : ln) + '</a:t></a:r></a:p>';
      void idx;
    });
    return x;
  }
  function titleSlideShapes(slide, total) {
    return '<p:sp><p:nvSpPr><p:cNvPr id="3" name="TitleBar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + EMU_W + '" cy="' + EMU_H + '"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="1F6FB2"/></a:solidFill></p:spPr>' +
      '<p:txBody><a:bodyPr anchor="ctr" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>' +
      pText(slide.title || '\u8bfe\u4ef6\u5927\u7eb2', 4400, 1, 'FFFFFF') +
      '</p:txBody></p:sp>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Sub"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="457200" y="5500000"/><a:ext cx="11277600" cy="800000"/></a:xfrm></p:spPr>' +
      '<p:txBody><a:bodyPr anchor="ctr" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>' +
      pText('\u521d\u4e2d\u6559\u5b66\u00b7\u8bfe\u4ef6\u5927\u7eb2 (1/' + total + ')', 1800, 0, 'FFFFFF') +
      '</p:txBody></p:sp>';
  }
  function contentSlideShapes(slide, idx, total) {
    return '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Band"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' + EMU_W + '" cy="1300000"/></a:xfrm>' +
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="1F6FB2"/></a:solidFill></p:spPr>' +
      '<p:txBody><a:bodyPr anchor="ctr" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>' +
      pText(slide.title || ('\u7b2c' + idx + '\u9875'), 3000, 1, 'FFFFFF') +
      '</p:txBody></p:sp>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="4" name="Body"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="457200" y="1600000"/><a:ext cx="11277600" cy="4800000"/></a:xfrm></p:spPr>' +
      '<p:txBody><a:bodyPr wrap="square" anchor="t" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>' +
      pBullet((slide.points || []).join('\n'), 2000, '333333') +
      '</p:txBody></p:sp>' +
      '<p:sp><p:nvSpPr><p:cNvPr id="5" name="Page"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>' +
      '<p:spPr><a:xfrm><a:off x="11277600" y="6250000"/><a:ext cx="900000" cy="400000"/></a:xfrm></p:spPr>' +
      '<p:txBody><a:bodyPr anchor="ctr" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>' +
      pText(idx + ' / ' + total, 1200, 0, '999999') +
      '</p:txBody></p:sp>';
  }
  function slideWrap(slideName, shapes) {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="' + esc(slideName) + '">' +
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      shapes +
      '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
  }
  function slideRelsXml() {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
      '</Relationships>';
  }

  function pptxFromCourseware(jsonText, fileName) {
    var obj;
    try { obj = JSON.parse(jsonText); } catch (e) { return Promise.reject(new Error('JSON ' + e.message)); }
    if (!obj || !Array.isArray(obj.pages)) return Promise.reject(new Error('invalid courseware json'));
    var pages = obj.pages;
    var slides = [{ title: obj.title || '\u8bfe\u4ef6\u5927\u7eb2', points: [] }].concat(pages);
    var n = slides.length;

    var skelP = window.rtmNative && window.rtmNative.skeleton
      ? window.rtmNative.skeleton()
      : Promise.reject(new Error('no skeleton'));
    return skelP
      .then(function (skel) {
        if (!skel || !skel.byteLength) throw new Error('no skeleton');
        return JSZip.loadAsync(skel);
      })
      .then(function (zip) {
        for (var i = 0; i < n; i++) {
          var shapes = i === 0 ? titleSlideShapes(slides[0], n) : contentSlideShapes(slides[i], i + 1, n);
          zip.file('ppt/slides/slide' + (i + 1) + '.xml', slideWrap('Slide ' + (i + 1), shapes));
          if (i > 0) zip.file('ppt/slides/_rels/slide' + (i + 1) + '.xml.rels', slideRelsXml());
        }
        // 共享读取骨架的三个 XML 以追加
        return Promise.all([
          zip.file('[Content_Types].xml').async('string'),
          zip.file('ppt/_rels/presentation.xml.rels').async('string'),
          zip.file('ppt/presentation.xml').async('string')
        ]).then(function (r) {
          var ct = r[0], rels = r[1], pres = r[2];
          var extrasCt = '', extrasRel = '', sldLst = '<p:sldIdLst><p:sldId id="256" r:id="rId2"/>';
          for (var j = 1; j < n; j++) {
            var rid = 'rId20' + (j + 1);
            extrasCt += '<Override PartName="/ppt/slides/slide' + (j + 1) + '.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>';
            extrasRel += '<Relationship Id="' + rid + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide' + (j + 1) + '.xml"/>';
            sldLst += '<p:sldId id="' + (256 + j) + '" r:id="' + rid + '"/>';
          }
          sldLst += '</p:sldIdLst>';
          zip.file('[Content_Types].xml', ct.replace(/<\/Types>/, extrasCt + '</Types>'));
          zip.file('ppt/_rels/presentation.xml.rels', rels.replace(/<\/Relationships>/, extrasRel + '</Relationships>'));
          zip.file('ppt/presentation.xml', pres.replace(/<p:sldIdLst>[\s\S]*?<\/p:sldIdLst>/, sldLst));
          return zip;
        });
      })
      .then(function (zip) {
        return zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE' });
      })
      .then(function (buf) {
        return { name: sanitizeName(fileName) + '.pptx', data: buf };
      });
  }

  /* ============================================================
   * Excel → string[][]（首个工作表 + sharedStrings）
   * ============================================================ */
  function colIdx(col) {
    var idx = 0;
    for (var i = 0; i < col.length; i++) idx = idx * 26 + (col.charCodeAt(i) - 64);
    return idx - 1;
  }
  function sharedStrings(txt) {
    var out = [];
    var m, re = /<si>([\s\S]*?)<\/si>/g;
    while ((m = re.exec(txt)) !== null) {
      var t = '', im, re2 = /<t[^>]*>([\s\S]*?)<\/t>/g;
      while ((im = re2.exec(m[1])) !== null) t += unesc(im[1]);
      out.push(t);
    }
    return out;
  }
  function parseSheetCells(xml, shared) {
    var rows = [];
    var rm, re = /<row[^>]*>([\s\S]*?)<\/row>/g;
    while ((rm = re.exec(xml)) !== null) {
      var cells = [];
      var cm, cre = /<c(?:\s+r="([A-Z]+)\d+")?([^>]*)>([\s\S]*?)<\/c>/g;
      while ((cm = cre.exec(rm[1])) !== null) {
        var col = cm[1] ? colIdx(cm[1]) : cells.length;
        var attrs = cm[2] || '';
        var tM = attrs.match(/t="([^"]*)"/);
        var t = tM ? tM[1] : '';
        var val = '';
        var inner = cm[3];
        if (t === 'inlineStr') {
          var im = inner.match(/<t[^>]*>([\s\S]*?)<\/t>/);
          if (im) val = unesc(im[1]);
        } else if (t === 's') {
          var sm = inner.match(/<v>([\s\S]*?)<\/v>/);
          if (sm) val = shared[parseInt(sm[1], 10)] || '';
        } else {
          var nm = inner.match(/<v>([\s\S]*?)<\/v>/);
          if (nm) val = unesc(nm[1]);
        }
        while (cells.length < col) cells.push('');
        cells[col] = val;
      }
      rows.push(cells);
    }
    return rows;
  }
  function xlsxToRows(buffer) {
    return JSZip.loadAsync(buffer).then(function (zip) {
      var shared = [];
      var ss = zip.file('xl/sharedStrings.xml');
      var p = ss ? ss.async('string').then(function (t) { shared = sharedStrings(t); return zip; }) : Promise.resolve(zip);
      return p.then(function () {
        // 取第一个工作表：优先经 workbook.xml + rels 定位，找不到退回 sheet1.xml
        var target = 'xl/worksheets/sheet1.xml';
        var wb = zip.file('xl/workbook.xml');
        var findP = wb ? wb.async('string').then(function (t) {
          var fm = t.match(/<sheet[^>]*name="([^"]*)"[^>]*r:id="([^"]*)"[^>]*>/);
          if (!fm) return null;
          var sheetName = fm[1] || '';
          var relsF = zip.file('xl/_rels/workbook.xml.rels');
          if (!relsF) return { target: target, sheetName: sheetName };
          return relsF.async('string').then(function (rt) {
            var rm = rt.match(new RegExp('<Relationship[^>]*Id="' + fm[2] + '"[^>]*Target="([^"]*)"'));
            if (rm) {
              var tgt = rm[1];
              if (!/^xl\//.test(tgt)) tgt = 'xl/' + tgt.replace(/^\//, '');
              target = tgt;
            }
            return { target: target, sheetName: sheetName };
          });
        }) : Promise.resolve(null);

        return findP.then(function (info) {
          var sheetFile = zip.file(target);
          if (!sheetFile) {
            // 兜底：遍历 worksheets
            var names = Object.keys(zip.files).filter(function (k) { return /^xl\/worksheets\/sheet\d+\.xml$/.test(k); }).sort();
            if (!names.length) throw new Error('no sheet');
            target = names[0];
            sheetFile = zip.file(target);
          }
          return sheetFile.async('string').then(function (sx) {
            return { sheetName: info ? info.sheetName : '', rows: parseSheetCells(sx, shared) };
          });
        });
      });
    });
  }

  /* ============================================================
   * docx → 纯文本（名单解析用）—— 与鸿蒙 parseWord 同正则
   * ============================================================ */
  function docxToPlain(buffer) {
    return JSZip.loadAsync(buffer).then(function (zip) {
      var f = zip.file('word/document.xml');
      if (!f) throw new Error('no document.xml');
      return f.async('string').then(function (xml) {
        var t = xml
          .replace(/<w:tab[^>]*\/\s*>/g, '\t')
          .replace(/<w:br[^>]*\/\s*>/g, '\n')
          .replace(/<\/w:p>/g, '\n')
          .replace(/<w:t[^>]*>([\s\S]*?)<\/w:t>/g, '$1')
          .replace(/<[^>]+>/g, '');
        return t;
      });
    });
  }

  return {
    docxFromMarkdown: docxFromMarkdown,
    docxFromHtml: docxFromHtml,
    pptxFromCourseware: pptxFromCourseware,
    xlsxToRows: xlsxToRows,
    docxToPlain: docxToPlain
  };
})();