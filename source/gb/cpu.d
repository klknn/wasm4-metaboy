module gb.cpu;

import gb.types;
import gb.mmu;

struct CPU {
    // 8-bit registers
    u8 a = 0x01;
    u8 f = 0xB0;
    u8 b = 0x00;
    u8 c = 0x13;
    u8 d = 0x00;
    u8 e = 0xD8;
    u8 h = 0x01;
    u8 l = 0x4D;

    u16 sp = 0xFFFE;
    u16 pc = 0x0100;

    bool ime = false;
    bool imeScheduled = false; // Delayed EI
    bool halted = false;

    // 16-bit register accessors
    @property u16 af() const { return cast(u16)((a << 8) | (f & 0xF0)); }
    @property void af(u16 v) { a = cast(u8)(v >> 8); f = cast(u8)(v & 0xF0); }

    @property u16 bc() const { return cast(u16)((b << 8) | c); }
    @property void bc(u16 v) { b = cast(u8)(v >> 8); c = cast(u8)(v & 0xFF); }

    @property u16 de() const { return cast(u16)((d << 8) | e); }
    @property void de(u16 v) { d = cast(u8)(v >> 8); e = cast(u8)(v & 0xFF); }

    @property u16 hl() const { return cast(u16)((h << 8) | l); }
    @property void hl(u16 v) { h = cast(u8)(v >> 8); l = cast(u8)(v & 0xFF); }

    void incBC() { bc = cast(u16)(bc + 1); }
    void decBC() { bc = cast(u16)(bc - 1); }
    void incDE() { de = cast(u16)(de + 1); }
    void decDE() { de = cast(u16)(de - 1); }
    void incHL() { hl = cast(u16)(hl + 1); }
    void decHL() { hl = cast(u16)(hl - 1); }

    // Flag getters & setters
    @property bool flagZ() const { return (f & FLAG_Z) != 0; }
    @property void flagZ(bool v) { if (v) f |= FLAG_Z; else f &= ~FLAG_Z; }

    @property bool flagN() const { return (f & FLAG_N) != 0; }
    @property void flagN(bool v) { if (v) f |= FLAG_N; else f &= ~FLAG_N; }

    @property bool flagH() const { return (f & FLAG_H) != 0; }
    @property void flagH(bool v) { if (v) f |= FLAG_H; else f &= ~FLAG_H; }

    @property bool flagC() const { return (f & FLAG_C) != 0; }
    @property void flagC(bool v) { if (v) f |= FLAG_C; else f &= ~FLAG_C; }

    void reset() {
        a = 0x01;
        f = 0xB0;
        b = 0x00;
        c = 0x13;
        d = 0x00;
        e = 0xD8;
        h = 0x01;
        l = 0x4D;
        sp = 0xFFFE;
        pc = 0x0100;
        ime = false;
        imeScheduled = false;
        halted = false;
    }

    // Step CPU by executing one instruction or servicing interrupts.
    // Returns the number of T-cycles consumed.
    uint step(ref MMU mmu) {
        // Handle delayed EI
        if (imeScheduled) {
            ime = true;
            imeScheduled = false;
        }

        // Check and handle interrupts
        u8 pending = mmu.iflag & mmu.ie & 0x1F;
        if (pending != 0) {
            if (halted) {
                halted = false;
            }

            if (ime) {
                ime = false;
                // Priority: VBlank, STAT, Timer, Serial, Joypad
                u16 targetVector = 0;
                u8 mask = 1;
                u16[5] vectors = [0x0040, 0x0048, 0x0050, 0x0058, 0x0060];
                for (int i = 0; i < 5; i++) {
                    if (pending & mask) {
                        mmu.iflag &= ~mask;
                        targetVector = vectors[i];
                        break;
                    }
                    mask <<= 1;
                }

                push16(mmu, pc);
                pc = targetVector;
                return 20; // 5 M-cycles = 20 T-cycles
            }
        }

        if (halted) {
            return 4; // 1 M-cycle while halted
        }

        u8 opcode = fetch8(mmu);
        return execute(mmu, opcode);
    }

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

    // --- ALU Helpers ---
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

