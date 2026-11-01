import zlib
import struct
import zipfile
from pathlib import Path

def make_png(w, h, pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type none
        for r, g, b, a in row:
            raw.extend((r, g, b, a))
    compressed = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")

w, h = 64, 64
pixels = []
for y in range(h):
    row = []
    for x in range(w):
        if y < 22:
            # desert sunset sky
            row.append((240, 180 - y * 3, 110 - y * 3, 255))
        elif y < 46:
            # dunes
            d = int((x * 0.3 + y * 0.2) % 4)
            row.append((225 + d * 5, 175 + d * 5, 65, 255))
        else:
            # oasis water & grass
            dist = ((x - 32)**2 + (y - 53)**2)**0.5
            if dist < 10:
                row.append((30, 140, 220, 255))
            elif dist < 15:
                row.append((50, 180, 70, 255))
            else:
                row.append((210, 160, 55, 255))
    pixels.append(row)

mod_dir = Path(r"c:\Users\mxka\Documents\GitHub\DroneFlames-Mods\mods\oasis_map")
icon_path = mod_dir / "icon.png"
icon_path.write_bytes(make_png(w, h, pixels))
print("Saved icon.png to", icon_path)

# Create oasis_map.dfmod (zip archive)
dfmod_path = mod_dir / "oasis_map.dfmod"
with zipfile.ZipFile(dfmod_path, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.write(mod_dir / "mod.json", "mod.json")
    zf.write(mod_dir / "mod.gd", "mod.gd")
    zf.write(icon_path, "icon.png")

print("Created oasis_map.dfmod package:", dfmod_path)
