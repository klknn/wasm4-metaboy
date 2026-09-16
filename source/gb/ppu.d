/**
 * Game Boy Picture Processing Unit (PPU)
 *
 * Pan Docs References:
 * - Rendering:      https://gbdev.io/pandocs/Rendering.html
 * - Graphics Specs: https://gbdev.io/pandocs/Graphics.html
 * - LCD Control:    https://gbdev.io/pandocs/LCDC.html
 * - LCD Status:     https://gbdev.io/pandocs/STAT.html
 * - OAM Sprites:    https://gbdev.io/pandocs/OAM.html
 * - Palettes:       https://gbdev.io/pandocs/Palettes.html
 *
 * Architecture Summary:
 * - Display Resolution: 160 x 144 pixels (fits within WASM-4's 160 x 160 canvas).
 * - Colors: 4 shades of gray (mapped directly to WASM-4 palette indices 0..3).
 * - Timing:
 *   - Frame rate: ~59.73 Hz (70,224 T-cycles per frame).
 *   - Scanlines: 154 scanlines per frame (456 T-cycles per scanline).
 *     - Lines 0..143: Active display (visible scanlines).
 *     - Lines 144..153: Vertical Blanking (VBlank) interval.
 * - Scanline Mode Cycle Breakdown:
 *   - Mode 2 (OAM Search): Cycles 0..79 (80 cycles). PPU searches OAM for up to 10 sprites.
 *   - Mode 3 (Pixel Transfer): Cycles 80..251 (~172 cycles). PPU pushes pixels to display.
 *   - Mode 0 (HBlank): Cycles 252..455 (~204 cycles). Horizontal blanking until next line.
 *   - Mode 1 (VBlank): Scanlines 144..153. Triggers INT_VBLANK on transition to line 144.
 */
module gb.ppu;

import gb.types;
import std.bitmanip : bitfields;
import w4 = wasm4;

/**
 * Object Attribute Memory (OAM) Sprite Entry (4 bytes per sprite, 40 sprites total).
 * Memory: 0xFE00 - 0xFE9F.
 *
 * Pan Docs Reference: https://gbdev.io/pandocs/OAM.html
 */
align(1) struct OamEntry {
    u8 y;    // Y-position + 16 (0 hides the sprite)
    u8 x;    // X-position + 8  (0 hides the sprite)
    u8 tile; // Tile index from VRAM 0x8000-0x8FFF (in 8x16 mode, bit 0 is ignored)
    union {
        u8 attr;
        mixin(bitfields!(
            uint, "cgbPalette",  3, // Bits 0-2: CGB palette number (ignored on DMG)
            bool, "cgbBank",     1, // Bit 3: CGB VRAM bank (ignored on DMG)
            bool, "palette1",    1, // Bit 4: Palette selector (0=OBP0 at 0xFF48, 1=OBP1 at 0xFF49)
            bool, "xFlip",       1, // Bit 5: Horizontal flip (1 = flip horizontally)
            bool, "yFlip",       1, // Bit 6: Vertical flip (1 = flip vertically)
            bool, "behindBg",    1  // Bit 7: OBJ-to-BG priority (0 = above BG, 1 = behind BG colors 1-3)
        ));
    }
}
static assert(OamEntry.sizeof == 4, "OamEntry must be exactly 4 bytes");

struct PPU {
    u8[8192] vram;      // 0x8000 - 0x9FFF: Video RAM (tiles and tile maps)

    // 0xFE00 - 0xFE9F: 160-byte Object Attribute Memory, dual-accessed as 40 sprites
    union {
        u8[160]      oam;
        OamEntry[40] sprites;
    }

    // ------------------------------------------------------------------------
    // Memory-Mapped I/O Registers
    // ------------------------------------------------------------------------

    // 0xFF40: LCD Control (LCDC)
    // Pan Docs: https://gbdev.io/pandocs/LCDC.html
    union {
        u8 lcdc = 0x91;
        mixin(bitfields!(
            bool, "bgEnable",         1, // Bit 0: BG & Window display enable (0=off/white, 1=on)
            bool, "objEnable",        1, // Bit 1: OBJ (sprite) display enable (0=off, 1=on)
            bool, "objSize16",        1, // Bit 2: OBJ size (0=8x8, 1=8x16)
            bool, "bgTilemapHigh",    1, // Bit 3: BG tilemap (0=0x9800-0x9BFF, 1=0x9C00-0x9FFF)
            bool, "tileDataUnsigned", 1, // Bit 4: Tile data (0=0x8800 signed, 1=0x8000 unsigned)
            bool, "winEnable",        1, // Bit 5: Window display enable (0=off, 1=on)
            bool, "winTilemapHigh",   1, // Bit 6: Window tilemap (0=0x9800-0x9BFF, 1=0x9C00-0x9FFF)
            bool, "lcdEnable",        1  // Bit 7: LCD operation enable (0=off, 1=on)
        ));
    }

    // 0xFF41: LCD Status (STAT)
    // Pan Docs: https://gbdev.io/pandocs/STAT.html
    union {
        u8 stat = 0x85;
        mixin(bitfields!(
            uint, "mode",      2, // Bits 0-1: Current PPU Mode (0: HBlank, 1: VBlank, 2: OAM, 3: Transfer)
            bool, "lycFlag",   1, // Bit 2: LYC == LY coincidence flag
            bool, "intHBlank", 1, // Bit 3: Mode 0 HBlank interrupt selection
            bool, "intVBlank", 1, // Bit 4: Mode 1 VBlank interrupt selection
            bool, "intOam",    1, // Bit 5: Mode 2 OAM interrupt selection
            bool, "intLyc",    1, // Bit 6: LYC=LY coincidence interrupt selection
            bool, "_padStat",  1  // Bit 7: Unused (always 1 on DMG)
        ));
    }

