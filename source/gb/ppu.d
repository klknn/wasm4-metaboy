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
    u8 windowLine = 0;  // Internal window line counter
    
    // Top border offset in WASM-4 (160x160 screen):
    // Y=0..143: GB display, Y=144..159: Debug / Status bar
    enum int Y_OFFSET = 0;

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
        foreach (ref b; vram) b = 0;
        foreach (ref b; oam)  b = 0;
    }

    // Step PPU by `cycles` T-cycles.
    // Returns interrupt flags to be requested (e.g. INT_VBLANK, INT_STAT).
    u8 step(uint cycles) {
        if (!(lcdc & LCDC_ENABLE)) {
            // LCD is disabled
            scanlineCycles = 0;
            ly = 0;
            stat = (stat & ~STAT_MODE_MASK) | STAT_MODE_HBLANK;
            windowLine = 0;
            return 0;
        }

        u8 requestedInterrupts = 0;
        scanlineCycles += cycles;

        while (scanlineCycles >= GB_CYCLES_PER_LINE) {
            scanlineCycles -= GB_CYCLES_PER_LINE;

            // Render current scanline if within visible screen (0..143)
            if (ly < GB_SCREEN_H) {
                renderScanline(ly);
            }

            ly++;

            // Handle LY == LYC check
            checkLYC(requestedInterrupts);

            if (ly == GB_SCREEN_H) {
                // Entering VBlank (Mode 1)
                setMode(STAT_MODE_VBLANK, requestedInterrupts);
                requestedInterrupts |= INT_VBLANK;
                if (stat & STAT_INT_VBLANK) {
                    requestedInterrupts |= INT_STAT;
                }
            } else if (ly >= GB_SCANLINES) {
                // Frame complete, wrap back to line 0
                ly = 0;
                windowLine = 0;
                checkLYC(requestedInterrupts);
                setMode(STAT_MODE_OAM, requestedInterrupts);
            } else if (ly < GB_SCREEN_H) {
                setMode(STAT_MODE_OAM, requestedInterrupts);
            }
        }

        // Sub-scanline mode updates for lines 0..143
        if (ly < GB_SCREEN_H) {
            if (scanlineCycles < 80) {
                // Mode 2: OAM search
                setMode(STAT_MODE_OAM, requestedInterrupts);
            } else if (scanlineCycles < 80 + 172) {
                // Mode 3: Pixel Transfer
                setMode(STAT_MODE_TRANSFER, requestedInterrupts);
            } else {
                // Mode 0: HBlank
                setMode(STAT_MODE_HBLANK, requestedInterrupts);
            }
        }

        return requestedInterrupts;
    }

    private void setMode(u8 mode, ref u8 interrupts) {
        u8 oldMode = stat & STAT_MODE_MASK;
        if (oldMode == mode) return;

        stat = (stat & ~STAT_MODE_MASK) | (mode & STAT_MODE_MASK);

        // Check STAT interrupt triggers
        if (mode == STAT_MODE_HBLANK && (stat & STAT_INT_HBLANK)) {
            interrupts |= INT_STAT;
        } else if (mode == STAT_MODE_OAM && (stat & STAT_INT_OAM)) {
            interrupts |= INT_STAT;
        }
    }

    private void checkLYC(ref u8 interrupts) {
        if (ly == lyc) {
            stat |= STAT_LYC_FLAG;
            if (stat & STAT_INT_LYC) {
                interrupts |= INT_STAT;
            }
        } else {
            stat &= ~STAT_LYC_FLAG;
        }
    }

    private void renderScanline(u8 line) {
        // Pixel color buffer for line: color index (0-3) and priority
        u8[160] scanlineColors;
        u8[160] rawBgColor; // raw color id before palette (0..3) for sprite priority
        foreach (ref c; scanlineColors) c = 0;
        foreach (ref c; rawBgColor)     c = 0;

        // 1. Render Background & Window
        if (lcdc & LCDC_BG_ENABLE) {
            bool windowVisible = (lcdc & LCDC_WIN_ENABLE) && (line >= wy) && (wx <= 166);
            bool windowDrawnThisLine = false;

            u16 bgMapBase = (lcdc & LCDC_BG_TILEMAP) ? 0x9C00 : 0x9800;
            u16 winMapBase = (lcdc & LCDC_WIN_TILEMAP) ? 0x9C00 : 0x9800;
            bool unsignedTiles = (lcdc & LCDC_TILE_DATA) != 0;

            u8 bgY = cast(u8)(line + scy);

            for (int x = 0; x < 160; x++) {
                bool isWindow = windowVisible && (x >= (cast(int)wx - 7));
                u16 mapBase;
                u8 mapX, mapY;

                if (isWindow) {
                    mapBase = winMapBase;
                    mapX = cast(u8)(x - (cast(int)wx - 7));
                    mapY = windowLine;
                    windowDrawnThisLine = true;
                } else {
                    mapBase = bgMapBase;
                    mapX = cast(u8)(x + scx);
                    mapY = bgY;
                }

                u16 tileCol = mapX / 8;
                u16 tileRow = mapY / 8;
                u16 tileIndexAddr = cast(u16)(mapBase + (tileRow * 32) + tileCol);
                u8 tileId = vram[tileIndexAddr - 0x8000];

                u16 tileDataAddr;
                if (unsignedTiles) {
                    tileDataAddr = cast(u16)(0x8000 + (tileId * 16));
                } else {
                    tileDataAddr = cast(u16)(0x9000 + (cast(byte)tileId * 16));
                }

                u8 fineY = mapY % 8;
                u8 fineX = mapX % 8;

                u8 byte0 = vram[tileDataAddr - 0x8000 + fineY * 2];
                u8 byte1 = vram[tileDataAddr - 0x8000 + fineY * 2 + 1];

                u8 bit = cast(u8)(7 - fineX);
                u8 colorId = cast(u8)((((byte1 >> bit) & 1) << 1) | ((byte0 >> bit) & 1));
                rawBgColor[x] = colorId;

                // Apply BGP
                scanlineColors[x] = (bgp >> (colorId * 2)) & 3;
            }

            if (windowDrawnThisLine) {
                windowLine++;
            }
        }

        // 2. Render Sprites (OBJ)
        if (lcdc & LCDC_OBJ_ENABLE) {
            int spriteHeight = (lcdc & LCDC_OBJ_SIZE) ? 16 : 8;
            int spritesOnLine = 0;

            // Real GB searches 40 sprites and renders up to 10 per scanline
            for (int i = 0; i < 40 && spritesOnLine < 10; i++) {
                int oamIdx = i * 4;
                int spriteY = cast(int)oam[oamIdx] - 16;
                int spriteX = cast(int)oam[oamIdx + 1] - 8;
                u8 tileId   = oam[oamIdx + 2];
                u8 attrs    = oam[oamIdx + 3];

                if (line < spriteY || line >= spriteY + spriteHeight) {
                    continue;
                }
                spritesOnLine++;

                if (spriteHeight == 16) {
                    tileId &= 0xFE; // In 8x16 mode, bit 0 is ignored
                }

                bool priority = (attrs & 0x80) != 0; // 1 = behind BG colors 1..3
                bool yFlip    = (attrs & 0x40) != 0;
                bool xFlip    = (attrs & 0x20) != 0;
                u8 palette    = (attrs & 0x10) ? obp1 : obp0;

                int row = line - spriteY;
                if (yFlip) {
                    row = spriteHeight - 1 - row;
                }

                u16 tileDataAddr = cast(u16)(0x8000 + (tileId * 16) + (row * 2));
                u8 byte0 = vram[tileDataAddr - 0x8000];
                u8 byte1 = vram[tileDataAddr - 0x8000 + 1];

                for (int px = 0; px < 8; px++) {
                    int screenX = spriteX + px;
                    if (screenX < 0 || screenX >= 160) continue;

                    u8 bit = cast(u8)(xFlip ? px : (7 - px));
                    u8 colorId = cast(u8)((((byte1 >> bit) & 1) << 1) | ((byte0 >> bit) & 1));

                    // Color 0 for sprites is always transparent
                    if (colorId == 0) continue;

                    // If priority bit is set, sprite pixel is only drawn if BG raw color is 0
                    if (priority && rawBgColor[screenX] != 0) continue;

                    scanlineColors[screenX] = (palette >> (colorId * 2)) & 3;
                }
            }
        }

        // 3. Write directly to WASM-4 framebuffer!
        // WASM-4 framebuffer: 160x160 2bpp starting at 0x00A0
        // 4 pixels per byte:
        // bit 0-1: px0, bit 2-3: px1, bit 4-5: px2, bit 6-7: px3
        int targetY = line + Y_OFFSET;
        if (targetY >= 0 && targetY < 160) {
            ubyte* fb = w4.framebuffer + (targetY * 40);
            for (int col = 0; col < 40; col++) {
                int pxBase = col * 4;
                u8 p0 = scanlineColors[pxBase];
                u8 p1 = scanlineColors[pxBase + 1];
                u8 p2 = scanlineColors[pxBase + 2];
                u8 p3 = scanlineColors[pxBase + 3];

                fb[col] = cast(ubyte)((p0 & 3) | ((p1 & 3) << 2) | ((p2 & 3) << 4) | ((p3 & 3) << 6));
            }
        }
    }

    u8 read(u16 addr) const {
        if (addr >= 0x8000 && addr <= 0x9FFF) {
            return vram[addr - 0x8000];
        } else if (addr >= 0xFE00 && addr <= 0xFE9F) {
            return oam[addr - 0xFE00];
        }

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
            default: return 0xFF;
        }
    }

    void write(u16 addr, u8 val) {
        if (addr >= 0x8000 && addr <= 0x9FFF) {
            vram[addr - 0x8000] = val;
        } else if (addr >= 0xFE00 && addr <= 0xFE9F) {
            oam[addr - 0xFE00] = val;
        } else {
            switch (addr) {
                case 0xFF40: lcdc = val; break;
                case 0xFF41: stat = (stat & 0x07) | (val & 0xF8); break; // Low 3 bits are read-only
                case 0xFF42: scy = val; break;
                case 0xFF43: scx = val; break;
                case 0xFF44: ly = 0; break; // Writing to LY resets it
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
