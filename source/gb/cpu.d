module gb.cpu;

import gb.types;
import gb.mmu;
import std.bitmanip : bitfields;

/**
 * Game Boy (DMG-01) Sharp SM83 (LR35902) CPU Core
 *
 * Architecture References & Documentation:
 * - Pan Docs CPU Registers & Flags: https://gbdev.io/pandocs/CPU_Registers_and_Flags.html
 * - Pan Docs CPU Instruction Set:   https://gbdev.io/pandocs/CPU_Instruction_Set.html
 * - Pan Docs Interrupt Handling:    https://gbdev.io/pandocs/Interrupts.html
 * - Complete LR35902 Opcode Matrix: https://gbdev.io/gb-opcodes/optables/
 * - The Ultimate Game Boy Talk:     https://www.youtube.com/watch?v=HyzD8pNWDwI
 *
 * Architecture Summary:
 * The Sharp SM83 is an 8-bit microprocessor derived from the Intel 8080 and Zilog Z80:
 * - Clock speed: 4.194304 MHz (4,194,304 T-cycles/second = 1,048,576 M-cycles/second).
 * - 1 Machine Cycle (M-cycle) = 4 Clock Cycles (T-cycles).
 *   All instruction durations, memory accesses, and PPU timings are multiples of 4 T-cycles.
 * - Endianness: Little-Endian (low byte stored at lower address).
 */
struct CPU {
    // ------------------------------------------------------------------------
    // Registers & Flags
    // ------------------------------------------------------------------------

    // Accumulator: primary 8-bit register for math and logic operations.
    // Boot-up value on original Game Boy (DMG) is 0x01.
    u8 a = 0x01;

    // Register F holds CPU status flags in the upper 4 bits; lower 4 bits are always 0.
    // - flagZ (Bit 7 - Zero): Set if the result of an operation is zero.
    // - flagN (Bit 6 - Subtract): Used by DAA; set if the last operation was a subtraction.
    // - flagH (Bit 5 - Half Carry): Set if carry occurred from bit 3 to bit 4 (BCD nibble overflow).
    // - flagC (Bit 4 - Carry): Set if carry occurred from bit 7 (byte overflow) or bit 15 (word overflow).
    // Implemented cleanly with std.bitmanip.bitfields to avoid manual bitmask boilerplate.
    union {
        u8 f = 0xB0;
        mixin(bitfields!(
            uint, "_padF", 4,
            bool, "flagC", 1,
            bool, "flagH", 1,
            bool, "flagN", 1,
            bool, "flagZ", 1
        ));
    }

    // 16-bit register pairs using 8-bit bitfields (Little-Endian layout).
    // BC: Frequently used for loop counters and 16-bit pointers.
    // DE: Frequently used as destination memory pointers.
    // HL: "High-Low", the primary indirect memory pointer (accessed as [HL]).
    union {
        u16 bc = 0x0013;
        mixin(bitfields!(
            u8, "c", 8,
            u8, "b", 8
        ));
    }
    union {
        u16 de = 0x00D8;
        mixin(bitfields!(
            u8, "e", 8,
            u8, "d", 8
        ));
    }
    union {
        u16 hl = 0x014D;
        mixin(bitfields!(
            u8, "l", 8,
            u8, "h", 8
        ));
    }

    u16 sp = 0xFFFE; // Stack Pointer: points to the top of the stack in High RAM.
    u16 pc = 0x0100; // Program Counter: starts at 0x0100 (cartridge entry point after boot ROM).

    bool ime = false;          // Interrupt Master Enable flag.
    bool imeScheduled = false; // Delayed EI: interrupts are enabled AFTER the instruction following EI.
    bool halted = false;       // HALT state: CPU pauses until an interrupt occurs.

    // Combined 16-bit AF property (lower 4 bits of F must always remain 0).
    @property u16 af() const { return cast(u16)((a << 8) | (f & 0xF0)); }
    @property void af(u16 v) { a = cast(u8)(v >> 8); f = cast(u8)(v & 0xF0); }

    void reset() {
        a = 0x01;
        f = 0xB0;
        bc = 0x0013;
        de = 0x00D8;
        hl = 0x014D;
        sp = 0xFFFE;
        pc = 0x0100;
        ime = false;
        imeScheduled = false;
        halted = false;
    }

