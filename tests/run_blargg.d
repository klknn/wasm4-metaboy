/**
 * Blargg Game Boy Hardware Test Suite Runner
 *
 * Runs Blargg's CPU instruction and timing validation test ROMs from
 * https://github.com/retrio/gb-test-roms against MetaBoy.
 *
 * Test results are captured via Game Boy serial link port (SB 0xFF01 / SC 0xFF02),
 * which MetaBoy forwards to WASM-4 debug trace.
 */
module tests.run_blargg;

import std.file : exists, read;
import std.stdio : writeln, writefln;
import std.string : indexOf, strip;
import std.array : replace;
import core.stdc.stdlib : exit;

import gb.types;
import gb.gameboy;
import w4 = wasm4;

__gshared string serialOutput;

extern(C) void handleTrace(const char* str) {
    import core.stdc.string : strlen;
    serialOutput ~= str[0 .. strlen(str)];
}

struct TestCase {
    string path;
    string name;
    int maxFrames;
}

int main(string[] args) {
    string romsDir = "tests/gb-test-roms";
    if (args.length > 1) {
        romsDir = args[1];
    }

    if (!exists(romsDir)) {
        writefln("Error: Test ROMs directory not found: '%s'", romsDir);
        writeln("Please run 'make test-blargg' or clone test ROMs with:");
        writeln("  git clone --depth 1 https://github.com/retrio/gb-test-roms.git tests/gb-test-roms");
        return 1;
    }

    TestCase[] tests = [
        TestCase(romsDir ~ "/cpu_instrs/individual/01-special.gb", "01-special.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/02-interrupts.gb", "02-interrupts.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/03-op sp,hl.gb", "03-op sp,hl.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/04-op r,imm.gb", "04-op r,imm.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/05-op rp.gb", "05-op rp.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/06-ld r,r.gb", "06-ld r,r.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/07-jr,jp,call,ret,rst.gb", "07-jr,jp,call,ret,rst.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/08-misc instrs.gb", "08-misc instrs.gb", 500),
        TestCase(romsDir ~ "/cpu_instrs/individual/09-op r,r.gb", "09-op r,r.gb", 800),
        TestCase(romsDir ~ "/cpu_instrs/individual/10-bit ops.gb", "10-bit ops.gb", 1500),
        TestCase(romsDir ~ "/cpu_instrs/individual/11-op a,(hl).gb", "11-op a,(hl).gb", 1500),
        TestCase(romsDir ~ "/instr_timing/instr_timing.gb", "instr_timing.gb", 500),
    ];

    w4.customTraceHandler = &handleTrace;

    writeln("================================================================");
    writeln("  Running Blargg Game Boy Hardware Test Suite on MetaBoy");
    writeln("================================================================");

    int passedCount = 0;
    int failedCount = 0;

    foreach (i, t; tests) {
        if (!exists(t.path)) {
            writefln("  [%2d/%d] %-28s ✘ MISSING FILE: %s", i + 1, tests.length, t.name, t.path);
            failedCount++;
            continue;
        }

        serialOutput = "";
        const(ubyte)[] rom = cast(const(ubyte)[])read(t.path);
        GameBoy gb;
        ubyte[32768] ram;
        gb.loadCustomRom(rom, ram[]);

        int finishFrame = -1;
        bool passed = false;

        for (int f = 1; f <= t.maxFrames; f++) {
            gb.stepFrame(0);

            if (serialOutput.indexOf("Passed") != -1) {
                finishFrame = f;
                passed = true;
                break;
            }
            if (serialOutput.indexOf("Failed") != -1) {
                finishFrame = f;
                passed = false;
                break;
            }
        }

        if (passed) {
            passedCount++;
            writefln("  [%2d/%d] %-28s ✔ PASSED (frame %4d)", i + 1, tests.length, t.name, finishFrame);
        } else {
            failedCount++;
            writefln("  [%2d/%d] %-28s ✘ FAILED (frame %4d, output: %s)",
                i + 1, tests.length, t.name, finishFrame, serialOutput.strip.replace("\n", " "));
        }
    }

    writeln("================================================================");
    if (failedCount == 0) {
        writefln("  SUCCESS: All %d Blargg hardware test ROMs passed! (100%%)", passedCount);
        writeln("================================================================");
        return 0;
    } else {
        writefln("  FAILURE: %d failed, %d passed out of %d tests.", failedCount, passedCount, tests.length);
        writeln("================================================================");
        return 1;
    }
}
