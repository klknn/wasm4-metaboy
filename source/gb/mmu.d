/**
 * Game Boy Memory Management Unit (MMU) & Memory Banking Controller (MBC)
 *
 * Pan Docs References:
 * - Memory Map:  https://gbdev.io/pandocs/Memory_Map.html
 * - MBC1:        https://gbdev.io/pandocs/MBC1.html
 * - Joypad:      https://gbdev.io/pandocs/Joypad_Input.html
 * - Interrupts:  https://gbdev.io/pandocs/Interrupts.html
 *
 * ----------------------------------------------------------------------------
 * Game Boy 16-bit (64 KiB) Address Map:
 * ----------------------------------------------------------------------------
 * 0x0000 - 0x3FFF | 16 KiB ROM Bank 00        | From cartridge, usually non-switchable
 * 0x4000 - 0x7FFF | 16 KiB Switchable ROM Bank | Bank 01..NN switchable via MBC
 * 0x8000 - 0x9FFF |  8 KiB Video RAM (VRAM)   | Tile data & tilemaps (managed by PPU)
 * 0xA000 - 0xBFFF |  8 KiB External Cart RAM   | Cartridge SRAM (battery backed in saves)
 * 0xC000 - 0xCFFF |  4 KiB Work RAM (WRAM) B0  | Internal system RAM
 * 0xD000 - 0xDFFF |  4 KiB Work RAM (WRAM) B1  | Internal system RAM
 * 0xE000 - 0xFDFF |  Echo RAM (prohibited)     | Mirrors 0xC000..0xDDFF
 * 0xFE00 - 0xFE9F |  Sprite OAM (160 bytes)    | 40 sprite attributes (managed by PPU)
 * 0xFEA0 - 0xFEFF |  Unusable Memory           | Reads 0xFF, writes ignored
 * 0xFF00 - 0xFF7F |  I/O Registers             | Joypad, Timer, Serial, PPU, Audio, DMA
 * 0xFF80 - 0xFFFE |  High RAM (HRAM) (127 B)   | Fast zero-page RAM
 * 0xFFFF          |  Interrupt Enable (IE)     | 1 byte interrupt mask
 * ----------------------------------------------------------------------------
 *
 * MBC1 Banking Registers:
 * - 0x0000 - 0x1FFF: RAM Enable (writing 0x0A enables RAM, any other value disables)
 * - 0x2000 - 0x3FFF: ROM Bank Number (lower 5 bits: 1..31; 0 is translated to 1)
 * - 0x4000 - 0x5FFF: RAM Bank Number (0..3) or Upper 2 bits of ROM Bank (bits 5-6)
 * - 0x6000 - 0x7FFF: Banking Mode Select (0 = ROM banking mode, 1 = RAM banking mode)
 */
module gb.mmu;

import gb.types;
import gb.ppu;
import gb.timer;
import std.bitmanip : bitfields;
import w4 = wasm4;

struct MMU {
    const(u8)* romData = null;
    size_t     romSize = 0;

    u8*        cartRam = null;
    size_t     cartRamSize = 0;

    // MBC1 Registers
    u8   cartType = 0;
    u8   romBank5 = 1;       // 5-bit ROM bank register (1..31)
    u8   ramBank = 0;        // 2-bit RAM bank / upper ROM bank register (0..3)
    u8   bankingMode = 0;    // 0: ROM banking mode (up to 2MB ROM, 8KB RAM), 1: RAM banking mode
    bool ramEnabled = false;
    uint numRomBanks = 2;
    uint numRamBanks = 0;

    u8[8192] wram;      // 0xC000 - 0xDFFF (Work RAM)
    u8[128]  hram;      // 0xFF80 - 0xFFFE (High RAM)

    // 0xFF0F: Interrupt Flag (IF) - active interrupt requests
    // Pan Docs: https://gbdev.io/pandocs/Interrupts.html#ff0f--if-interrupt-flag
    union {
        u8 iflag = 0xE1;
        mixin(bitfields!(
            bool, "ifVBlank", 1, // Bit 0: VBlank interrupt request
            bool, "ifStat",   1, // Bit 1: LCD STAT interrupt request
            bool, "ifTimer",  1, // Bit 2: Timer interrupt request
            bool, "ifSerial", 1, // Bit 3: Serial interrupt request
            bool, "ifJoypad", 1, // Bit 4: Joypad interrupt request
            uint, "_padIF",   3  // Bits 5-7: Unused, always read as 1 on DMG
        ));
    }

