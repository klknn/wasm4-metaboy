module gb.ppu;

import gb.types;
import w4 = wasm4;

struct PPU {
    u8[8192] vram;      // 0x8000 - 0x9FFF
    u8[160]  oam;       // 0xFE00 - 0xFE9F

    // Registers
    u8 lcdc = 0x91;     // 0xFF40 LCD Control
    u8 stat = 0x85;     // 0xFF41 LCD Status
    u8 scy  = 0x00;     // 0xFF42 Scroll Y
    u8 scx  = 0x00;     // 0xFF43 Scroll X
    u8 ly   = 0x00;     // 0xFF44 LCD Y
    u8 lyc  = 0x00;     // 0xFF45 LY Compare
    u8 bgp  = 0xFC;     // 0xFF47 BG Palette
    u8 obp0 = 0xFF;     // 0xFF48 OBJ Palette 0
    u8 obp1 = 0xFF;     // 0xFF49 OBJ Palette 1
    u8 wy   = 0x00;     // 0xFF4A Window Y
    u8 wx   = 0x00;     // 0xFF4B Window X

    uint scanlineCycles = 0;
    u8 windowLine = 0;

    void reset() {
        lcdc = 0x91;
        stat = 0x85;
        scy  = 0;
        scx  = 0;
        ly   = 0;
        lyc  = 0;
        bgp  = 0xFC;
        obp0 = 0xFF;
        obp1 = 0xFF;
        wy   = 0;
        wx   = 0;
        scanlineCycles = 0;
        windowLine = 0;
        vram[] = 0;
        oam[]  = 0;
    }

    // Step PPU by `cycles` T-cycles. Returns interrupt bits (INT_VBLANK, INT_STAT).
    u8 step(uint cycles) {
        if (!(lcdc & LCDC_ENABLE)) {
            scanlineCycles = 0;
            ly = 0;
            stat = (stat & ~STAT_MODE_MASK) | STAT_MODE_HBLANK;
            windowLine = 0;
            return 0;
        }

        u8 requested = 0;
        scanlineCycles += cycles;

        while (scanlineCycles >= GB_CYCLES_PER_LINE) {
            scanlineCycles -= GB_CYCLES_PER_LINE;

            if (ly < GB_SCREEN_H) {
                renderScanline(ly);
            }
            ly++;

            checkLYC(requested);

            if (ly == GB_SCREEN_H) {
                // Mode 1: VBlank
                setMode(STAT_MODE_VBLANK, requested);
                requested |= INT_VBLANK;
                if (stat & STAT_INT_VBLANK) requested |= INT_STAT;
            } else if (ly >= GB_SCANLINES) {
                // Frame complete, wrap back to scanline 0
                ly = 0;
                windowLine = 0;
                checkLYC(requested);
                setMode(STAT_MODE_OAM, requested);
            } else if (ly < GB_SCREEN_H) {
                setMode(STAT_MODE_OAM, requested);
            }
        }

        // Sub-scanline mode updates for active display lines
        if (ly < GB_SCREEN_H) {
            if (scanlineCycles < 80) {
                setMode(STAT_MODE_OAM, requested);
            } else if (scanlineCycles < 80 + 172) {
                setMode(STAT_MODE_TRANSFER, requested);
            } else {
                setMode(STAT_MODE_HBLANK, requested);
            }
        }

        return requested;
    }

    private void setMode(u8 mode, ref u8 interrupts) {
        if ((stat & STAT_MODE_MASK) == mode) return;
        stat = (stat & ~STAT_MODE_MASK) | (mode & STAT_MODE_MASK);

        if ((mode == STAT_MODE_HBLANK && (stat & STAT_INT_HBLANK)) ||
            (mode == STAT_MODE_OAM    && (stat & STAT_INT_OAM))) {
            interrupts |= INT_STAT;
        }
    }

    private void checkLYC(ref u8 interrupts) {
        if (ly == lyc) {
            stat |= STAT_LYC_FLAG;
            if (stat & STAT_INT_LYC) interrupts |= INT_STAT;
        } else {
            stat &= ~STAT_LYC_FLAG;
        }
    }

