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

    void loadCustomRom(const(u8)[] rom) {
        cpu.reset();
        mmu.reset();
        mmu.setRom(rom);
        totalFrames = 0;
    }

    void stepFrame(ubyte gamepad) {
        // Map WASM-4 gamepad to Game Boy buttons
        mmu.updateInput(
            (gamepad & w4.buttonRight) != 0,
            (gamepad & w4.buttonLeft)  != 0,
            (gamepad & w4.buttonUp)    != 0,
            (gamepad & w4.buttonDown)  != 0,
            (gamepad & w4.button1)     != 0,
            (gamepad & w4.button2)     != 0,
            false, // Select
            false  // Start
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

    import core.stdc.stdio : printf;
    printf("✔ [GameBoy] Integration unittests passed.\n");
}