    // ------------------------------------------------------------------------
    // Step Execution & Interrupt Handling
    // ------------------------------------------------------------------------

    /**
     * Executes one CPU instruction or services a pending interrupt.
     * Returns the number of T-cycles elapsed (multiples of 4).
     */
    uint step(ref MMU mmu) {
        // Delayed EI: enable IME on the instruction following the EI opcode.
        if (imeScheduled) {
            ime = true;
            imeScheduled = false;
        }

        // Check for pending interrupts: IF & IE (only bits 0..4 are valid on DMG)
        u8 pending = mmu.iflag & mmu.ie & 0x1F;
        if (pending != 0) {
            halted = false; // Any pending interrupt wakes the CPU from HALT
            if (ime) {
                ime = false; // Disable further interrupts until re-enabled
                // Priority order: VBlank (0x40), STAT (0x48), Timer (0x50), Serial (0x58), Joypad (0x60)
                immutable u16[5] vectors = [0x0040, 0x0048, 0x0050, 0x0058, 0x0060];
                for (int i = 0; i < 5; i++) {
                    u8 mask = cast(u8)(1 << i);
                    if (pending & mask) {
                        mmu.iflag &= ~mask;  // Clear serviced interrupt flag bit
                        push16(mmu, pc);     // Push current PC to stack
                        pc = vectors[i];     // Jump to interrupt vector
                        return 20;           // Interrupt dispatch takes 5 M-cycles (20 T-cycles)
                    }
                }
            }
        }

        if (halted) return 4; // In HALT state, CPU idles for 1 M-cycle (4 T-cycles)

        u8 opcode = fetch8(mmu);
        return execute(mmu, opcode);
    }

    // ------------------------------------------------------------------------
    // Memory Fetch & Stack Operations
    // ------------------------------------------------------------------------

    private u8 fetch8(ref MMU mmu) {
        u8 val = mmu.read(pc);
        pc++;
        return val;
    }

    private u16 fetch16(ref MMU mmu) {
        u8 lo = fetch8(mmu);
        u8 hi = fetch8(mmu);
        return cast(u16)((hi << 8) | lo);
    }

    private void push16(ref MMU mmu, u16 val) {
        sp--;
        mmu.write(sp, cast(u8)(val >> 8));
        sp--;
        mmu.write(sp, cast(u8)(val & 0xFF));
    }

    private u16 pop16(ref MMU mmu) {
        u8 lo = mmu.read(sp);
        sp++;
        u8 hi = mmu.read(sp);
        sp++;
        return cast(u16)((hi << 8) | lo);
    }

    // Condition codes for conditional JR, JP, CALL, RET:
    // 0: NZ (Not Zero), 1: Z (Zero), 2: NC (No Carry), 3: C (Carry)
    private bool checkCond(u8 cc) const {
        switch (cc) {
            case 0:  return !flagZ; // NZ
            case 1:  return flagZ;  // Z
            case 2:  return !flagC; // NC
            default: return flagC;  // C
        }
    }

    // ------------------------------------------------------------------------
    // Unified Register Accessors
    // ------------------------------------------------------------------------

    // Map 3-bit register index `r` to 8-bit register:
    // 0: B, 1: C, 2: D, 3: E, 4: H, 5: L, 6: (HL), 7: A
    // Reference: Pan Docs Opcode Encoding Table (r = bits 0-2 or 3-5)
    private u8 getReg8(ref MMU mmu, u8 idx) {
        switch (idx) {
            case 0: return b;
            case 1: return c;
            case 2: return d;
            case 3: return e;
            case 4: return h;
            case 5: return l;
            case 6: return mmu.read(hl);
            default: return a;
        }
    }

    private void setReg8(ref MMU mmu, u8 idx, u8 val) {
        switch (idx) {
            case 0: b = val; break;
            case 1: c = val; break;
            case 2: d = val; break;
            case 3: e = val; break;
            case 4: h = val; break;
            case 5: l = val; break;
            case 6: mmu.write(hl, val); break;
            default: a = val; break;
        }
    }

