#!/usr/bin/env python3
"""AppIcon.icns for L42 Config: a printer front with a settings gear."""
import math
import os
import struct
import subprocess
import zlib

S = 1024
PAPER = (247, 244, 236, 255)
EDGE = (208, 200, 184, 255)
INK = (32, 32, 34, 255)
CLAY = (217, 119, 87, 255)

img = bytearray(S * S * 4)


def put(x, y, c):
    if 0 <= x < S and 0 <= y < S:
        o = (y * S + x) * 4
        img[o:o+4] = bytes(c)


def rounded(x, y, x0, y0, x1, y1, r):
    if x0 + r <= x <= x1 - r or y0 + r <= y <= y1 - r:
        return x0 <= x <= x1 and y0 <= y <= y1
    cx = x0 + r if x < x0 + r else x1 - r
    cy = y0 + r if y < y0 + r else y1 - r
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def rect(x0, y0, x1, y1, c):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            put(x, y, c)


# squircle background
M, R = 100, 232
for y in range(S):
    for x in range(S):
        if rounded(x, y, M, M, S - 1 - M, S - 1 - M, R):
            edge = not rounded(x, y, M + 14, M + 14, S - 15 - M, S - 15 - M, R - 14)
            put(x, y, EDGE if edge else PAPER)

# printer body
rect(250, 430, 774, 700, INK)
# label coming out of the slot
rect(300, 620, 724, 640, PAPER)
rect(320, 700, 704, 810, PAPER)
for x in range(320, 705, 2):          # torn bottom edge
    rect(x, 810, x + 1, 810 + (6 if (x // 2) % 2 else 0), PAPER)
# barcode on the label
bx = 350
import random
random.seed(5)
while bx < 670:
    w = random.choice([4, 4, 8, 12])
    rect(bx, 730, bx + w - 1, 785, INK)
    bx += w + random.choice([6, 10])

# gear on the printer face
GX, GY, RO, RI = 512, 520, 96, 52
for y in range(GY - RO - 26, GY + RO + 27):
    for x in range(GX - RO - 26, GX + RO + 27):
        dx, dy = x - GX, y - GY
        d = math.hypot(dx, dy)
        ang = math.atan2(dy, dx)
        tooth = (math.cos(ang * 8) + 1) / 2          # 8 teeth
        edge = RO + tooth * 26
        if d <= edge and d >= RI:
            put(x, y, CLAY)


def write_png(path, size):
    f = S // size
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            r = g = b = a = 0
            for dy in range(f):
                for dx in range(f):
                    o = ((y * f + dy) * S + x * f + dx) * 4
                    r += img[o]; g += img[o+1]; b += img[o+2]; a += img[o+3]
            n = f * f
            row += bytes((r // n, g // n, b // n, a // n))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data))

    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


here = os.path.dirname(os.path.abspath(__file__))
iconset = os.path.join(here, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for size, names in [(16, ["icon_16x16.png"]), (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
                    (64, ["icon_32x32@2x.png"]), (128, ["icon_128x128.png"]),
                    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
                    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
                    (1024, ["icon_512x512@2x.png"])]:
    write_png(os.path.join(iconset, names[0]), size)
    for extra in names[1:]:
        data = open(os.path.join(iconset, names[0]), "rb").read()
        open(os.path.join(iconset, extra), "wb").write(data)

subprocess.run(["iconutil", "-c", "icns", iconset, "-o",
                os.path.join(here, "AppIcon.icns")], check=True)
print("AppIcon.icns written")