    u8 scy  = 0x00;     // 0xFF42: Background Scroll Y
    u8 scx  = 0x00;     // 0xFF43: Background Scroll X
    u8 ly   = 0x00;     // 0xFF44: Current LCD Scanline (0..153)
    u8 lyc  = 0x00;     // 0xFF45: LY Compare
    u8 bgp  = 0xFC;     // 0xFF47: BG & Window Palette Data
    u8 obp0 = 0xFF;     // 0xFF48: OBJ Palette 0 Data
    u8 obp1 = 0xFF;     // 0xFF49: OBJ Palette 1 Data
    u8 wy   = 0x00;     // 0xFF4A: Window Y Position
    u8 wx   = 0x00;     // 0xFF4B: Window X Position + 7

    uint scanlineCycles = 0; // Cycles elapsed on current scanline (0..455)
    u8 windowLine = 0;       // Internal counter for visible window scanlines

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

    /**
     * Steps the PPU by `cycles` T-cycles.
     * Returns interrupt bitmask (INT_VBLANK, INT_STAT).
     */
    u8 step(uint cycles) {
        if (!lcdEnable) {
            scanlineCycles = 0;
            ly = 0;
            mode = STAT_MODE_HBLANK;
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
                // Transition to Mode 1: VBlank
                setMode(STAT_MODE_VBLANK, requested);
                requested |= INT_VBLANK;
                if (intVBlank) requested |= INT_STAT;
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

    private void setMode(u8 newMode, ref u8 interrupts) {
        if (mode == newMode) return;
        mode = newMode;

        if ((newMode == STAT_MODE_HBLANK && intHBlank) ||
            (newMode == STAT_MODE_OAM    && intOam)) {
            interrupts |= INT_STAT;
        }
    }

    private void checkLYC(ref u8 interrupts) {
        if (ly == lyc) {
            lycFlag = true;
            if (intLyc) interrupts |= INT_STAT;
        } else {
            lycFlag = false;
        }
    }

    /**
     * Renders scanline `line` into the WASM-4 framebuffer.
     */
    private void renderScanline(u8 line) {
        u8[160] scanlineColors = 0;
        u8[160] rawBgColor = 0;

        // 1. Render Background & Window
        if (bgEnable) {
            bool winActive = winEnable && (line >= wy) && (wx <= 166);
            bool winDrawn = false;

            u16 bgBase = bgTilemapHigh ? 0x9C00 : 0x9800;
            u16 winBase = winTilemapHigh ? 0x9C00 : 0x9800;

            for (int x = 0; x < 160; x++) {
                bool isWin = winActive && (x >= (cast(int)wx - 7));
                u16 mapBase = isWin ? winBase : bgBase;
                u8 mapX = cast(u8)(isWin ? (x - (cast(int)wx - 7)) : (x + scx));
                u8 mapY = isWin ? windowLine : cast(u8)(line + scy);
                if (isWin) winDrawn = true;

                u16 tileIdxAddr = cast(u16)(mapBase + (mapY / 8) * 32 + (mapX / 8));
                u8 tileId = vram[tileIdxAddr - 0x8000];

                u16 tileAddr = tileDataUnsigned
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
        if (objEnable) {
            int spriteHeight = objSize16 ? 16 : 8;
            int count = 0;

            for (int i = 0; i < 40 && count < 10; i++) {
                const entry = sprites[i];
                int sy = cast(int)entry.y - 16;
                int sx = cast(int)entry.x - 8;
                u8 tileId = entry.tile;

                if (line < sy || line >= sy + spriteHeight) continue;
                count++;

                if (objSize16) tileId &= 0xFE; // In 8x16 mode, least significant bit of tileId is ignored
                u8 pal = entry.palette1 ? obp1 : obp0;

                int row = entry.yFlip ? (spriteHeight - 1 - (line - sy)) : (line - sy);
                u16 tileAddr = cast(u16)(0x8000 + tileId * 16 + row * 2);
                u8 b0 = vram[tileAddr - 0x8000];
                u8 b1 = vram[tileAddr - 0x8000 + 1];

                for (int px = 0; px < 8; px++) {
                    int screenX = sx + px;
                    if (screenX < 0 || screenX >= 160) continue;

                    u8 bit = cast(u8)(entry.xFlip ? px : (7 - px));
                    u8 colorId = cast(u8)((((b1 >> bit) & 1) << 1) | ((b0 >> bit) & 1));
                    if (colorId == 0) continue; // Color 0 is transparent for sprites
                    if (entry.behindBg && rawBgColor[screenX] != 0) continue;

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
    assert(ppu.lycFlag); // Test bitfield getter

    // Test LCDC bitfields
    ppu.lcdc = 0x91;
    assert(ppu.lcdEnable);
    assert(!ppu.winEnable);
    assert(ppu.bgEnable);

    // Test OamEntry struct and bitfields
    ppu.oam[0] = 16 + 10; // y = 10
    ppu.oam[1] = 8 + 20;  // x = 20
    ppu.oam[2] = 0x42;    // tile = 0x42
    ppu.oam[3] = 0b1111_0000; // behindBg=1, yFlip=1, xFlip=1, palette1=1
    assert(ppu.sprites[0].y == 26);
    assert(ppu.sprites[0].x == 28);
    assert(ppu.sprites[0].tile == 0x42);
    assert(ppu.sprites[0].behindBg);
    assert(ppu.sprites[0].yFlip);
    assert(ppu.sprites[0].xFlip);
    assert(ppu.sprites[0].palette1);

    import core.stdc.stdio : printf;
    printf("✔ [PPU] Unittests passed.\n");
}
