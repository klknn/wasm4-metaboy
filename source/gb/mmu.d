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

    // Joypad state (0xFF00)
    u8 joypSelect = 0x30;
    u8 joypadButtons = 0xFF; // Down, Up, Left, Right (active low)
    u8 joypadActions = 0xFF; // Start, Select, B, A (active low)

    // Serial
    u8 sb = 0x00;       // 0xFF01
    u8 sc = 0x7E;       // 0xFF02

    PPU   ppu;
    Timer timer;

    void reset() {
        wram[] = 0;
        hram[] = 0;
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
        if (addr < 0x8000) { // Cartridge ROM
            return (romData !is null && addr < romSize) ? romData[addr] : 0xFF;
        } else if (addr < 0xA000) { // VRAM
            return ppu.read(addr);
        } else if (addr < 0xC000) { // External RAM
            return 0xFF;
        } else if (addr < 0xE000) { // WRAM
            return wram[addr - 0xC000];
        } else if (addr < 0xFE00) { // Echo RAM
            return wram[addr - 0xE000];
        } else if (addr < 0xFEA0) { // OAM
            return ppu.read(addr);
        } else if (addr < 0xFF00) { // Unusable
            return 0xFF;
        } else if (addr == 0xFF00) { // Joypad
            u8 res = joypSelect | 0xCF;
            if (!(joypSelect & 0x10)) res &= (joypadButtons | 0xF0);
            if (!(joypSelect & 0x20)) res &= (joypadActions | 0xF0);
            return res;
        } else if (addr == 0xFF01) {
            return sb;
        } else if (addr == 0xFF02) {
            return sc | 0x7E;
        } else if (addr <= 0xFF07) {
            return timer.read(addr);
        } else if (addr == 0xFF0F) {
            return iflag | 0xE0;
        } else if (addr <= 0xFF4B) {
            return ppu.read(addr);
        } else if (addr >= 0xFF80 && addr <= 0xFFFE) {
            return hram[addr - 0xFF80];
        } else if (addr == 0xFFFF) {
            return ie;
        }
        return 0xFF;
    }

    void write(u16 addr, u8 val) {
        if (addr < 0x8000) {
            return; // ROM is read-only
        } else if (addr < 0xA000) {
            ppu.write(addr, val);
        } else if (addr < 0xC000) {
            return;
        } else if (addr < 0xE000) {
            wram[addr - 0xC000] = val;
        } else if (addr < 0xFE00) {
            wram[addr - 0xE000] = val; // Echo RAM
        } else if (addr < 0xFEA0) {
            ppu.write(addr, val);
        } else if (addr < 0xFF00) {
            return;
        } else if (addr == 0xFF00) {
            joypSelect = val & 0x30;
        } else if (addr == 0xFF01) {
            sb = val;
        } else if (addr == 0xFF02) {
            sc = val;
            if (val == 0x81) { // Debug serial output
                char[2] buf = [cast(char)sb, '\0'];
                w4.trace(buf.ptr);
                sc &= 0x7F;
                iflag |= INT_SERIAL;
            }
        } else if (addr <= 0xFF07) {
            timer.write(addr, val);
        } else if (addr == 0xFF0F) {
            iflag = val;
        } else if (addr <= 0xFF45 || (addr >= 0xFF47 && addr <= 0xFF4B)) {
            ppu.write(addr, val);
        } else if (addr == 0xFF46) { // OAM DMA
            u16 src = cast(u16)(val << 8);
            for (u16 i = 0; i < 160; i++) {
                ppu.oam[i] = read(cast(u16)(src + i));
            }
        } else if (addr >= 0xFF80 && addr <= 0xFFFE) {
            hram[addr - 0xFF80] = val;
        } else if (addr == 0xFFFF) {
            ie = val;
        }
    }
}

unittest {
    MMU mmu;
    mmu.reset();

    // WRAM read / write & Echo RAM
    mmu.write(0xC050, 0x42);
    assert(mmu.read(0xC050) == 0x42);
    assert(mmu.read(0xE050) == 0x42); // Echo RAM

    // HRAM
    mmu.write(0xFF85, 0x99);
    assert(mmu.read(0xFF85) == 0x99);

    // Joypad: test D-Pad selection
    mmu.updateInput(true, false, false, false, false, false, false, false); // Right pressed
    mmu.write(0xFF00, 0x20); // Select D-pad (bit 4=0)
    assert((mmu.read(0xFF00) & 0x01) == 0); // Bit 0 is 0 (pressed)
    assert((mmu.read(0xFF00) & 0x02) != 0); // Bit 1 is 1 (not pressed)

    // OAM DMA test: write data to WRAM, trigger DMA to OAM
    for (u16 i = 0; i < 160; i++) {
        mmu.write(cast(u16)(0xC100 + i), cast(u8)(i + 1));
    }
    mmu.write(0xFF46, 0xC1); // Trigger DMA from 0xC100
    for (u16 i = 0; i < 160; i++) {
        assert(mmu.ppu.oam[i] == cast(u8)(i + 1));
    }

    import core.stdc.stdio : printf;
    printf("✔ [MMU] Unittests passed.\n");
}
