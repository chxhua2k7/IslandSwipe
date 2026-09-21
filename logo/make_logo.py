#!/usr/bin/env python3
"""IslandSwipe 的麥塊風 logo:16x16 像素畫(深板岩底、動態島黑膠囊、往左飛的箭),
輸出 SVG + 圓角 PNG(1024 大圖和設定頁的 29/58/87)。純 Python,不需要 PIL。"""
import os, struct, zlib, random

# 調色盤
P = {
    'a': '#2A2A2E', 'b': '#333338', 'c': '#3B3B41', 'd': '#242428',  # 深板岩
    'K': '#08080A', 'k': '#17171B',                                   # 動態島
    'g': '#2F6B3A',                                                   # 鏡頭一點綠
    'F': '#C9CACF', 'f': '#8E9096',                                   # 燧石箭頭
    'S': '#7A5230', 's': '#5E3E22',                                   # 木棍
    'W': '#F4F4F6', 'w': '#D3D4D8',                                   # 羽毛
}
random.seed(7)
grid = [[random.choice('aabbbccd') for _ in range(16)] for _ in range(16)]

def put(r, c, ch): grid[r][c] = ch

# 動態島膠囊(rows 2-4)
for c in range(5, 11): put(2, c, 'K'); put(4, c, 'K')
for c in range(4, 12): put(3, c, 'K')
put(2, 5, 'k'); put(2, 10, 'k'); put(4, 5, 'k'); put(4, 10, 'k')
put(3, 10, 'g')

# 往左飛的箭(rows 8-12):燧石頭在左、木棍、右邊白羽毛
for c in range(5, 13): put(10, c, 'S')
put(10, 8, 's'); put(10, 11, 's')
put(10, 2, 'F'); put(10, 3, 'F'); put(9, 3, 'f'); put(11, 3, 'f'); put(10, 4, 'f')
put(9, 4, 'F'); put(11, 4, 'F')
for c in (12, 13): put(9, c, 'W'); put(11, c, 'W')
put(8, 13, 'w'); put(12, 13, 'w'); put(10, 13, 'S'); put(10, 14, 's')

def hex2rgb(h): return tuple(int(h[i:i+2], 16) for i in (1, 3, 5))

def png(path, size):
    cell = size / 16
    radius = size * 0.2237  # iOS icon 圓角比例
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            r, g, b = hex2rgb(P[grid[int(y // cell)][int(x // cell)]])
            # 圓角遮罩
            cx = min(max(x + .5, radius), size - radius); cy = min(max(y + .5, radius), size - radius)
            a = 255 if (x + .5 - cx) ** 2 + (y + .5 - cy) ** 2 <= radius * radius else 0
            row += bytes((r, g, b, a))
        rows.append(bytes(row))
    raw = b''.join(rows)
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(data)

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
with open(os.path.join(here, 'IslandSwipe.svg'), 'w') as f:
    f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" shape-rendering="crispEdges">')
    for r in range(16):
        for c in range(16):
            f.write(f'<rect x="{c*64}" y="{r*64}" width="64" height="64" fill="{P[grid[r][c]]}"/>')
    f.write('</svg>\n')
png(os.path.join(here, 'IslandSwipe-1024.png'), 1024)
for name, size in (('IslandSwipe.png', 29), ('IslandSwipe@2x.png', 58), ('IslandSwipe@3x.png', 87)):
    png(os.path.join(root, 'bundle', name), size)
print('\n'.join(''.join(r) for r in grid))
