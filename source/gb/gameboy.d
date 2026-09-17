/**
 * Game Boy System Coordinator
 *
 * Orchestrates the CPU, MMU, PPU, and Timer components to simulate real-time
 * Game Boy execution at ~59.73 frames per second.
 *
 * Emulation Loop Architecture:
 * - 1 Game Boy frame = 154 scanlines * 456 T-cycles = 70,224 T-cycles.
 * - In each step of the frame loop:
 *   1. CPU executes one instruction via `cpu.step(mmu)`, returning T-cycles consumed.
 *   2. Timer steps forward by that many cycles; triggers Timer interrupt on overflow.
 *   3. PPU steps forward by that many cycles, generating scanlines and STAT/VBlank interrupts.
 *   4. Any generated interrupts are raised in MMU's IF register (0xFF0F).
 */
module gb.gameboy;

import gb.types;
import gb.cpu;
import gb.mmu;
import gb.rom;
import w4 = wasm4;

struct GameBoy {
    CPU cpu;
    MMU mmu;
    uint totalFrames = 0;

    void init() {
        cpu.reset();
        mmu.reset();
        mmu.setRom(DEBUG_ROM);
        totalFrames = 0;
    }

    void loadCustomRom(const(u8)[] rom, u8[] ram = null) {
        cpu.reset();
        mmu.reset();
        mmu.setRom(rom);
        if (ram !is null) {
            mmu.setCartRam(ram);
        }
        totalFrames = 0;
    }

    /**
     * Executes one complete frame (70,224 clock cycles) with input sampling.
     */
    void stepFrame(ubyte gp1, ubyte gp2 = 0, ubyte mouse = 0) {
        bool btnA      = (gp1 & w4.button1) != 0;
        bool btnB      = (gp1 & w4.button2) != 0;
        bool btnSelect = (gp2 & w4.button1) != 0 || (mouse & w4.mouseRight) != 0;
        bool btnStart  = (gp2 & w4.button2) != 0 || (mouse & w4.mouseLeft) != 0 ||
                         ((gp1 & (w4.button1 | w4.button2)) == (w4.button1 | w4.button2));

        mmu.updateInput(
            (gp1 & w4.buttonRight) != 0,
            (gp1 & w4.buttonLeft)  != 0,
            (gp1 & w4.buttonUp)    != 0,
            (gp1 & w4.buttonDown)  != 0,
            btnA,
            btnB,
            btnSelect,
            btnStart
        );

        // Run 1 frame = 70,224 T-cycles
        uint cyclesThisFrame = 0;
        while (cyclesThisFrame < GB_CYCLES_PER_FRAME) {
            uint cycles = cpu.step(mmu);
            cyclesThisFrame += cycles;

            if (mmu.timer.step(cycles)) mmu.iflag |= INT_TIMER;
            u8 ppuInts = mmu.ppu.step(cycles);
            if (ppuInts != 0) mmu.iflag |= ppuInts;
        }

        mmu.apu.updateFrame();
        totalFrames++;
    }
}

unittest {
    GameBoy gb;
    gb.init();

    // Verify debug ROM header
    assert(gb.mmu.read(0x0100) == 0x00); // NOP
    assert(gb.mmu.read(0x0101) == 0xC3); // JP 0x0150

    // Run 5 frames
    for (int f = 0; f < 5; f++) {
        gb.stepFrame(0);
    }
    assert(gb.totalFrames == 5);

    // Verify debug ROM populated VRAM tile data & tilemap
    bool vramPopulated = false;
    for (int i = 0x200; i < 0x500; i++) {
        if (gb.mmu.ppu.vram[i] != 0) { vramPopulated = true; break; }
    }
    assert(vramPopulated, "VRAM tile data was not populated");

    bool mapPopulated = false;
    for (int i = 0x1800; i < 0x1800 + 32 * 18; i++) {
        if (gb.mmu.ppu.vram[i] != 0) { mapPopulated = true; break; }
    }
    assert(mapPopulated, "VRAM tilemap was not populated");

    // Verify OAM sprite initialization
    assert(gb.mmu.ppu.oam[2] == 38, "Sprite tile should match smiley glyph");

    // Test input responsiveness: D-Pad Right increments Sprite X
    u8 initialX = gb.mmu.ppu.oam[1];
    for (int f = 0; f < 10; f++) {
        gb.stepFrame(w4.buttonRight);
    }
    assert(gb.mmu.ppu.oam[1] > initialX, "Sprite X should advance when Right is held");

    // Button A increments background SCX
    u8 initialSCX = gb.mmu.ppu.scx;
    for (int f = 0; f < 10; f++) {
        gb.stepFrame(w4.button1);
    }
    assert(gb.mmu.ppu.scx > initialSCX, "SCX should advance when Button 1 is held");

    // Verify framebuffer rendering
    ubyte* fb = w4.framebuffer;
    bool hasPixels = false;
    for (int i = 0; i < 6400; i++) {
        if (fb[i] != 0) { hasPixels = true; break; }
    }
    assert(hasPixels, "Framebuffer should contain non-zero rendered pixels");

    // Pokemon Red verification if ROM is present locally
    import std.file : exists, read;
    if (exists("pokemon_red.gb")) {
        const(ubyte)[] pokeRom = cast(const(ubyte)[])read("pokemon_red.gb");
        assert(pokeRom.length == 524288, "Pokemon Red should be 512KB");

        GameBoy pokeGb;
        ubyte[32768] pokeRam;
        pokeGb.loadCustomRom(pokeRom, pokeRam[]);

        assert(pokeGb.mmu.cartType == 0x03, "Cart type should be MBC1+RAM+BATTERY");
        assert(pokeGb.mmu.numRomBanks == 32, "Pokemon Red should have 32 ROM banks");
        assert(pokeGb.mmu.numRamBanks == 4, "Pokemon Red should have 4 RAM banks");

        // Run 180 frames (approx 3 seconds of in-game time)
        for (int f = 0; f < 180; f++) {
            pokeGb.stepFrame(0);
        }

        assert(pokeGb.totalFrames == 180);
        assert(pokeGb.mmu.ppu.lcdEnable, "LCD should be enabled by Pokemon Red");
        assert(pokeGb.cpu.pc >= 0x0100 && pokeGb.cpu.pc < 0x8000, "PC in valid ROM address range");
    }

    // Super Mario Land verification if ROM is present locally
    if (exists("super_mario_land.gb")) {
        const(ubyte)[] marioRom = cast(const(ubyte)[])read("super_mario_land.gb");
        assert(marioRom.length == 65536, "Super Mario Land should be 64KB");

        GameBoy marioGb;
        marioGb.loadCustomRom(marioRom, null);

        assert(marioGb.mmu.cartType == 0x01, "Cart type should be MBC1");
        assert(marioGb.mmu.numRomBanks == 4, "Super Mario Land should have 4 ROM banks");

        // Run 100 frames to reach title screen
        for (int f = 0; f < 100; f++) {
            marioGb.stepFrame(0);
        }

        assert(marioGb.totalFrames == 100);
        assert(marioGb.mmu.ppu.lcdEnable, "LCD should be enabled by Super Mario Land");
        assert(marioGb.cpu.pc >= 0x0100 && marioGb.cpu.pc < 0x8000, "PC in valid ROM address range");
    }

    import core.stdc.stdio : printf;
    printf("✔ [GameBoy] Integration unittests passed.\n");
}