    // Map 2-bit register pair index `rp` to 16-bit register:
    // 0: BC, 1: DE, 2: HL, 3: SP (or AF for stack PUSH/POP)
    // Reference: Pan Docs Opcode Encoding Table (rp = bits 4-5)
    private u16 getReg16(u8 idx, bool stackAf = false) const {
        switch (idx) {
            case 0: return bc;
            case 1: return de;
            case 2: return hl;
            default: return stackAf ? af : sp;
        }
    }

    private void setReg16(u8 idx, u16 val, bool stackAf = false) {
        switch (idx) {
            case 0: bc = val; break;
            case 1: de = val; break;
            case 2: hl = val; break;
            default:
                if (stackAf) af = val;
                else sp = val;
                break;
        }
    }

    // ------------------------------------------------------------------------
    // Arithmetic & Logic Unit (ALU) Operations
    // ------------------------------------------------------------------------

    /**
     * Unifies all 8 standard SM83 ALU operations:
     * 0: ADD, 1: ADC, 2: SUB, 3: SBC, 4: AND, 5: XOR, 6: OR, 7: CP
     *
     * In the SM83 instruction encoding, bits 3..5 select the ALU operation:
     * - 0x80..0xBF: ALU A, r   (format: 10_ooo_rrr)
     * - 0xC6..0xFE: ALU A, n   (format: 11_ooo_110)
     */
    private void aluOp(u8 op, u8 val) {
        switch (op) {
            case 0: aluAdd(val, false); break; // ADD A, s
            case 1: aluAdd(val, true);  break; // ADC A, s
            case 2: aluSub(val, false); break; // SUB s
            case 3: aluSub(val, true);  break; // SBC A, s
            case 4: aluAnd(val);        break; // AND s
            case 5: aluXor(val);        break; // XOR s
            case 6: aluOr(val);         break; // OR s
            default: aluCp(val);        break; // CP s
        }
    }

    private void aluAdd(u8 val, bool withCarry = false) {
        int carry = (withCarry && flagC) ? 1 : 0;
        int res = a + val + carry;
        flagZ = ((res & 0xFF) == 0);
        flagN = false;
        flagH = ((a & 0x0F) + (val & 0x0F) + carry) > 0x0F;
        flagC = res > 0xFF;
        a = cast(u8)res;
    }

    private void aluSub(u8 val, bool withCarry = false) {
        int carry = (withCarry && flagC) ? 1 : 0;
        int res = a - val - carry;
        flagZ = ((res & 0xFF) == 0);
        flagN = true;
        flagH = ((a & 0x0F) - (val & 0x0F) - carry) < 0;
        flagC = res < 0;
        a = cast(u8)res;
    }

    private void aluAnd(u8 val) {
        a &= val;
        flagZ = (a == 0);
        flagN = false;
        flagH = true;
        flagC = false;
    }

    private void aluXor(u8 val) {
        a ^= val;
        flagZ = (a == 0);
        flagN = false;
        flagH = false;
        flagC = false;
    }

    private void aluOr(u8 val) {
        a |= val;
        flagZ = (a == 0);
        flagN = false;
        flagH = false;
        flagC = false;
    }

    private void aluCp(u8 val) {
        int res = a - val;
        flagZ = (res == 0);
        flagN = true;
        flagH = (a & 0x0F) < (val & 0x0F);
        flagC = res < 0;
    }

    private u8 aluInc(u8 val) {
        u8 res = cast(u8)(val + 1);
        flagZ = (res == 0);
        flagN = false;
        flagH = (val & 0x0F) == 0x0F;
        return res;
    }

    private u8 aluDec(u8 val) {
        u8 res = cast(u8)(val - 1);
        flagZ = (res == 0);
        flagN = true;
        flagH = (val & 0x0F) == 0;
        return res;
    }

    private void aluAddHL(u16 val) {
        u32 curHL = hl;
        u32 res = curHL + val;
        flagN = false;
        flagH = ((curHL & 0x0FFF) + (val & 0x0FFF)) > 0x0FFF;
        flagC = res > 0xFFFF;
        hl = cast(u16)res;
    }

