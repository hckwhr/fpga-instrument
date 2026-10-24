"""Add three glyphs to reserved font slots; preserve existing glyphs/help."""
from pathlib import Path
import re
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
font = ImageFont.truetype(r'C:\Windows\Fonts\msyhbd.ttc', 22, index=0)
case_path = ROOT / 'rtl/chinese_font_24x24.vh'
rom_path = ROOT / 'rtl/chinese_font_rom_init.vh'
case = case_path.read_text(encoding='utf-8')
rom = rom_path.read_text(encoding='utf-8')
new_cases = []
for glyph, char in ((134, '同'), (135, '钢'), (136, '盘')):
    bitmap = Image.new('L', (24, 24), 0)
    draw = ImageDraw.Draw(bitmap)
    x0, y0, x1, y1 = draw.textbbox((0, 0), char, font=font)
    draw.text(((24-x1+x0)//2-x0, (24-y1+y0)//2-y0-1), char, font=font, fill=255)
    for row in range(32):
        bits = ''.join('1' if row < 24 and bitmap.getpixel((col,row)) >= 92 else '0' for col in range(24))
        address = glyph*32+row
        case = re.sub(rf"^\s*13'd{address}: chinese_font_row = .*;\n", '', case, flags=re.M)
        if '1' in bits:
            new_cases.append(f"            13'd{address}: chinese_font_row = 24'b{bits};")
        rom, count = re.subn(rf"font_memory\[{address}\] = 24'b[01]{{24}};", f"font_memory[{address}] = 24'b{bits};", rom)
        assert count == 1, address
marker = "            default: chinese_font_row = 24'd0;"
assert case.count(marker) == 1
case = case.replace(marker, '\n'.join(new_cases)+'\n'+marker)
case_path.write_text(case, encoding='utf-8')
rom_path.write_text(rom, encoding='utf-8')
print('Generated glyphs 134..136 in existing 8192 x 24 ROM; old glyph indices retained')
