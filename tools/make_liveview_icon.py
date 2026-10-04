# -*- coding: utf-8 -*-
"""为实况窗生成合规的胶囊图标。

依据（华为实况窗设计规范）：
  - 图标会被系统**统一裁切为同心圆**，需预留安全边距，避免关键图形被裁掉
  - 胶囊背景为系统统一提供的深色（纯黑透明 / 黑色微渐变）
  - 文本固定白色 #FFFFFF，图标需与白字有足够对比
  - 引用方式：放在 resources/rawfile/ 下，用文件名引用

做法：
  1. 读取应用前景图标 AppScope/.../foreground.png（1024x1024 RGBA）
  2. 等比缩放到 192x192（三倍图，适配高密度屏，且体积小）
  3. 居中放置于透明方形画布，四周留出约 12% 安全边距（防同心圆裁切）
  4. 输出 PNG 到 entry/src/main/resources/rawfile/liveview/
"""
import os

from PIL import Image

ROOT = r'C:\Users\laoyu\Desktop\Rev_Techingmaster'
SRC = os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media', 'foreground.png')
OUT_DIR = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'liveview')

# 输出尺寸：192px（三倍图）；系统裁切同心圆，故留安全边距
CANVAS = 192
SAFE_RATIO = 0.12          # 四周各留 12% 作为裁切安全区
INNER = int(CANVAS * (1 - SAFE_RATIO * 2))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    im = Image.open(SRC).convert('RGBA')
    print('源图: %dx%d %s' % (im.width, im.height, im.mode))

    # 等比缩放到 INNER
    im2 = im.resize((INNER, INNER), Image.LANCZOS)

    # 居中贴到透明画布
    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - INNER) // 2
    canvas.paste(im2, (off, off), im2)

    out = os.path.join(OUT_DIR, 'liveview_icon.png')
    canvas.save(out, 'PNG', optimize=True)
    print('输出: %s  %dx%d  %d B' % (out, canvas.width, canvas.height, os.path.getsize(out)))

    # 额外输出一个不带安全边距的紧贴版（若系统不裁切可用）
    im3 = im.resize((CANVAS, CANVAS), Image.LANCZOS)
    out2 = os.path.join(OUT_DIR, 'liveview_icon_full.png')
    im3.save(out2, 'PNG', optimize=True)
    print('输出: %s  %dx%d  %d B' % (out2, im3.width, im3.height, os.path.getsize(out2)))

    print()
    print('体积对比: 原图 %d B -> 安全边距版 %d B / 紧贴版 %d B'
          % (os.path.getsize(SRC), os.path.getsize(out), os.path.getsize(out2)))


if __name__ == '__main__':
    main()
