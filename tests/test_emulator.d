module test_emulator;

import core.stdc.stdio : printf;
import gb.types;
import gb.cpu;
import gb.mmu;
import gb.timer;
import gb.ppu;
import gb.gameboy;
import gb.rom;
import w4 = wasm4;

int main() {
    printf("=== Starting Game Boy Emulator Tests ===\n\n");

    testCpuBasics();
    testCpuAlu();
    testCpuCb();
    testPpuTiming();
    testDebugRomExecution();

    printf("\n=== All Tests Passed Successfully! ===\n");
    return 0;
}

void testCpuBasics() {
    printf("[1/5] Testing CPU Basics (Registers, Flags, Stack)... ");
    
    CPU cpu;
    MMU mmu;
    cpu.reset();
    mmu.reset();

    // Verify initial DMG register values
    assert(cpu.af == 0x01B0, "Initial AF incorrect");
    assert(cpu.bc == 0x0013, "Initial BC incorrect");
    assert(cpu.de == 0x00D8, "Initial DE incorrect");
    assert(cpu.hl == 0x014D, "Initial HL incorrect");
    assert(cpu.sp == 0xFFFE, "Initial SP incorrect");
    assert(cpu.pc == 0x0100, "Initial PC incorrect");

    // Test flags
    cpu.flagZ = true;
    assert((cpu.f & FLAG_Z) != 0);
    assert(cpu.flagZ);
    cpu.flagZ = false;
    assert(!cpu.flagZ);

    cpu.flagC = true;
    assert(cpu.flagC);
    cpu.flagC = false;
    assert(!cpu.flagC);

    // Test 16-bit register modification
    cpu.hl = 0xC000;
    assert(cpu.h == 0xC0 && cpu.l == 0x00);
    cpu.incHL();
    assert(cpu.hl == 0xC001);
    cpu.decHL();
    assert(cpu.hl == 0xC000);

    printf("PASSED\n");
}

void testCpuAlu() {
    printf("[2/5] Testing CPU ALU Operations... ");

    CPU cpu;
    MMU mmu;
    cpu.reset();
    mmu.reset();

    // Test ADD A, n (opcode 0xC6)
    // Put code at 0xC000: LD A, 0x0F; ADD A, 0x01; HALT
    mmu.wram[0] = 0x3E; // LD A, 0x0F
    mmu.wram[1] = 0x0F;
    mmu.wram[2] = 0xC6; // ADD A, 0x01
    mmu.wram[3] = 0x01;
    mmu.wram[4] = 0x76; // HALT
    cpu.pc = 0xC000;

    cpu.step(mmu); // LD A, 0x0F
    assert(cpu.a == 0x0F);
    
    cpu.step(mmu); // ADD A, 0x01
    assert(cpu.a == 0x10);
    assert(!cpu.flagZ);
    assert(!cpu.flagN);
    assert(cpu.flagH); // 0x0F + 1 causes half-carry
    assert(!cpu.flagC);

    // Test SUB 0x10 -> A = 0, Z=1, N=1, H=0, C=0
    mmu.wram[5] = 0xD6; // SUB 0x10
    mmu.wram[6] = 0x10;
    cpu.pc = 0xC005;
    cpu.step(mmu);
    assert(cpu.a == 0x00);
    assert(cpu.flagZ);
    assert(cpu.flagN);
    assert(!cpu.flagC);

    printf("PASSED\n");
}

void testCpuCb() {
    printf("[3/5] Testing CB Bit Manipulation & Rotates... ");

    CPU cpu;
    MMU mmu;
    cpu.reset();
    mmu.reset();

    // Test SWAP A (CB 37)
    // Put code at 0xC000: LD A, 0xA5; CB 37 (SWAP A); HALT
    mmu.wram[0] = 0x3E;
    mmu.wram[1] = 0xA5;
    mmu.wram[2] = 0xCB;
    mmu.wram[3] = 0x37; // SWAP A
    cpu.pc = 0xC000;

    cpu.step(mmu);
    assert(cpu.a == 0xA5);

    cpu.step(mmu); // SWAP A -> 0x5A
    assert(cpu.a == 0x5A);
    assert(!cpu.flagZ);

    // Test BIT 3, A (CB 5F) -> bit 3 of 0x5A (0101 1010) is 1 -> Z=0
    mmu.wram[4] = 0xCB;
    mmu.wram[5] = 0x5F; // BIT 3, A
    cpu.pc = 0xC004;
    cpu.step(mmu);
    assert(!cpu.flagZ);
    assert(cpu.flagH);

    // Test BIT 2, A (CB 57) -> bit 2 of 0x5A is 0 -> Z=1
    mmu.wram[6] = 0xCB;
    mmu.wram[7] = 0x57; // BIT 2, A
    cpu.pc = 0xC006;
    cpu.step(mmu);
    assert(cpu.flagZ);

    // Test SET 2, A (CB D7) -> sets bit 2: 0x5A | 4 = 0x5E
    mmu.wram[8] = 0xCB;
    mmu.wram[9] = 0xD7; // SET 2, A
    cpu.pc = 0xC008;
    cpu.step(mmu);
    assert(cpu.a == 0x5E);

    // Test RES 2, A (CB 97) -> clears bit 2: 0x5E & ~4 = 0x5A
    mmu.wram[10] = 0xCB;
    mmu.wram[11] = 0x97; // RES 2, A
    cpu.pc = 0xC00A;
    cpu.step(mmu);
    assert(cpu.a == 0x5A);

    printf("PASSED\n");
}

