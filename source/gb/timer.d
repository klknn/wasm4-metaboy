/**
 * Game Boy Timer and Divider Registers (Pan Docs Reference)
 * https://gbdev.io/pandocs/Timer_and_Divider_Registers.html
 *
 * The Game Boy contains an internal 16-bit counter that increments every T-cycle
 * at the master oscillator clock rate of 4,194,304 Hz (4.194304 MHz).
 *
 * Memory Mapped Registers:
 * - 0xFF04 (DIV):  Divider Register. Mapped directly to the upper 8 bits of the
 *                  internal 16-bit counter (internalCounter >> 8). It increments
 *                  every 256 T-cycles (16,384 Hz). Writing ANY value to 0xFF04
 *                  resets the entire 16-bit counter to 0.
 * - 0xFF05 (TIMA): Timer Counter. Increments at the clock frequency selected by TAC.
 *                  When TIMA overflows (0xFF -> 0x00), it reloads the value from TMA
 *                  and requests a Timer interrupt (bit 2 of IF register, 0xFF0F).
 * - 0xFF06 (TMA):  Timer Modulo. When TIMA overflows, it is reloaded with this value.
 * - 0xFF07 (TAC):  Timer Control.
 *                  - Bit 2: Timer Enable (0 = Disable, 1 = Enable).
 *                  - Bits 1-0: Input Clock Select:
 *                    00: 4,096 Hz   (every 1024 T-cycles, bit 9 falling edge)
 *                    01: 262,144 Hz (every 16 T-cycles,   bit 3 falling edge)
 *                    10: 65,536 Hz  (every 64 T-cycles,   bit 5 falling edge)
 *                    11: 16,384 Hz  (every 256 T-cycles,  bit 7 falling edge)
 *                  - Bits 7-3: Unused, always read as 1 (0xF8 mask).
 */
module gb.timer;

import gb.types;
import std.bitmanip : bitfields;

struct Timer {
    u16 internalCounter = 0xABCC; // Initial DMG boot value; upper byte is DIV (0xFF04)
    u8 tima = 0;                  // 0xFF05: Timer Counter
    u8 tma  = 0;                  // 0xFF06: Timer Modulo

    // 0xFF07: Timer Control (TAC) implemented with std.bitmanip.bitfields
    union {
        u8 tac = 0xF8;
        mixin(bitfields!(
            uint, "clockSelect", 2, // Bits 0-1: 00=1024T, 01=16T, 10=64T, 11=256T
            bool, "enabled",     1, // Bit 2: Timer Enable flag
            uint, "_padTac",     5  // Bits 3-7: Unused, reads as 1 on DMG
        ));
    }

    void reset() {
        internalCounter = 0xABCC;
        tima = 0;
        tma  = 0;
        tac  = 0xF8;
    }

    /**
     * Steps the timer by the given number of CPU T-cycles.
     * Returns true if a Timer Interrupt should be triggered.
     *
     * In real Game Boy hardware, TIMA increments on the falling edge of the selected
     * bit of the internal counter ANDed with the TAC enable bit.
     */
    bool step(uint cycles) {
        if (cycles == 0) return false;

        uint start = internalCounter;
        internalCounter += cast(u16)cycles;

        if (!enabled) return false; // Timer is disabled via TAC bit 2

        // TAC clock bits: 00: bit 9 (1024T), 01: bit 3 (16T), 10: bit 5 (64T), 11: bit 7 (256T)
        immutable uint[4] bitIndex = [9, 3, 5, 7];
        uint bit = bitIndex[clockSelect];

        // Number of falling edges during this interval
        uint edges = ((start + cycles) >> (bit + 1)) - (start >> (bit + 1));
        if (edges == 0) return false;

        bool interrupt = false;
        while (edges-- > 0) {
            if (tima == 0xFF) {
                tima = tma;       // Reload modulo
                interrupt = true; // Request INT_TIMER
            } else {
                tima++;
            }
        }
        return interrupt;
    }

    u8 read(u16 addr) const {
        switch (addr) {
            case 0xFF04: return cast(u8)(internalCounter >> 8); // DIV is upper byte
            case 0xFF05: return tima;
            case 0xFF06: return tma;
            case 0xFF07: return tac | 0xF8; // Bits 3-7 are unused and always 1
            default:     return 0xFF;
        }
    }

    void write(u16 addr, u8 val) {
        switch (addr) {
            case 0xFF04: internalCounter = 0; break; // Any write to DIV resets the counter
            case 0xFF05: tima = val; break;
            case 0xFF06: tma  = val; break;
            case 0xFF07: tac  = val | 0xF8; break;
            default: break;
        }
    }
}

unittest {
    Timer timer;
    timer.reset();

    // DIV read and reset
    assert(timer.read(0xFF04) == 0xAB);
    timer.write(0xFF04, 0x12);
    assert(timer.read(0xFF04) == 0x00);

    // Enable timer at 262,144 Hz (bit 3, every 16 T-cycles)
    timer.write(0xFF07, 0x05); // TAC: enabled, clock 01 (bit 3)
    timer.write(0xFF06, 0xA0); // TMA modulo
    timer.write(0xFF05, 0xFE); // TIMA

    // Step 8 cycles: counter bit 3 goes high
    assert(!timer.step(8));
    assert(timer.tima == 0xFE);

    // Step 8 cycles: counter bit 3 falls -> TIMA increments to 0xFF
    assert(!timer.step(8));
    assert(timer.tima == 0xFF);

    // Step 16 cycles: falling edge -> TIMA overflows to TMA (0xA0) and triggers interrupt
    assert(timer.step(16));
    assert(timer.tima == 0xA0);

    import core.stdc.stdio : printf;
    printf("✔ [Timer] Unittests passed.\n");
}
