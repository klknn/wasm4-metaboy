module gb.types;

alias u8  = ubyte;
alias u16 = ushort;
alias u32 = uint;
alias i8  = byte;
alias i16 = short;
alias i32 = int;

// Flags in Register F
enum u8 FLAG_Z = 0x80; // Zero flag
enum u8 FLAG_N = 0x40; // Subtract flag
enum u8 FLAG_H = 0x20; // Half-carry flag
enum u8 FLAG_C = 0x10; // Carry flag

// Interrupt bits in IF (0xFF0F) and IE (0xFFFF)
enum u8 INT_VBLANK = 0x01; // Vector 0x0040
enum u8 INT_STAT   = 0x02; // Vector 0x0048
enum u8 INT_TIMER  = 0x04; // Vector 0x0050
enum u8 INT_SERIAL = 0x08; // Vector 0x0058
enum u8 INT_JOYPAD = 0x10; // Vector 0x0060

// LCD Control (LCDC) bits (0xFF40)
enum u8 LCDC_BG_ENABLE   = 0x01; // BG & Window display enable
enum u8 LCDC_OBJ_ENABLE  = 0x02; // OBJ (sprite) display enable
enum u8 LCDC_OBJ_SIZE    = 0x04; // OBJ size: 0=8x8, 1=8x16
enum u8 LCDC_BG_TILEMAP  = 0x08; // BG tile map display select: 0=9800-9BFF, 1=9C00-9FFF
enum u8 LCDC_TILE_DATA   = 0x10; // BG & Window tile data select: 0=8800-97FF, 1=8000-8FFF
enum u8 LCDC_WIN_ENABLE  = 0x20; // Window display enable
enum u8 LCDC_WIN_TILEMAP = 0x40; // Window tile map display select: 0=9800-9BFF, 1=9C00-9FFF
enum u8 LCDC_ENABLE      = 0x80; // LCD operation enable

// LCD Status (STAT) bits (0xFF41)
enum u8 STAT_MODE_MASK     = 0x03;
enum u8 STAT_MODE_HBLANK   = 0x00; // Mode 0
enum u8 STAT_MODE_VBLANK   = 0x01; // Mode 1
enum u8 STAT_MODE_OAM      = 0x02; // Mode 2
enum u8 STAT_MODE_TRANSFER = 0x03; // Mode 3
enum u8 STAT_LYC_FLAG      = 0x04; // Bit 2: LYC == LY
enum u8 STAT_INT_HBLANK    = 0x08; // Bit 3
enum u8 STAT_INT_VBLANK    = 0x10; // Bit 4
enum u8 STAT_INT_OAM       = 0x20; // Bit 5
enum u8 STAT_INT_LYC       = 0x40; // Bit 6

// Screen dimensions
enum uint GB_SCREEN_W = 160;
enum uint GB_SCREEN_H = 144;
enum uint GB_SCANLINES = 154;
enum uint GB_CYCLES_PER_LINE = 456;
enum uint GB_CYCLES_PER_FRAME = GB_SCANLINES * GB_CYCLES_PER_LINE; // 70224