void testPpuTiming() {
    printf("[4/5] Testing PPU Scanline & VBlank Timing... ");

    PPU ppu;
    ppu.reset();
    assert(ppu.ly == 0);

    // Step 456 cycles = 1 scanline
    ppu.step(456);
    assert(ppu.ly == 1);

    // Step to line 144 (VBlank)
    u8 interrupts = 0;
    while (ppu.ly < 144) {
        interrupts |= ppu.step(456);
    }
    assert(ppu.ly == 144);
    assert((interrupts & INT_VBLANK) != 0, "VBlank interrupt not triggered at line 144");

    // Step to line 153 and wrap to line 0
    while (ppu.ly > 0) {
        ppu.step(456);
    }
    assert(ppu.ly == 0, "Scanlines did not wrap to 0 after line 153");

    printf("PASSED\n");
}

void testDebugRomExecution() {
    printf("[5/5] Testing Debug ROM Execution with GameBoy System... ");

    GameBoy gb;
    gb.init();

    // Verify ROM is loaded at 0x0100
    assert(gb.mmu.read(0x0100) == 0x00); // NOP
    assert(gb.mmu.read(0x0101) == 0xC3); // JP 0x0150
    assert(gb.mmu.read(0x0102) == 0x50);
    assert(gb.mmu.read(0x0103) == 0x01);

    // Run 1 frame (70,224 cycles)
    gb.stepFrame(0);

    // Verify CPU progressed and executed instructions
    printf("\n      [Frame 1] PC = 0x%04X, SP = 0x%04X, LY = %d\n", gb.cpu.pc, gb.cpu.sp, gb.mmu.ppu.ly);

    // Run 5 frames
    for (int f = 0; f < 5; f++) {
        gb.stepFrame(0);
    }
    printf("      [Frame 6] PC = 0x%04X, SP = 0x%04X\n", gb.cpu.pc, gb.cpu.sp);

    // Verify that VRAM has been populated by the debug ROM
    // Tile 1 should have non-zero data
    bool vramHasData = false;
    for (int i = 0x200; i < 0x500; i++) {
        if (gb.mmu.ppu.vram[i] != 0) {
            vramHasData = true;
            break;
        }
    }
    assert(vramHasData, "Debug ROM failed to copy tile data into VRAM!");

    // Verify that the tilemap at 0x9800 (offset 0x1800 in VRAM) has data
    bool mapHasData = false;
    for (int i = 0x1800; i < 0x1800 + 32 * 18; i++) {
        if (gb.mmu.ppu.vram[i] != 0) {
            mapHasData = true;
            break;
        }
    }
    assert(mapHasData, "Debug ROM failed to copy tilemap into 0x9800!");

    // Verify that OAM has sprite 0
    u8 spriteY = gb.mmu.ppu.oam[0];
    u8 spriteX = gb.mmu.ppu.oam[1];
    u8 spriteTile = gb.mmu.ppu.oam[2];
    printf("      Sprite 0: Y=%d, X=%d, Tile=%d\n", spriteY, spriteX, spriteTile);
    assert(spriteTile == 38, "Sprite tile should match smiley tile index");

    // Test Joypad Input: Press D-Pad Right for 10 frames
    // In our ROM, Right increments Sprite X
    u8 initialX = spriteX;
    for (int f = 0; f < 10; f++) {
        gb.stepFrame(w4.buttonRight);
    }
    u8 newX = gb.mmu.ppu.oam[1];
    printf("      Sprite X after pressing Right: %d (initially %d)\n", newX, initialX);
    assert(newX > initialX, "Sprite X should increase when D-Pad Right is pressed!");

    // Test Joypad Input: Press Button 1 (A) for 10 frames
    // In our ROM, Button A increments SCX
    u8 initialSCX = gb.mmu.ppu.scx;
    for (int f = 0; f < 10; f++) {
        gb.stepFrame(w4.button1);
    }
    u8 newSCX = gb.mmu.ppu.scx;
    printf("      SCX after pressing Button A: %d (initially %d)\n", newSCX, initialSCX);
    assert(newSCX > initialSCX, "SCX should increment when Button A is pressed!");

    // Verify framebuffer has rendered non-zero pixels
    ubyte* fb = w4.framebuffer;
    bool fbHasPixels = false;
    for (int i = 0; i < 6400; i++) {
        if (fb[i] != 0) {
            fbHasPixels = true;
            break;
        }
    }
    assert(fbHasPixels, "Framebuffer should contain rendered pixels from PPU!");

    // Save screenshot to PPM
    import core.stdc.stdio : fopen, fputs, fputc, fclose, FILE;
    FILE* fp = fopen("screenshot.ppm".ptr, "wb".ptr);
    if (fp !is null) {
        fputs("P6\n160 160\n255\n".ptr, fp);
        // Palette colors (RGB)
        ubyte[3][4] palRgb = [
            [224, 248, 208], // 0: Lightest
            [136, 192, 112], // 1: Light
            [52, 104, 86],   // 2: Dark
            [8, 24, 32]      // 3: Darkest
        ];
        for (int y = 0; y < 160; y++) {
            for (int col = 0; col < 40; col++) {
                ubyte b = fb[y * 40 + col];
                u8[4] px = [
                    cast(u8)(b & 3),
                    cast(u8)((b >> 2) & 3),
                    cast(u8)((b >> 4) & 3),
                    cast(u8)((b >> 6) & 3)
                ];
                for (int p = 0; p < 4; p++) {
                    fputc(palRgb[px[p]][0], fp);
                    fputc(palRgb[px[p]][1], fp);
                    fputc(palRgb[px[p]][2], fp);
                }
            }
        }
        fclose(fp);
        printf("      Dumped screenshot.ppm successfully\n");
    }

    printf("      PASSED\n");
}