    private uint execute(ref MMU mmu, u8 opcode) {
        switch (opcode) {
            // NOP
            case 0x00: return 4;

            // LD rr, nn
            case 0x01: bc = fetch16(mmu); return 12;
            case 0x11: de = fetch16(mmu); return 12;
            case 0x21: hl = fetch16(mmu); return 12;
            case 0x31: sp = fetch16(mmu); return 12;

            // LD (rr), A
            case 0x02: mmu.write(bc, a); return 8;
            case 0x12: mmu.write(de, a); return 8;
            case 0x22: mmu.write(hl, a); incHL(); return 8; // LD (HL+), A
            case 0x32: mmu.write(hl, a); decHL(); return 8; // LD (HL-), A

            // LD A, (rr)
            case 0x0A: a = mmu.read(bc); return 8;
            case 0x1A: a = mmu.read(de); return 8;
            case 0x2A: a = mmu.read(hl); incHL(); return 8; // LD A, (HL+)
            case 0x3A: a = mmu.read(hl); decHL(); return 8; // LD A, (HL-)

            // LD (nn), SP
            case 0x08: {
                u16 addr = fetch16(mmu);
                mmu.write(addr, cast(u8)(sp & 0xFF));
                mmu.write(cast(u16)(addr + 1), cast(u8)(sp >> 8));
                return 20;
            }

            // INC rr
            case 0x03: incBC(); return 8;
            case 0x13: incDE(); return 8;
            case 0x23: incHL(); return 8;
            case 0x33: sp++; return 8;

            // DEC rr
            case 0x0B: decBC(); return 8;
            case 0x1B: decDE(); return 8;
            case 0x2B: decHL(); return 8;
            case 0x3B: sp--; return 8;

            // ADD HL, rr
            case 0x09: aluAddHL(bc); return 8;
            case 0x19: aluAddHL(de); return 8;
            case 0x29: aluAddHL(hl); return 8;
            case 0x39: aluAddHL(sp); return 8;

            // INC r
            case 0x04: b = aluInc(b); return 4;
            case 0x14: d = aluInc(d); return 4;
            case 0x24: h = aluInc(h); return 4;
            case 0x34: mmu.write(hl, aluInc(mmu.read(hl))); return 12;
            case 0x0C: c = aluInc(c); return 4;
            case 0x1C: e = aluInc(e); return 4;
            case 0x2C: l = aluInc(l); return 4;
            case 0x3C: a = aluInc(a); return 4;

            // DEC r
            case 0x05: b = aluDec(b); return 4;
            case 0x15: d = aluDec(d); return 4;
            case 0x25: h = aluDec(h); return 4;
            case 0x35: mmu.write(hl, aluDec(mmu.read(hl))); return 12;
            case 0x0D: c = aluDec(c); return 4;
            case 0x1D: e = aluDec(e); return 4;
            case 0x2D: l = aluDec(l); return 4;
            case 0x3D: a = aluDec(a); return 4;

            // LD r, n
            case 0x06: b = fetch8(mmu); return 8;
            case 0x16: d = fetch8(mmu); return 8;
            case 0x26: h = fetch8(mmu); return 8;
            case 0x36: mmu.write(hl, fetch8(mmu)); return 12;
            case 0x0E: c = fetch8(mmu); return 8;
            case 0x1E: e = fetch8(mmu); return 8;
            case 0x2E: l = fetch8(mmu); return 8;
            case 0x3E: a = fetch8(mmu); return 8;

            // Rotates of A
            case 0x07: { // RLCA
                u8 cOut = (a & 0x80) != 0 ? 1 : 0;
                a = cast(u8)((a << 1) | cOut);
                flagZ = false; flagN = false; flagH = false; flagC = (cOut != 0);
                return 4;
            }
            case 0x0F: { // RRCA
                u8 cOut = (a & 0x01) != 0 ? 1 : 0;
                a = cast(u8)((a >> 1) | (cOut << 7));
                flagZ = false; flagN = false; flagH = false; flagC = (cOut != 0);
                return 4;
            }
            case 0x17: { // RLA
                u8 oldC = flagC ? 1 : 0;
                u8 cOut = (a & 0x80) != 0 ? 1 : 0;
                a = cast(u8)((a << 1) | oldC);
                flagZ = false; flagN = false; flagH = false; flagC = (cOut != 0);
                return 4;
            }
            case 0x1F: { // RRA
                u8 oldC = flagC ? 1 : 0;
                u8 cOut = (a & 0x01) != 0 ? 1 : 0;
                a = cast(u8)((a >> 1) | (oldC << 7));
                flagZ = false; flagN = false; flagH = false; flagC = (cOut != 0);
                return 4;
            }

            // JR e
            case 0x18: {
                i8 offset = cast(i8)fetch8(mmu);
                pc = cast(u16)(pc + offset);
                return 12;
            }
            case 0x20: { // JR NZ, e
                i8 offset = cast(i8)fetch8(mmu);
                if (!flagZ) { pc = cast(u16)(pc + offset); return 12; }
                return 8;
            }
            case 0x28: { // JR Z, e
                i8 offset = cast(i8)fetch8(mmu);
                if (flagZ) { pc = cast(u16)(pc + offset); return 12; }
                return 8;
            }
            case 0x30: { // JR NC, e
                i8 offset = cast(i8)fetch8(mmu);
                if (!flagC) { pc = cast(u16)(pc + offset); return 12; }
                return 8;
            }
            case 0x38: { // JR C, e
                i8 offset = cast(i8)fetch8(mmu);
                if (flagC) { pc = cast(u16)(pc + offset); return 12; }
                return 8;
            }

            // DAA, CPL, SCF, CCF
            case 0x27: aluDaa(); return 4;
            case 0x2F: a = cast(u8)~a; flagN = true; flagH = true; return 4;
            case 0x37: flagN = false; flagH = false; flagC = true; return 4;
            case 0x3F: flagC = !flagC; flagN = false; flagH = false; return 4;

            // HALT, STOP
            case 0x76: halted = true; return 4;
            case 0x10: fetch8(mmu); return 4; // STOP 0

            // 8-bit loads: LD r, r' (0x40 - 0x7F except 0x76 HALT)
            case 0x40: .. case 0x75:
            case 0x77: .. case 0x7F: {
                u8 dst = (opcode >> 3) & 7;
                u8 src = opcode & 7;
                u8 val = getReg8(mmu, src);
                setReg8(mmu, dst, val);
                return (dst == 6 || src == 6) ? 8 : 4;
            }

            // ALU A, r (0x80 - 0xBF)
            case 0x80: .. case 0x87: aluAdd(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;
            case 0x88: .. case 0x8F: aluAdd(getReg8(mmu, opcode & 7), true); return (opcode & 7) == 6 ? 8 : 4;
            case 0x90: .. case 0x97: aluSub(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;
            case 0x98: .. case 0x9F: aluSub(getReg8(mmu, opcode & 7), true); return (opcode & 7) == 6 ? 8 : 4;
            case 0xA0: .. case 0xA7: aluAnd(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;
            case 0xA8: .. case 0xAF: aluXor(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;
            case 0xB0: .. case 0xB7: aluOr(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;
            case 0xB8: .. case 0xBF: aluCp(getReg8(mmu, opcode & 7)); return (opcode & 7) == 6 ? 8 : 4;

            // Immediate ALU
            case 0xC6: aluAdd(fetch8(mmu)); return 8;
            case 0xCE: aluAdd(fetch8(mmu), true); return 8;
            case 0xD6: aluSub(fetch8(mmu)); return 8;
            case 0xDE: aluSub(fetch8(mmu), true); return 8;
            case 0xE6: aluAnd(fetch8(mmu)); return 8;
            case 0xEE: aluXor(fetch8(mmu)); return 8;
            case 0xF6: aluOr(fetch8(mmu)); return 8;
            case 0xFE: aluCp(fetch8(mmu)); return 8;

            // RET cc
            case 0xC0: if (!flagZ) { pc = pop16(mmu); return 20; } return 8;
            case 0xC8: if (flagZ)  { pc = pop16(mmu); return 20; } return 8;
            case 0xD0: if (!flagC) { pc = pop16(mmu); return 20; } return 8;
            case 0xD8: if (flagC)  { pc = pop16(mmu); return 20; } return 8;

            // RET / RETI
            case 0xC9: pc = pop16(mmu); return 16;
            case 0xD9: pc = pop16(mmu); ime = true; return 16;

            // JP cc, nn
            case 0xC2: {
                u16 dest = fetch16(mmu);
                if (!flagZ) { pc = dest; return 16; }
                return 12;
            }
            case 0xCA: {
                u16 dest = fetch16(mmu);
                if (flagZ) { pc = dest; return 16; }
                return 12;
            }
            case 0xD2: {
                u16 dest = fetch16(mmu);
                if (!flagC) { pc = dest; return 16; }
                return 12;
            }
            case 0xDA: {
                u16 dest = fetch16(mmu);
                if (flagC) { pc = dest; return 16; }
                return 12;
            }

            // JP nn / JP (HL)
            case 0xC3: pc = fetch16(mmu); return 16;
            case 0xE9: pc = hl; return 4;

            // CALL cc, nn
            case 0xC4: {
                u16 dest = fetch16(mmu);
                if (!flagZ) { push16(mmu, pc); pc = dest; return 24; }
                return 12;
            }
            case 0xCC: {
                u16 dest = fetch16(mmu);
                if (flagZ) { push16(mmu, pc); pc = dest; return 24; }
                return 12;
            }
            case 0xD4: {
                u16 dest = fetch16(mmu);
                if (!flagC) { push16(mmu, pc); pc = dest; return 24; }
                return 12;
            }
            case 0xDC: {
                u16 dest = fetch16(mmu);
                if (flagC) { push16(mmu, pc); pc = dest; return 24; }
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
            case 0xC7: push16(mmu, pc); pc = 0x0000; return 16;
            case 0xCF: push16(mmu, pc); pc = 0x0008; return 16;
            case 0xD7: push16(mmu, pc); pc = 0x0010; return 16;
            case 0xDF: push16(mmu, pc); pc = 0x0018; return 16;
            case 0xE7: push16(mmu, pc); pc = 0x0020; return 16;
            case 0xEF: push16(mmu, pc); pc = 0x0028; return 16;
            case 0xF7: push16(mmu, pc); pc = 0x0030; return 16;
            case 0xFF: push16(mmu, pc); pc = 0x0038; return 16;

            // POP rr
            case 0xC1: bc = pop16(mmu); return 12;
            case 0xD1: de = pop16(mmu); return 12;
            case 0xE1: hl = pop16(mmu); return 12;
            case 0xF1: af = pop16(mmu); return 12;

            // PUSH rr
            case 0xC5: push16(mmu, bc); return 16;
            case 0xD5: push16(mmu, de); return 16;
            case 0xE5: push16(mmu, hl); return 16;
            case 0xF5: push16(mmu, af); return 16;

            // LDH / High Memory
            case 0xE0: mmu.write(cast(u16)(0xFF00 + fetch8(mmu)), a); return 12;
            case 0xF0: a = mmu.read(cast(u16)(0xFF00 + fetch8(mmu))); return 12;
            case 0xE2: mmu.write(cast(u16)(0xFF00 + c), a); return 8;
            case 0xF2: a = mmu.read(cast(u16)(0xFF00 + c)); return 8;

            // Direct (nn) Loads
            case 0xEA: mmu.write(fetch16(mmu), a); return 16;
            case 0xFA: a = mmu.read(fetch16(mmu)); return 16;

            // ADD SP, e
            case 0xE8: {
                i8 offset = cast(i8)fetch8(mmu);
                flagZ = false;
                flagN = false;
                flagH = ((sp & 0x0F) + (offset & 0x0F)) > 0x0F;
                flagC = ((sp & 0xFF) + (offset & 0xFF)) > 0xFF;
                sp = cast(u16)(sp + offset);
                return 16;
            }

            // LD HL, SP+e
            case 0xF8: {
                i8 offset = cast(i8)fetch8(mmu);
                flagZ = false;
                flagN = false;
                flagH = ((sp & 0x0F) + (offset & 0x0F)) > 0x0F;
                flagC = ((sp & 0xFF) + (offset & 0xFF)) > 0xFF;
                hl = cast(u16)(sp + offset);
                return 12;
            }

            // LD SP, HL
            case 0xF9: sp = hl; return 8;

            // Interrupt Control
            case 0xF3: ime = false; imeScheduled = false; return 4; // DI
            case 0xFB: imeScheduled = true; return 4;               // EI

            // CB-prefix
            case 0xCB: {
                u8 cbOpcode = fetch8(mmu);
                return executeCB(mmu, cbOpcode);
            }

            default:
                // Unmapped opcode
                return 4;
        }
    }

    private uint executeCB(ref MMU mmu, u8 cbOpcode) {
        u8 regIdx = cbOpcode & 7;
        u8 bitIdx = (cbOpcode >> 3) & 7;
        u8 group  = cbOpcode >> 6;

        uint cycles = (regIdx == 6) ? 16 : 8;

        if (group == 1) {
            // BIT b, r
            u8 val = getReg8(mmu, regIdx);
            flagZ = (val & (1 << bitIdx)) == 0;
            flagN = false;
            flagH = true;
            return (regIdx == 6) ? 12 : 8;
        } else if (group == 2) {
            // RES b, r
            u8 val = getReg8(mmu, regIdx);
            val &= ~(1 << bitIdx);
            setReg8(mmu, regIdx, val);
            return cycles;
        } else if (group == 3) {
            // SET b, r
            u8 val = getReg8(mmu, regIdx);
            val |= (1 << bitIdx);
            setReg8(mmu, regIdx, val);
            return cycles;
        } else {
            // Rotates and shifts (group 0)
            u8 val = getReg8(mmu, regIdx);
            u8 res;
            switch (bitIdx) {
                case 0: res = aluRlc(val); break;
                case 1: res = aluRrc(val); break;
                case 2: res = aluRl(val); break;
                case 3: res = aluRr(val); break;
                case 4: res = aluSla(val); break;
                case 5: res = aluSra(val); break;
                case 6: res = aluSwap(val); break;
                default: res = aluSrl(val); break;
            }
            setReg8(mmu, regIdx, res);
            return cycles;
        }
    }
}