    u8 ie    = 0x00;    // 0xFFFF: Interrupt Enable (IE) mask

    // 0xFF00: Joypad register (P1 / JOYP)
    // Pan Docs: https://gbdev.io/pandocs/Joypad_Input.html
    union {
        u8 joypSelect = 0x30;
        mixin(bitfields!(
            uint, "_padJoyLower",   4, // Bits 0-3: Read-only button states
            bool, "selectDirection", 1, // Bit 4: 0 = select directional keys
            bool, "selectAction",    1, // Bit 5: 0 = select action buttons
            uint, "_padJoyUpper",   2  // Bits 6-7: Unused, always 1 on DMG
        ));
    }
    u8 joypadButtons = 0xFF; // Down, Up, Left, Right (active low: 0 = pressed)
    u8 joypadActions = 0xFF; // Start, Select, B, A (active low: 0 = pressed)

    // Serial Data Transfer
    u8 sb = 0x00;       // 0xFF01: Serial transfer data
    u8 sc = 0x7E;       // 0xFF02: Serial transfer control

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
        resetCart();
    }

    void setRom(const(u8)[] rom) {
        romData = rom.ptr;
        romSize = rom.length;
        resetCart();
    }

    void setCartRam(u8[] ram) {
        cartRam = ram.ptr;
        cartRamSize = ram.length;
    }

    void resetCart() {
        if (romData !is null && romSize >= 0x150) {
            cartType = romData[0x0147];
            u8 romCode = romData[0x0148];
            numRomBanks = (romCode <= 0x08) ? (2 << romCode) : 2;
            u8 ramCode = romData[0x0149];
            switch (ramCode) {
                case 1: numRamBanks = 1; break; // 2KB
                case 2: numRamBanks = 1; break; // 8KB
                case 3: numRamBanks = 4; break; // 32KB (Pokemon Red)
                case 4: numRamBanks = 16; break; // 128KB
                case 5: numRamBanks = 8; break; // 64KB
                default: numRamBanks = 0; break;
            }
        } else {
            cartType = 0;
            numRomBanks = 2;
            numRamBanks = 0;
        }
        romBank5 = 1;
        ramBank = 0;
        bankingMode = 0;
        ramEnabled = false;
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
        if (addr < 0x4000) { // ROM Bank 00
            if (romData is null || romSize == 0) return 0xFF;
            size_t bank = 0;
            if (bankingMode == 1 && (cartType >= 1 && cartType <= 3)) {
                bank = ((ramBank << 5) & (numRomBanks - 1));
            }
            size_t offset = bank * 16384 + addr;
            return offset < romSize ? romData[offset] : 0xFF;
        } else if (addr < 0x8000) { // Switchable ROM Bank 01..31
            if (romData is null || romSize == 0) return 0xFF;
            size_t bank = 1;
            if (cartType >= 1 && cartType <= 3) { // MBC1
                size_t rawBank = ((ramBank & 3) << 5) | (romBank5 == 0 ? 1 : romBank5);
                bank = rawBank & (numRomBanks - 1);
            }
            size_t offset = bank * 16384 + (addr - 0x4000);
            return offset < romSize ? romData[offset] : 0xFF;
        } else if (addr < 0xA000) { // VRAM
            return ppu.read(addr);
        } else if (addr < 0xC000) { // External Cartridge RAM
            if (!ramEnabled || cartRam is null || numRamBanks == 0) return 0xFF;
            size_t bank = (bankingMode == 1) ? (ramBank & (numRamBanks - 1)) : 0;
            size_t offset = bank * 8192 + (addr - 0xA000);
            return offset < cartRamSize ? cartRam[offset] : 0xFF;
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
            if (!selectDirection) res &= (joypadButtons | 0xF0);
            if (!selectAction)    res &= (joypadActions | 0xF0);
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
        if (addr < 0x2000) { // 0x0000 - 0x1FFF: RAM Enable
            if (cartType >= 1 && cartType <= 3) {
                ramEnabled = ((val & 0x0F) == 0x0A);
            }
        } else if (addr < 0x4000) { // 0x2000 - 0x3FFF: ROM Bank Number
            if (cartType >= 1 && cartType <= 3) {
                u8 b = val & 0x1F;
                romBank5 = (b == 0) ? 1 : b;
            }
        } else if (addr < 0x6000) { // 0x4000 - 0x5FFF: RAM Bank / Upper ROM Bank
            if (cartType >= 1 && cartType <= 3) {
                ramBank = val & 0x03;
            }
        } else if (addr < 0x8000) { // 0x6000 - 0x7FFF: Banking Mode Select
            if (cartType >= 1 && cartType <= 3) {
                bankingMode = val & 0x01;
            }
        } else if (addr < 0xA000) {
            ppu.write(addr, val);
        } else if (addr < 0xC000) { // External Cartridge RAM
            if (ramEnabled && cartRam !is null && numRamBanks > 0) {
                size_t bank = (bankingMode == 1) ? (ramBank & (numRamBanks - 1)) : 0;
                size_t offset = bank * 8192 + (addr - 0xA000);
                if (offset < cartRamSize) {
                    cartRam[offset] = val;
                }
            }
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
            if (val & 0x80) { // Serial transfer requested
                if (sb >= 32 && sb < 127) {
                    char[2] buf = [cast(char)sb, '\0'];
                    w4.trace(buf.ptr);
                }
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

    // MBC1 Banking Unittest with synthetic 64KB ROM (4 banks) + 32KB RAM (4 banks)
    u8[65536] testRom;
    testRom[0x0147] = 0x03; // MBC1 + RAM + BATTERY
    testRom[0x0148] = 0x01; // 4 ROM banks
    testRom[0x0149] = 0x03; // 4 RAM banks
    // Tag each bank with distinctive marker at byte 0
    testRom[0 * 16384] = 0x10; // Bank 0
    testRom[1 * 16384] = 0x21; // Bank 1
    testRom[2 * 16384] = 0x32; // Bank 2
    testRom[3 * 16384] = 0x43; // Bank 3

    u8[32768] testRam;
    mmu.setRom(testRom[]);
    mmu.setCartRam(testRam[]);

    // Default: Bank 0 at 0x0000, Bank 1 at 0x4000
    assert(mmu.read(0x0000) == 0x10);
    assert(mmu.read(0x4000) == 0x21);

    // Switch to Bank 2 via 0x2000
    mmu.write(0x2000, 0x02);
    assert(mmu.read(0x4000) == 0x32);

    // Switch to Bank 3
    mmu.write(0x2000, 0x03);
    assert(mmu.read(0x4000) == 0x43);

    // Bank 0 write translates to Bank 1
    mmu.write(0x2000, 0x00);
    assert(mmu.read(0x4000) == 0x21);

    // RAM disabled by default
    assert(mmu.read(0xA000) == 0xFF);
    mmu.write(0xA000, 0x77);
    assert(mmu.read(0xA000) == 0xFF);

    // Enable RAM with 0x0A
    mmu.write(0x0000, 0x0A);
    mmu.write(0xA000, 0x77);
    assert(mmu.read(0xA000) == 0x77);

    // Switch RAM bank in mode 1
    mmu.write(0x6000, 0x01); // Mode 1
    mmu.write(0x4000, 0x01); // RAM bank 1
    mmu.write(0xA000, 0x88);
    assert(mmu.read(0xA000) == 0x88);

    // Switch back to RAM bank 0
    mmu.write(0x4000, 0x00);
    assert(mmu.read(0xA000) == 0x77);

    // Test IF and Joypad bitfield getters
    mmu.iflag = 0xE1;
    assert(mmu.ifVBlank);
    assert(!mmu.ifTimer);
    mmu.write(0xFF00, 0x20); // selectDirection=0, selectAction=1
    assert(!mmu.selectDirection);
    assert(mmu.selectAction);

    import core.stdc.stdio : printf;
    printf("✔ [MMU] Unittests passed.\n");
}