    /**
     * DAA: Decimal Adjust Accumulator
     *
     * Reference: https://gbdev.io/pandocs/CPU_Instruction_Set.html#daa
     *
     * In Binary Coded Decimal (BCD), each 4-bit nibble represents a decimal digit (0..9).
     * Standard binary math can result in invalid digits (> 9 or 0xA..0xF).
     *
     * DAA adjusts the accumulator into valid BCD digits:
     * - Addition (N = 0): If low nibble > 9 or H is set, add 0x06.
     *                     If value > 0x9F or C is set, add 0x60 and set C.
     * - Subtraction (N = 1): If H is set, subtract 0x06. If C is set, subtract 0x60.
     * H is always cleared; Z is updated based on the result.
     */
    private void aluDaa() {
        int val = a;
        if (!flagN) {
            if (flagH || (val & 0x0F) > 9) val += 0x06;
            if (flagC || val > 0x9F) {
                val += 0x60;
                flagC = true;
            }
        } else {
            if (flagH) val = (val - 6) & 0xFF;
            if (flagC) val -= 0x60;
        }
        a = cast(u8)val;
        flagZ = (a == 0);
        flagH = false;
    }

    // Rotates and shifts
    private u8 aluRlc(u8 val) {
        u8 cOut = (val & 0x80) != 0 ? 1 : 0;
        u8 res = cast(u8)((val << 1) | cOut);
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluRrc(u8 val) {
        u8 cOut = (val & 0x01) != 0 ? 1 : 0;
        u8 res = cast(u8)((val >> 1) | (cOut << 7));
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluRl(u8 val) {
        u8 oldC = flagC ? 1 : 0;
        u8 cOut = (val & 0x80) != 0 ? 1 : 0;
        u8 res = cast(u8)((val << 1) | oldC);
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluRr(u8 val) {
        u8 oldC = flagC ? 1 : 0;
        u8 cOut = (val & 0x01) != 0 ? 1 : 0;
        u8 res = cast(u8)((val >> 1) | (oldC << 7));
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluSla(u8 val) {
        u8 cOut = (val & 0x80) != 0 ? 1 : 0;
        u8 res = cast(u8)(val << 1);
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluSra(u8 val) {
        u8 cOut = (val & 0x01) != 0 ? 1 : 0;
        u8 res = cast(u8)((val >> 1) | (val & 0x80));
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    private u8 aluSwap(u8 val) {
        u8 res = cast(u8)(((val & 0x0F) << 4) | ((val & 0xF0) >> 4));
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = false;
        return res;
    }

    private u8 aluSrl(u8 val) {
        u8 cOut = (val & 0x01) != 0 ? 1 : 0;
        u8 res = cast(u8)(val >> 1);
        flagZ = (res == 0);
        flagN = false;
        flagH = false;
        flagC = (cOut != 0);
        return res;
    }

    /**
     * Shared SP addition for ADD SP, e (0xE8) and LD HL, SP+e (0xF8).
     *
     * LR35902 Quirk: Unlike 16-bit ADD HL, rr, the flags for SP relative addition
     * are computed exclusively from the lower 8 bits (bit 3->4 for H, bit 7->8 for C).
     * Flags Z and N are always reset to 0.
     */
    private u16 addSp(i8 offset) {
        flagZ = false;
        flagN = false;
        flagH = ((sp & 0x0F) + (offset & 0x0F)) > 0x0F;
        flagC = ((sp & 0xFF) + (offset & 0xFF)) > 0xFF;
        return cast(u16)(sp + offset);
    }

    // ------------------------------------------------------------------------
    // Opcode Dispatcher
    // ------------------------------------------------------------------------

    /**
     * Decodes and executes one SM83 opcode.
     *
     * Reference: https://gbdev.io/pandocs/CPU_Instruction_Set.html
     *
     * The LR35902 instruction set is structured into 4 primary octal groups:
     * - Group 0 (0x00 - 0x3F): Control (NOP, STOP, JR), 16-bit loads/arithmetic, 8-bit INC/DEC/LD immediate.
     * - Group 1 (0x40 - 0x7F): LD r, r' inter-register transfers, plus 0x76 (HALT).
     * - Group 2 (0x80 - 0xBF): ALU A, r arithmetic/logic operations on registers.
     * - Group 3 (0xC0 - 0xFF): Conditional branches, stack operations, high-page I/O, and CB prefix.
     */
    private uint execute(ref MMU mmu, u8 opcode) {
        switch (opcode) {
            // NOP
            case 0x00: return 4;

            // 16-bit Immediate Loads (LD rr, nn: 0x01, 0x11, 0x21, 0x31)
            case 0x01: case 0x11: case 0x21: case 0x31:
                setReg16((opcode >> 4) & 3, fetch16(mmu));
                return 12;

            // LD (rr), A
            case 0x02: mmu.write(bc, a); return 8;
            case 0x12: mmu.write(de, a); return 8;
            case 0x22: mmu.write(hl, a); hl++; return 8; // LD (HL+), A
            case 0x32: mmu.write(hl, a); hl--; return 8; // LD (HL-), A

            // LD A, (rr)
            case 0x0A: a = mmu.read(bc); return 8;
            case 0x1A: a = mmu.read(de); return 8;
            case 0x2A: a = mmu.read(hl); hl++; return 8; // LD A, (HL+)
            case 0x3A: a = mmu.read(hl); hl--; return 8; // LD A, (HL-)

            // LD (nn), SP
            case 0x08: {
                u16 addr = fetch16(mmu);
                mmu.write(addr, cast(u8)(sp & 0xFF));
                mmu.write(cast(u16)(addr + 1), cast(u8)(sp >> 8));
                return 20;
            }

            // 16-bit INC/DEC
            case 0x03: case 0x13: case 0x23: case 0x33: {
                u8 r = (opcode >> 4) & 3;
                setReg16(r, cast(u16)(getReg16(r) + 1));
                return 8;
            }
            case 0x0B: case 0x1B: case 0x2B: case 0x3B: {
                u8 r = (opcode >> 4) & 3;
                setReg16(r, cast(u16)(getReg16(r) - 1));
                return 8;
            }

            // ADD HL, rr
            case 0x09: case 0x19: case 0x29: case 0x39:
                aluAddHL(getReg16((opcode >> 4) & 3));
                return 8;

            // 8-bit INC r / (HL)
            case 0x04: case 0x0C: case 0x14: case 0x1C: case 0x24: case 0x2C: case 0x34: case 0x3C: {
                u8 r = (opcode >> 3) & 7;
                setReg8(mmu, r, aluInc(getReg8(mmu, r)));
                return r == 6 ? 12 : 4;
            }

            // 8-bit DEC r / (HL)
            case 0x05: case 0x0D: case 0x15: case 0x1D: case 0x25: case 0x2D: case 0x35: case 0x3D: {
                u8 r = (opcode >> 3) & 7;
                setReg8(mmu, r, aluDec(getReg8(mmu, r)));
                return r == 6 ? 12 : 4;
            }

            // LD r, n
            case 0x06: case 0x0E: case 0x16: case 0x1E: case 0x26: case 0x2E: case 0x36: case 0x3E: {
                u8 r = (opcode >> 3) & 7;
                setReg8(mmu, r, fetch8(mmu));
                return r == 6 ? 12 : 8;
            }

            // Rotates of A (flag Z is 0 on DMG)
            case 0x07: a = aluRlc(a); flagZ = false; return 4; // RLCA
            case 0x0F: a = aluRrc(a); flagZ = false; return 4; // RRCA
            case 0x17: a = aluRl(a);  flagZ = false; return 4; // RLA
            case 0x1F: a = aluRr(a);  flagZ = false; return 4; // RRA

            // JR e
            case 0x18: {
                i8 offset = cast(i8)fetch8(mmu);
                pc = cast(u16)(pc + offset);
                return 12;
            }

            // JR cc, e
            case 0x20: case 0x28: case 0x30: case 0x38: {
                i8 offset = cast(i8)fetch8(mmu);
                if (checkCond((opcode >> 3) & 3)) {
                    pc = cast(u16)(pc + offset);
                    return 12;
                }
                return 8;
            }

            // DAA, CPL, SCF, CCF
            case 0x27: aluDaa(); return 4;
            case 0x2F: a = cast(u8)~a; flagN = true; flagH = true; return 4;
            case 0x37: flagN = false; flagH = false; flagC = true; return 4;
            case 0x3F: flagC = !flagC; flagN = false; flagH = false; return 4;

            // HALT, STOP
            case 0x76: halted = true; return 4;
            case 0x10: fetch8(mmu); return 4;

            // LD r, r' (0x40 - 0x7F except 0x76 HALT)
            case 0x40: .. case 0x75:
            case 0x77: .. case 0x7F: {
                u8 dst = (opcode >> 3) & 7;
                u8 src = opcode & 7;
                setReg8(mmu, dst, getReg8(mmu, src));
                return (dst == 6 || src == 6) ? 8 : 4;
            }

            // ALU A, r (0x80 - 0xBF): Opcode format 10_ooo_rrr
            case 0x80: .. case 0xBF: {
                u8 reg = opcode & 7;
                aluOp((opcode >> 3) & 7, getReg8(mmu, reg));
                return reg == 6 ? 8 : 4;
            }

            // Immediate ALU A, n (0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE): 11_ooo_110
            case 0xC6: case 0xCE: case 0xD6: case 0xDE:
            case 0xE6: case 0xEE: case 0xF6: case 0xFE:
                aluOp((opcode >> 3) & 7, fetch8(mmu));
                return 8;

            // RET cc
            case 0xC0: case 0xC8: case 0xD0: case 0xD8: {
                if (checkCond((opcode >> 3) & 3)) {
                    pc = pop16(mmu);
                    return 20;
                }
                return 8;
            }

            // RET / RETI
            case 0xC9: pc = pop16(mmu); return 16;
            case 0xD9: pc = pop16(mmu); ime = true; return 16;

            // JP cc, nn
            case 0xC2: case 0xCA: case 0xD2: case 0xDA: {
                u16 dest = fetch16(mmu);
                if (checkCond((opcode >> 3) & 3)) {
                    pc = dest;
                    return 16;
                }
                return 12;
            }

            // JP nn / JP (HL)
            case 0xC3: pc = fetch16(mmu); return 16;
            case 0xE9: pc = hl; return 4;

            // CALL cc, nn
            case 0xC4: case 0xCC: case 0xD4: case 0xDC: {
                u16 dest = fetch16(mmu);
                if (checkCond((opcode >> 3) & 3)) {
                    push16(mmu, pc);
                    pc = dest;
                    return 24;
                }
                return 12;
            }

            // CALL nn
            case 0xCD: {
                u16 dest = fetch16(mmu);
                push16(mmu, pc);
                pc = dest;
                return 24;
            }

            // RST n
            case 0xC7: case 0xCF: case 0xD7: case 0xDF:
            case 0xE7: case 0xEF: case 0xF7: case 0xFF:
                push16(mmu, pc);
                pc = cast(u16)(opcode & 0x38);
                return 16;

            // Stack POP rr (0xC1, 0xD1, 0xE1, 0xF1)
            case 0xC1: case 0xD1: case 0xE1: case 0xF1:
                setReg16((opcode >> 4) & 3, pop16(mmu), true);
                return 12;

            // Stack PUSH rr (0xC5, 0xD5, 0xE5, 0xF5)
            case 0xC5: case 0xD5: case 0xE5: case 0xF5:
                push16(mmu, getReg16((opcode >> 4) & 3, true));
                return 16;

            // LDH / High Memory
            case 0xE0: mmu.write(cast(u16)(0xFF00 + fetch8(mmu)), a); return 12;
            case 0xF0: a = mmu.read(cast(u16)(0xFF00 + fetch8(mmu))); return 12;
            case 0xE2: mmu.write(cast(u16)(0xFF00 + c), a); return 8;
            case 0xF2: a = mmu.read(cast(u16)(0xFF00 + c)); return 8;

            // Direct (nn) Loads
            case 0xEA: mmu.write(fetch16(mmu), a); return 16;
            case 0xFA: a = mmu.read(fetch16(mmu)); return 16;

            // ADD SP, e & LD HL, SP+e
            case 0xE8: sp = addSp(cast(i8)fetch8(mmu)); return 16;
            case 0xF8: hl = addSp(cast(i8)fetch8(mmu)); return 12;

            // LD SP, HL
            case 0xF9: sp = hl; return 8;

            // Interrupt Control
            case 0xF3: ime = false; imeScheduled = false; return 4;
            case 0xFB: imeScheduled = true; return 4;

            // CB-prefix
            case 0xCB: {
                u8 cb = fetch8(mmu);
                u8 reg = cb & 7;
                u8 bit = (cb >> 3) & 7;
                u8 group = cb >> 6;
                uint cycles = (reg == 6) ? 16 : 8;

                if (group == 1) { // BIT b, r
                    u8 val = getReg8(mmu, reg);
                    flagZ = (val & (1 << bit)) == 0;
                    flagN = false;
                    flagH = true;
                    return (reg == 6) ? 12 : 8;
                } else if (group == 2) { // RES b, r
                    setReg8(mmu, reg, cast(u8)(getReg8(mmu, reg) & ~(1 << bit)));
                    return cycles;
                } else if (group == 3) { // SET b, r
                    setReg8(mmu, reg, cast(u8)(getReg8(mmu, reg) | (1 << bit)));
                    return cycles;
                } else { // Rotates and shifts (group 0)
                    u8 val = getReg8(mmu, reg);
                    u8 res;
                    switch (bit) {
                        case 0: res = aluRlc(val); break;
                        case 1: res = aluRrc(val); break;
                        case 2: res = aluRl(val); break;
                        case 3: res = aluRr(val); break;
                        case 4: res = aluSla(val); break;
                        case 5: res = aluSra(val); break;
                        case 6: res = aluSwap(val); break;
                        default: res = aluSrl(val); break;
                    }
                    setReg8(mmu, reg, res);
                    return cycles;
                }
            }

            default:
                return 4;
        }
    }
}

unittest {
    CPU cpu;
    MMU mmu;
    cpu.reset();
    mmu.reset();

    // Initial register states
    assert(cpu.af == 0x01B0);
    assert(cpu.bc == 0x0013);
    assert(cpu.de == 0x00D8);
    assert(cpu.hl == 0x014D);
    assert(cpu.sp == 0xFFFE);
    assert(cpu.pc == 0x0100);

    // Register unions: 16-bit and 8-bit synchronicity
    cpu.hl = 0x1234;
    assert(cpu.h == 0x12 && cpu.l == 0x34);
    cpu.hl++;
    assert(cpu.hl == 0x1235);
    cpu.hl--;
    assert(cpu.hl == 0x1234);

    // Flags
    cpu.flagZ = true;
    assert(cpu.flagZ && (cpu.f & FLAG_Z));
    cpu.flagZ = false;
    assert(!cpu.flagZ);

    // Test ALU: ADD A, n and SUB n in RAM
    mmu.wram[0] = 0x3E; mmu.wram[1] = 0x0F; // LD A, 0x0F
    mmu.wram[2] = 0xC6; mmu.wram[3] = 0x01; // ADD A, 0x01
    mmu.wram[4] = 0xD6; mmu.wram[5] = 0x10; // SUB 0x10
    cpu.pc = 0xC000;

    cpu.step(mmu);
    assert(cpu.a == 0x0F);
    cpu.step(mmu);
    assert(cpu.a == 0x10);
    assert(cpu.flagH && !cpu.flagZ && !cpu.flagC);
    cpu.step(mmu);
    assert(cpu.a == 0x00);
    assert(cpu.flagZ && cpu.flagN);

    // Test CB: SWAP, BIT, SET, RES
    mmu.wram[6] = 0x3E; mmu.wram[7] = 0xA5; // LD A, 0xA5
    mmu.wram[8] = 0xCB; mmu.wram[9] = 0x37; // SWAP A
    mmu.wram[10] = 0xCB; mmu.wram[11] = 0x5F; // BIT 3, A
    mmu.wram[12] = 0xCB; mmu.wram[13] = 0x57; // BIT 2, A
    mmu.wram[14] = 0xCB; mmu.wram[15] = 0xD7; // SET 2, A
    mmu.wram[16] = 0xCB; mmu.wram[17] = 0x97; // RES 2, A
    cpu.pc = 0xC006;

    cpu.step(mmu);
    assert(cpu.a == 0xA5);
    cpu.step(mmu);
    assert(cpu.a == 0x5A); // SWAP
    cpu.step(mmu);
    assert(!cpu.flagZ); // BIT 3 of 0x5A is 1
    cpu.step(mmu);
    assert(cpu.flagZ);  // BIT 2 of 0x5A is 0
    cpu.step(mmu);
    assert(cpu.a == 0x5E); // SET 2
    cpu.step(mmu);
    assert(cpu.a == 0x5A); // RES 2

    import core.stdc.stdio : printf;
    printf("✔ [CPU] Unittests passed.\n");
}