    private void renderScanline(u8 line) {
        u8[160] scanlineColors = 0;
        u8[160] rawBgColor = 0;

        // 1. Render Background & Window
        if (lcdc & LCDC_BG_ENABLE) {
            bool winActive = (lcdc & LCDC_WIN_ENABLE) && (line >= wy) && (wx <= 166);
            bool winDrawn = false;

            u16 bgBase = (lcdc & LCDC_BG_TILEMAP) ? 0x9C00 : 0x9800;
            u16 winBase = (lcdc & LCDC_WIN_TILEMAP) ? 0x9C00 : 0x9800;
            bool unsignedTiles = (lcdc & LCDC_TILE_DATA) != 0;

            for (int x = 0; x < 160; x++) {
                bool isWin = winActive && (x >= (cast(int)wx - 7));
                u16 mapBase = isWin ? winBase : bgBase;
                u8 mapX = cast(u8)(isWin ? (x - (cast(int)wx - 7)) : (x + scx));
                u8 mapY = isWin ? windowLine : cast(u8)(line + scy);
                if (isWin) winDrawn = true;

                u16 tileIdxAddr = cast(u16)(mapBase + (mapY / 8) * 32 + (mapX / 8));
                u8 tileId = vram[tileIdxAddr - 0x8000];

                u16 tileAddr = unsignedTiles
                    ? cast(u16)(0x8000 + tileId * 16)
                    : cast(u16)(0x9000 + cast(byte)tileId * 16);

                u8 fineY = mapY % 8;
                u8 bit = cast(u8)(7 - (mapX % 8));
                u8 b0 = vram[tileAddr - 0x8000 + fineY * 2];
                u8 b1 = vram[tileAddr - 0x8000 + fineY * 2 + 1];

                u8 colorId = cast(u8)((((b1 >> bit) & 1) << 1) | ((b0 >> bit) & 1));
                rawBgColor[x] = colorId;
                scanlineColors[x] = (bgp >> (colorId * 2)) & 3;
            }
            if (winDrawn) windowLine++;
        }

        // 2. Render Sprites (OBJ)
        if (lcdc & LCDC_OBJ_ENABLE) {
            int spriteHeight = (lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
            int count = 0;

            for (int i = 0; i < 40 && count < 10; i++) {
                int oamIdx = i * 4;
                int sy = cast(int)oam[oamIdx] - 16;
                int sx = cast(int)oam[oamIdx + 1] - 8;
                u8 tileId = oam[oamIdx + 2];
                u8 attr = oam[oamIdx + 3];

                if (line < sy || line >= sy + spriteHeight) continue;
                count++;

                if (spriteHeight == 16) tileId &= 0xFE;
                bool priority = (attr & 0x80) != 0;
                bool yFlip = (attr & 0x40) != 0;
                bool xFlip = (attr & 0x20) != 0;
                u8 pal = (attr & 0x10) ? obp1 : obp0;

                int row = yFlip ? (spriteHeight - 1 - (line - sy)) : (line - sy);
                u16 tileAddr = cast(u16)(0x8000 + tileId * 16 + row * 2);
                u8 b0 = vram[tileAddr - 0x8000];
                u8 b1 = vram[tileAddr - 0x8000 + 1];

                for (int px = 0; px < 8; px++) {
                    int screenX = sx + px;
                    if (screenX < 0 || screenX >= 160) continue;

                    u8 bit = cast(u8)(xFlip ? px : (7 - px));
                    u8 colorId = cast(u8)((((b1 >> bit) & 1) << 1) | ((b0 >> bit) & 1));
                    if (colorId == 0) continue; // Transparent
                    if (priority && rawBgColor[screenX] != 0) continue;

                    scanlineColors[screenX] = (pal >> (colorId * 2)) & 3;
                }
            }
        }

        // 3. Write directly to WASM-4 framebuffer (160x160 2bpp, 4 pixels/byte)
        ubyte* fb = w4.framebuffer + (line * 40);
        for (int col = 0; col < 40; col++) {
            int p = col * 4;
            fb[col] = cast(ubyte)(
                (scanlineColors[p]     & 3)      |
                ((scanlineColors[p + 1] & 3) << 2) |
                ((scanlineColors[p + 2] & 3) << 4) |
                ((scanlineColors[p + 3] & 3) << 6)
            );
        }
    }

    u8 read(u16 addr) const {
        if (addr <= 0x9FFF) return vram[addr - 0x8000];
        if (addr <= 0xFE9F) return oam[addr - 0xFE00];

        switch (addr) {
            case 0xFF40: return lcdc;
            case 0xFF41: return stat | 0x80;
            case 0xFF42: return scy;
            case 0xFF43: return scx;
            case 0xFF44: return ly;
            case 0xFF45: return lyc;
            case 0xFF47: return bgp;
            case 0xFF48: return obp0;
            case 0xFF49: return obp1;
            case 0xFF4A: return wy;
            case 0xFF4B: return wx;
            default:     return 0xFF;
        }
    }

    void write(u16 addr, u8 val) {
        if (addr <= 0x9FFF) {
            vram[addr - 0x8000] = val;
        } else if (addr <= 0xFE9F) {
            oam[addr - 0xFE00] = val;
        } else {
            switch (addr) {
                case 0xFF40: lcdc = val; break;
                case 0xFF41: stat = (stat & 0x07) | (val & 0xF8); break;
                case 0xFF42: scy = val; break;
                case 0xFF43: scx = val; break;
                case 0xFF44: ly = 0; break;
                case 0xFF45: lyc = val; break;
                case 0xFF47: bgp = val; break;
                case 0xFF48: obp0 = val; break;
                case 0xFF49: obp1 = val; break;
                case 0xFF4A: wy = val; break;
                case 0xFF4B: wx = val; break;
                default: break;
            }
        }
    }
}

unittest {
    PPU ppu;
    ppu.reset();
    assert(ppu.ly == 0);

    // Step 1 scanline (456 cycles)
    ppu.step(456);
    assert(ppu.ly == 1);

    // Step to line 144 (VBlank)
    u8 ints = 0;
    while (ppu.ly < 144) {
        ints |= ppu.step(456);
    }
    assert(ppu.ly == 144);
    assert((ints & INT_VBLANK) != 0);

    // Step until end of frame (line 153 -> wraps to 0)
    while (ppu.ly > 0) {
        ppu.step(456);
    }
    assert(ppu.ly == 0);

    // LYC compare test
    ppu.lyc = 5;
    ppu.stat |= STAT_INT_LYC; // Enable LYC interrupt
    while (ppu.ly < 5) ppu.step(456);
    assert(ppu.ly == 5);
    assert((ppu.stat & STAT_LYC_FLAG) != 0);

    import core.stdc.stdio : printf;
    printf("✔ [PPU] Unittests passed.\n");
}
