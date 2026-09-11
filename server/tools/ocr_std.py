# -*- coding: utf-8 -*-
"""新课标 PDF 批量 OCR（课标 PDF 为扫描件，无文本层，必须先 OCR）

用法:
    python tools/ocr_std.py [并发数]
    python tools/ocr_std.py 8 --src ../teching --out .ocr_cache

参数（均可用环境变量覆盖）:
    --src   课标 PDF 目录，默认 <repo>/teching
    --out   OCR 结果缓存目录，默认 <repo>/server/.ocr_cache
输入：<src>/*.pdf
输出：<out>/<原文件名>.jsonl   每行 {"page": n, "text": "..."}

依赖：pypdfium2（渲染）、pytesseract + tesseract（chi_sim 语言包）
说明：可断点续跑，已存在且非空的输出会被跳过。
"""
import os
import sys
import glob
import json
import time
import argparse
import warnings

warnings.filterwarnings('ignore')

import pypdfium2 as pdfium
import pytesseract

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# tesseract 可执行文件路径（Windows 上通常不在 PATH，需显式指定）
TESSERACT_CMD = os.environ.get('TESSERACT_CMD', '')
if TESSERACT_CMD:
    pytesseract.pytesseract.tesseract_cmd = TESSERACT_CMD

DPI = 300          # 300 DPI 实测识别率最好；更高 DPI 反而放大扫描噪点
CFG = '--psm 6'    # 版式为单一文本块（课标正文即此形态）
LANG = 'chi_sim'


def ocr_one(args):
    pdf_path, out_dir = args
    base = os.path.basename(pdf_path)
    dst = os.path.join(out_dir, base + '.jsonl')
    if os.path.exists(dst) and os.path.getsize(dst) > 200:
        return '%s 已存在，跳过' % base
    tmp = dst + '.part'
    pdf = pdfium.PdfDocument(pdf_path)
    n = len(pdf)
    t0 = time.time()
    rows = []
    for i in range(n):
        img = pdf[i].render(scale=DPI / 72.0).to_pil()
        try:
            txt = pytesseract.image_to_string(img, lang=LANG, config=CFG)
        except Exception as e:
            txt = ''
            print('  %s 第 %d 页 OCR 失败: %s' % (base, i + 1, e), flush=True)
        rows.append({'page': i + 1, 'text': txt})
        if (i + 1) % 20 == 0:
            print('  %s %d/%d  %.0fs' % (base, i + 1, n, time.time() - t0), flush=True)
    pdf.close()
    with open(tmp, 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    os.replace(tmp, dst)
    return '%s 完成 %d 页 %.0fs' % (base, n, time.time() - t0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('workers', nargs='?', type=int, default=6, help='并发进程数')
    ap.add_argument('--src', default=os.path.join(REPO, 'teching'))
    ap.add_argument('--out', default=os.path.join(REPO, 'server', '.ocr_cache'))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(args.src, '*.pdf')))
    if not files:
        print('未在 %s 找到 PDF' % args.src)
        return
    todo = []
    for f in files:
        dst = os.path.join(args.out, os.path.basename(f) + '.jsonl')
        if os.path.exists(dst) and os.path.getsize(dst) > 200:
            print('跳过（已有）', os.path.basename(f))
        else:
            todo.append((f, args.out))
    if not todo:
        print('全部已完成')
        return
    print('待处理 %d 个文件，并发 %d' % (len(todo), args.workers), flush=True)
    from multiprocessing import Pool
    with Pool(args.workers) as pool:
        for msg in pool.imap_unordered(ocr_one, todo):
            print(msg, flush=True)
    print('全部完成')


if __name__ == '__main__':
    main()
