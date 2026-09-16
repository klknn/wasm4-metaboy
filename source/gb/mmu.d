module gb.mmu;

import gb.types;
import gb.ppu;
import gb.timer;
import w4 = wasm4;

struct MMU {
    const(u8)* romData = null;
    size_t     romSize = 0;

    u8[8192] wram;      // 0xC000 - 0xDFFF (Work RAM)
    u8[128]  hram;      // 0xFF80 - 0xFFFE (High RAM)

    u8 iflag = 0xE1;    // 0xFF0F Interrupt Flag
    u8 ie    = 0x00;    // 0xFFFF Interrupt Enable

    // Joypad state
    u8 joypSelect = 0x30; // 0xFF00 select bits (bits 4 and 5)
    u8 joypadButtons = 0xFF; // Active low: bits: Down, Up, Left, Right
    u8 joypadActions = 0xFF; // Active low: bits: Start, Select, B, A

    // Serial transfer
    u8 sb = 0x00;       // 0xFF01
    u8 sc = 0x7E;       // 0xFF02

    PPU   ppu;
    Timer timer;

    void reset() {
        foreach (ref b; wram) b = 0;
        foreach (ref b; hram) b = 0;
        iflag = 0xE1;
        ie    = 0x00;
        joypSelect = 0x30;
        joypadButtons = 0xFF;
        joypadActions = 0xFF;
        sb = 0;
        sc = 0x7E;
        ppu.reset();
        timer.reset();
    }

    void setRom(const(u8)[] rom) {
        romData = rom.ptr;
        romSize = rom.length;
    }

    // Set joypad input from active-high button states:
    // [right, left, up, down, a, b, select, start]
    void updateInput(bool right, bool left, bool up, bool down, bool a, bool b, bool select, bool start) {
        u8 dir = 0x0F;
        if (right) dir &= ~0x01;
        if (left)  dir &= ~0x02;
        if (up)    dir &= ~0x04;
        if (down)  dir &= ~0x08;
        joypadButtons = dir;

        u8 act = 0x0F;
        if (a)      act &= ~0x01;
        if (b)      act &= ~0x02;
        if (select) act &= ~0x04;
        if (start)  act &= ~0x08;
        joypadActions = act;
    }

    u8 read(u16 addr) const {
        if (addr < 0x8000) {
            // Cartridge ROM
            if (romData !is null && addr < romSize) {
                return romData[addr];
            }
            return 0xFF;
        } else if (addr >= 0x8000 && addr <= 0x9FFF) {
            // VRAM
            return ppu.read(addr);
        } else if (addr >= 0xA000 && addr <= 0xBFFF) {
            // External RAM (unmapped for minimal ROMs)
            return 0xFF;
        } else if (addr >= 0xC000 && addr <= 0xDFFF) {
            // WRAM
            return wram[addr - 0xC000];
        } else if (addr >= 0xE000 && addr <= 0xFDFF) {
            // Echo RAM
            return wram[addr - 0xE000];
        } else if (addr >= 0xFE00 && addr <= 0xFE9F) {
            // OAM
            return ppu.read(addr);
        } else if (addr >= 0xFEA0 && addr <= 0xFEFF) {
            // Not usable
            return 0xFF;
        } else if (addr == 0xFF00) {
            // Joypad
            u8 res = joypSelect | 0xCF;
            if ((joypSelect & 0x10) == 0) {
                res &= (joypadButtons | 0xF0);
            }
            if ((joypSelect & 0x20) == 0) {
                res &= (joypadActions | 0xF0);
            }
            return res;
        } else if (addr == 0xFF01) {
            return sb;
        } else if (addr == 0xFF02) {
            return sc | 0x7E;
        } else if (addr >= 0xFF04 && addr <= 0xFF07) {
            // Timer
            return timer.read(addr);
        } else if (addr == 0xFF0F) {
            return iflag | 0xE0;
        } else if (addr >= 0xFF40 && addr <= 0xFF4B) {
            // PPU registers
            return ppu.read(addr);
        } else if (addr >= 0xFF80 && addr <= 0xFFFE) {
            // HRAM
            return hram[addr - 0xFF80];
        } else if (addr == 0xFFFF) {
            // IE
            return ie;
        }

        return 0xFF;
    }

    void write(u16 addr, u8 val) {
        if (addr < 0x8000) {
            // ROM write (for MBC banking, ignore for simple 32KB ROM)
            return;
        } else if (addr >= 0x8000 && addr <= 0x9FFF) {
            // VRAM
            ppu.write(addr, val);
        } else if (addr >= 0xA000 && addr <= 0xBFFF) {
            // External RAM
            return;
        } else if (addr >= 0xC000 && addr <= 0xDFFF) {
            // WRAM
            wram[addr - 0xC000] = val;
        } else if (addr >= 0xE000 && addr <= 0xFDFF) {
            // Echo RAM
            wram[addr - 0xE000] = val;
        } else if (addr >= 0xFE00 && addr <= 0xFE9F) {
            // OAM
            ppu.write(addr, val);
        } else if (addr >= 0xFEA0 && addr <= 0xFEFF) {
            return;
        } else if (addr == 0xFF00) {
            joypSelect = val & 0x30;
        } else if (addr == 0xFF01) {
            sb = val;
        } else if (addr == 0xFF02) {
            sc = val;
            // If transfer requested with internal clock (debug output)
            if (val == 0x81) {
                // Serial debug output character
                char[2] buf = [cast(char)sb, '\0'];
                w4.trace(buf.ptr);
                sc &= 0x7F; // Transfer completed
                iflag |= INT_SERIAL;
            }
        } else if (addr >= 0xFF04 && addr <= 0xFF07) {
            timer.write(addr, val);
        } else if (addr == 0xFF0F) {
            iflag = val;
        } else if (addr >= 0xFF40 && addr <= 0xFF45 || (addr >= 0xFF47 && addr <= 0xFF4B)) {
            ppu.write(addr, val);
        } else if (addr == 0xFF46) {
            // OAM DMA Transfer: Copy 160 bytes from source xx00-xx9F to OAM FE00-FE9F
            u16 srcBase = cast(u16)(val << 8);
            for (u16 i = 0; i < 160; i++) {
                ppu.oam[i] = read(cast(u16)(srcBase + i));
            }
        } else if (addr >= 0xFF80 && addr <= 0xFFFE) {
            hram[addr - 0xFF80] = val;
        } else if (addr == 0xFFFF) {
            ie = val;
        }
    }
}
