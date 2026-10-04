# -*- coding: utf-8 -*-
"""生成进度条节点图标（nodeIcons 用）。

背景：真机日志显示 startLiveView 报 401：
    The type of layoutData.nodeIcons must be Array<string | image.PixelMap>
    [or the parameter is mandatory]
虽然 SDK 中 nodeIcons 标注为**可选**（nodeIcons?），但**运行时会强制校验**，
故必须提供。运行时优先于类型定义，以实测为准。

产出：
  - node_done.png    已完成节点（蓝色实心圆点）
  - node_todo.png    未完成节点（灰色空心圆点）
规格：48x48 透明 PNG（三倍图），体积小、在深色胶囊背景上清晰可辨。
"""
import os

from PIL import Image, ImageDraw

ROOT = r'C:\Users\laoyu\Desktop\Rev_Techingmaster'
OUT = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'liveview')

SIZE = 48          # 三倍图
R = 16             # 圆半径
LW = 5             # 描边宽度


def circle(fill, outline, path):
    im = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = SIZE // 2
    box = [c - R, c - R, c + R, c + R]
    if fill is not None:
        d.ellipse(box, fill=fill)
    if outline is not None:
        d.ellipse(box, outline=outline, width=LW)
    im.save(path, 'PNG', optimize=True)
    return os.path.getsize(path)


def main():
    os.makedirs(OUT, exist_ok=True)
    # 已完成：主题蓝实心
    s1 = circle((74, 144, 217, 255), None, os.path.join(OUT, 'node_done.png'))
    # 待完成：灰描边空心
    s2 = circle(None, (153, 153, 153, 255), os.path.join(OUT, 'node_todo.png'))
    print('node_done.png  %d B' % s1)
    print('node_todo.png  %d B' % s2)
    print('输出目录: %s' % OUT)


if __name__ == '__main__':
    main()
