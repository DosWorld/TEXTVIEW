# TEXTVIEW

An 8086 text file viewer for MS-DOS with demand-paged virtual memory.

## Features

- View text files of any size up to 32 MB
- Demand-paged architecture — only 256 KB of RAM used regardless of file size
- LRU cache with 8 resident 32 KB chunks, loaded from disk on demand
- Checkpoint table for fast O(1) random seeking to any line
- Direct VRAM rendering (CGA/EGA/VGA 80x25 text mode)
- Word wrap mode (`--wrap` flag)
- Keyboard navigation: PgUp/PgDn, Up/Down, Home/End, Esc to quit

- Support screens more 80*25.

## Usage

```
TEXTVIEW <filename>
TEXTVIEW --wrap <filename>
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

TEXTVIEW is built with **Turbo Pascal**:

```
tpc TEXTVIEW.PAS
```

This produces `TEXTVIEW.EXE`, ready to run on any DOS system.

## Architecture

### Demand Paging

Unlike traditional DOS viewers that load entire files into memory, TEXTREAD uses a demand-paged design:

1. **Scan phase** — The file is streamed once at startup through a temporary 32 KB buffer (freed afterwards) to count lines and record checkpoints every 256 visual lines.

2. **Page-in on demand** — When the user navigates to a line, the nearest checkpoint is looked up in O(1), then a short forward walk finds the exact byte position. The required 32 KB chunk is loaded from disk into one of 8 cache slots.

3. **LRU eviction** — When all 8 cache slots are full, the least-recently-used slot is evicted and reused for the new chunk.

This keeps RAM usage constant at ~256 KB (8 x 32 KB) regardless of file size, while supporting files up to 32 MB (1024 chunks).

### Limits

| Parameter | Value |
|-----------|-------|
| Max file size | 32 MB (1024 pieces x 32 KB) |
| Max visual lines | 524,288 (2048 checkpoints x 256 interval) |
| RAM for file data | 256 KB (8 cached chunks) |
| Video mode | 80x25 CGA/EGA/VGA text |

## File List

| File | Description |
|------|-------------|
| `TEXTVIEW.PAS` | Assembly source code |
| `TEXTVIEW.EXE` | Pre-built DOS binary |
| `TEXTREAD.ZIP` | Original source      |
| `THECHAIR.TXT` | Sample text file for testing (72 KB, ~1100 lines) |

## License

Public domain.
