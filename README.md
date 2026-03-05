# TEXTREAD

An 8086 text file viewer for MS-DOS with demand-paged virtual memory.

Written in 16-bit x86 assembly for the [agent86](https://github.com/cookertron/agent86) assembler. Produces a standard .COM binary that runs on any DOS-compatible system (MS-DOS, FreeDOS, DOSBox, etc.).

## Features

- View text files of any size up to 32 MB
- Demand-paged architecture — only 256 KB of RAM used regardless of file size
- LRU cache with 8 resident 32 KB chunks, loaded from disk on demand
- Checkpoint table for fast O(1) random seeking to any line
- Direct VRAM rendering (CGA/EGA/VGA 80x25 text mode)
- Word wrap mode (`--wrap` flag)
- Keyboard navigation: PgUp/PgDn, Up/Down, Home/End, Esc to quit

## Usage

```
TEXTREAD <filename>
TEXTREAD --wrap <filename>
```

### Keys

| Key | Action |
|-----|--------|
| PgDn | Scroll down one page (24 lines) |
| PgUp | Scroll up one page |
| Down | Scroll down one line |
| Up | Scroll up one line |
| Home | Jump to start of file |
| End | Jump to end of file |
| Esc | Quit |

## Building

TEXTREAD is built with **agent86**, a two-pass 8086 assembler and JIT emulator targeting .COM binaries.

```
agent86 TEXTREAD.ASM
```

This produces `TEXTREAD.COM`, ready to run on any DOS system.

### Testing with agent86's built-in emulator

agent86 includes a JIT emulator with video framebuffer support, so you can assemble and run in one step:

```
agent86 TEXTREAD.ASM --build_run --screen CGA80 --args "THECHAIR.TXT"
```

For large files that may exceed the default 100M instruction limit during the initial scan:

```
agent86 TEXTREAD.ASM --build_run --run 500000000 --screen CGA80 --args "bigfile.txt"
```

## Architecture

### Demand Paging

Unlike traditional DOS viewers that load entire files into memory, TEXTREAD uses a demand-paged design:

1. **Scan phase** — The file is streamed once at startup through a temporary 32 KB buffer (freed afterwards) to count lines and record checkpoints every 256 visual lines.

2. **Page-in on demand** — When the user navigates to a line, the nearest checkpoint is looked up in O(1), then a short forward walk finds the exact byte position. The required 32 KB chunk is loaded from disk into one of 8 cache slots.

3. **LRU eviction** — When all 8 cache slots are full, the least-recently-used slot is evicted and reused for the new chunk.

This keeps RAM usage constant at ~256 KB (8 x 32 KB) regardless of file size, while supporting files up to 32 MB (1024 chunks).

### Memory Map

| Region | Size | Purpose |
|--------|------|---------|
| COM segment | ~13 KB code + ~10 KB BSS | Program, piece table, checkpoint table |
| Cache slots | 8 x 32 KB = 256 KB | Demand-paged file data |
| Stack | ~19 KB | Below 32 KB COM boundary |

### Limits

| Parameter | Value |
|-----------|-------|
| Max file size | 32 MB (1024 pieces x 32 KB) |
| Max visual lines | 524,288 (2048 checkpoints x 256 interval) |
| RAM for file data | 256 KB fixed (8 cached chunks) |
| Video mode | 80x25 CGA/EGA/VGA text |

## File List

| File | Description |
|------|-------------|
| `TEXTREAD.ASM` | Assembly source code |
| `TEXTREAD.COM` | Pre-built DOS binary |
| `IMPL_PLAN.md` | Detailed implementation plan for the demand-paged architecture |
| `THECHAIR.TXT` | Sample text file for testing (72 KB, ~1100 lines) |

## License

Public domain.
