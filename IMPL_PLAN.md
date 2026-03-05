# TEXTREAD.ASM — Demand-Paged Architecture Implementation Plan

**Target assembler:** agent86 (see constraints section)  
**Source file:** `TEXTREAD.ASM` (the agent86-compatible version with `CS:` segment overrides)  
**Goal:** Replace the full-upfront load with a demand-paged streaming architecture capable of handling files of tens of megabytes within the DOS 640 KB address space.

---

## Overview of the Change

The current program loads the entire file into RAM at startup (all `load_file` + `build_li`), then closes the file handle. The new architecture:

1. **Keeps the file handle open** for the lifetime of the program.
2. **Scans the file once at startup** (streaming, without retaining data) to record piece lengths and a sparse checkpoint table.
3. **Caches only a small window** of up to `MAX_CACHE` (8) chunk segments in RAM at any one time, evicting the least-recently-used segment when a new one is needed.
4. **Resolves any target line number** in O(1) checkpoint lookup + O(CHKPT_INTERVAL) forward walk, never scanning the whole file again after startup.

---

## agent86 Assembler Constraints

These must be respected throughout all new and modified code:

- **Shifts by immediate > 1 are not supported.** Use `SHL reg, 1` / `SHR reg, 1` repeatedly, or load a count into `CL` and use `SHL reg, CL`.
- **No STRUC / RECORD / UNION.** Use parallel word arrays only.
- **No TIMES / DUP.** Use `RESB` / `RESW N` for zero-fill blocks.
- **No conditional assembly** (no IF/ELSE/ENDIF).
- **Flat COM model only.** No SEGMENT/ENDS.
- **Labels are case-sensitive.**
- **All shifts in the existing code** that use `SHL BX, 1` twice are correct and must be kept as-is.
- **agent86's instruction limit** is 100 million by default. Scanning a large file at startup may approach this. When testing, pass `--run 500000000` (500 M) to agent86 for large test files. Production DOS hardware has no such limit.

---

## Phase 1 — Constants and BSS Restructure

### 1.1  Replace / Add Constants

Remove `MAX_PIECES EQU 64`, `LI_PARA EQU 0800h`, `LI_ENTRY_SZ EQU 4`.

Add or change the following constants:

```asm
MAX_PIECES    EQU  1024   ; covers files up to 32 MB (1024 × 32 KB)
MAX_CACHE     EQU  8      ; chunk segments resident in RAM simultaneously
CHUNK_PARA    EQU  0800h  ; 2048 paragraphs = 32 768 bytes per chunk (unchanged)
CHUNK_BYTES   EQU  8000h  ; 32 768 (unchanged)

CHKPT_INTERVAL EQU 256   ; record one checkpoint every 256 visual lines
MAX_CHKPT      EQU 2048  ; max checkpoints (covers 524 288 visual lines)
```

### 1.2  Remove BSS Variables

Delete all of:

```asm
; DELETE these entirely:
pt_seg:      RESW MAX_PIECES   ; no longer needed (was allocated segment per piece)
pt_ofs:      RESW MAX_PIECES   ; always 0, implicit now
alloc_lst:   RESW MAX_PIECES + 4
alloc_num:   RESW 1
li_seg:      RESW 1
li_count:    RESW 1
```

### 1.3  Add / Rename BSS Variables

After the existing `file_hnd:`, `wrap_mode:`, `filename:` declarations, insert the following blocks in order:

```asm
; ---- Piece Table (metadata only, no allocated memory per piece) ----
; Piece i covers file bytes [i * CHUNK_BYTES .. i * CHUNK_BYTES + pt_len[i] - 1]
; File offset is implicit: never stored, always computed on demand.
pt_count:    RESW 1              ; total number of pieces (set by scan_file)
pt_len:      RESW MAX_PIECES     ; byte count of each piece (CHUNK_BYTES for all
                                 ; except the last, which may be smaller)

; ---- Chunk Cache ----
; A pool of MAX_CACHE allocated 32 KB DOS segments that hold piece data.
; Eviction policy: LRU (lowest cache_lru[] value is evicted first).
cache_count: RESW 1              ; number of cache slots currently allocated (0..MAX_CACHE)
cache_seg:   RESW MAX_CACHE      ; DOS segment address of each cache slot
cache_pi:    RESW MAX_CACHE      ; piece index held in each slot (0FFFFh = empty)
cache_lru:   RESW MAX_CACHE      ; LRU timestamp for each slot
lru_clock:   RESW 1              ; global counter, incremented on every page_in hit

; ---- Checkpoint Table ----
; Entry C covers visual lines [C * CHKPT_INTERVAL .. (C+1) * CHKPT_INTERVAL - 1].
; Line C * CHKPT_INTERVAL begins at piece chkpt_pi[C], byte chkpt_po[C].
chkpt_num:   RESW 1              ; number of checkpoints recorded
total_lines: RESW 1              ; total visual lines in the file (set by scan_file)
chkpt_pi:    RESW MAX_CHKPT      ; piece index at each checkpoint
chkpt_po:    RESW MAX_CHKPT      ; byte offset within piece at each checkpoint
```

### 1.4  Rename / Keep Existing BSS

Keep unchanged:
- `filename`, `wrap_mode`, `file_hnd`
- `top_line`, `nav_max`, `sav_curs`
- `rnd_pi`, `rnd_seg`, `rnd_off`, `rnd_len`, `rnd_row`

---

## Phase 2 — Startup Sequence Changes in `main`

### 2.1  Remove Lines

Delete the following calls from `main`:

```asm
; DELETE these three lines:
    CALL    alloc_li
    JC      .err_nomem

    CALL    load_file
    JC      .err_nomem

    ; Close file — all data lives in the chunk segments now
    MOV     BX, [file_hnd]
    MOV     AH, 3Eh
    INT     21h

    CALL    build_li
```

### 2.2  Insert Replacement

In their place (after `open_file` and the `s_loading` print), insert:

```asm
    ; ---- Scan file: measure pieces + build checkpoint table ----
    CALL    scan_file
    JC      .err_nomem

    ; NOTE: file handle stays OPEN — do NOT close it here
```

### 2.3  Update the Quit Path

In the `.quit` section, before `CALL free_all`, add:

```asm
    ; Close the file handle (kept open since startup)
    MOV     BX, [file_hnd]
    MOV     AH, 3Eh
    INT     21h
```

---

## Phase 3 — New Function: `scan_file`

**Purpose:** Perform a single streaming pass over the entire file to:
- Determine the number of pieces and each piece's byte count (`pt_count`, `pt_len[]`).
- Count total visual lines (`total_lines`).
- Record a checkpoint every `CHKPT_INTERVAL` lines into `chkpt_pi[]` / `chkpt_po[]`.

**Memory use:** Allocates one temporary 32 KB scan buffer segment, reuses it for every piece, frees it before returning. The file data is NOT retained.

**Returns:** `CF=0` on success, `CF=1` if the scan buffer cannot be allocated.

### Algorithm

```
scan_file:
    Allocate one 32 KB segment (INT 21h AH=48h, BX=CHUNK_PARA) → scan_seg
    If CF: return CF=1

    piece_index = 0
    col_counter = 0         ; visual column (for wrap mode)
    line_count  = 0         ; running total of visual lines seen so far

    ; Record checkpoint 0: line 0 begins at piece 0, offset 0
    chkpt_pi[0] = 0
    chkpt_po[0] = 0
    chkpt_num   = 1

    LOOP over pieces:
        ; Seek to piece_index * CHUNK_BYTES  (INT 21h AH=42h, AL=0)
        ; CX:DX = 32-bit offset (see Phase 3.1 for exact computation)
        ; BX = file_hnd
        ; If CF: break (I/O error or past EOF — treat as done)

        ; Read CHUNK_BYTES bytes into scan_seg:0  (INT 21h AH=3Fh)
        ; DS must = scan_seg for the read; use CS: prefix for all COM vars inside
        ; AX = bytes actually read

        If AX == 0: break (clean EOF)

        Store pt_len[piece_index] = AX
        piece_index++

        ; Walk the bytes just read (SI = 0..AX-1, DS = scan_seg):
        For each byte b = DS:[SI]:
            If b == 0Dh: skip (CR)
            If b == 0Ah (LF):
                col_counter = 0
                line_count++
                ; Check if a checkpoint is due
                If (line_count % CHKPT_INTERVAL) == 0:
                    If chkpt_num < MAX_CHKPT:
                        chkpt_pi[chkpt_num] = piece_index - 1
                        chkpt_po[chkpt_num] = SI + 1  ; byte AFTER the LF
                        ; If SI+1 == pt_len[piece_index-1]:
                        ;     chkpt_pi[chkpt_num] = piece_index  ; next piece
                        ;     chkpt_po[chkpt_num] = 0
                        chkpt_num++
            Else:
                col_counter++
                If wrap_mode AND col_counter == SCREEN_COLS:
                    col_counter = 0
                    line_count++
                    ; Check if checkpoint is due (same logic as LF case above)
                    ; chkpt_po points to the CURRENT SI (start of next visual row)

        If AX < CHUNK_BYTES: break (short read = EOF)

        If piece_index >= MAX_PIECES: break (file too large — silently truncate)

    pt_count    = piece_index
    total_lines = line_count + 1   ; +1 because the last line has no trailing LF

    ; Free the scan buffer segment  (INT 21h AH=49h, ES = scan_seg)
    ; No need to track in cache — it was a temporary allocation.

    CF = 0
    RET
```

### 3.1  Computing the 32-bit Seek Offset (`piece_index * CHUNK_BYTES`)

`CHUNK_BYTES = 8000h`. The 32-bit product `piece_index × 0x8000`:

```asm
; BX = piece_index (0..MAX_PIECES-1)
; Result: CX = high word,  DX = low word  (for INT 21h AH=42h)

MOV  AX, BX
SHR  AX, 1          ; AX = piece_index >> 1  (= high word of product)
MOV  CX, AX

MOV  DX, BX
AND  DX, 1          ; DX = piece_index & 1
MOV  CL, 15
SHL  DX, CL         ; DX = (piece_index & 1) << 15  (= low word of product)
                    ; Restore CL is not needed; CX already holds the value
                    ; but CX was clobbered! Fix:

; Correct sequence (CX must be set AFTER DX is shifted):
MOV  DX, BX
AND  DX, 1
MOV  CL, 15
SHL  DX, CL         ; DX = low word of (piece_index * CHUNK_BYTES)
MOV  AX, BX
SHR  AX, 1
MOV  CX, AX         ; CX = high word
; Now CX:DX = 32-bit file offset
; BX must be restored to file_hnd before INT 21h
```

### 3.2  Checkpoint Boundary Handling

When the checkpoint boundary falls exactly at the end of a piece (i.e. `chkpt_po` would equal `pt_len[piece]`), the checkpoint must refer to the start of the **next** piece instead:

```asm
; After incrementing line_count and determining a checkpoint is due:
; candidate: pi = current_piece_index, po = SI + 1  (or SI for wrap)
; if po >= pt_len[pi]:
;     pi = pi + 1
;     po = 0
; store chkpt_pi[chkpt_num] = pi,  chkpt_po[chkpt_num] = po
```

---

## Phase 4 — New Function: `page_in`

**Purpose:** Ensure piece `BX` is resident in the cache. Returns its segment in `AX`. If not already cached, allocates (or evicts a slot) and reads it from disk.

**Input:** `BX` = piece index (0..`pt_count`−1)  
**Output:** `AX` = segment, `CF=0` on success; `CF=1` on DOS error (alloc or read failed)  
**Preserved:** `BX`, `CX`, `DX`, `SI`, `DI`, `BP`

### Algorithm

```
page_in:
    PUSH BX, SI, DI                      ; save caller registers

    ; Step 1: Search for BX in cache_pi[]
    ; Scan cache_pi[0..cache_count-1] for a slot where cache_pi[i] == BX
    SI = 0
    CX = cache_count
    Loop CX times:
        If cache_pi[SI] == BX:
            ; Cache hit — update LRU and return
            INC [lru_clock]
            MOV AX, [lru_clock]
            MOV cache_lru[SI] = AX
            MOV AX = cache_seg[SI]
            POP DI, SI, BX
            CF = 0
            RET
        SI += 2  (advance to next WORD slot index)

    ; Step 2: Cache miss — need to load piece BX

    ; Step 2a: Find a free slot or choose an eviction victim
    MOV DI = 0xFFFF     ; DI = slot index of victim (best candidate so far)
    MOV AX = 0xFFFF     ; AX = lowest LRU seen

    If cache_count < MAX_CACHE:
        ; There is a free slot: use slot = cache_count, then increment cache_count
        ; Allocate a new segment for this slot
        MOV DI = cache_count
        CALL alloc_one_cache_slot(DI)   ; allocates 32 KB, stores in cache_seg[DI]
        If CF: POP ...; RET with CF=1
        INC [cache_count]
    Else:
        ; Find LRU victim: scan all slots for lowest cache_lru value
        SI = 0
        For each slot i in 0..MAX_CACHE-1:
            If cache_lru[SI] < AX (unsigned):
                AX = cache_lru[SI]
                DI = SI (in word units, not slot number — track carefully)
            SI += 2
        ; DI = word offset of LRU slot
        ; Mark slot as empty (overwrite its pi)
        cache_pi[DI] = 0FFFFh

    ; Step 2b: DI = word offset of the target slot

    ; Step 2c: Seek to piece BX's file position and read it
    ; Compute CX:DX = BX * CHUNK_BYTES  (use sequence from Phase 3.1)
    ; INT 21h AH=42h, AL=0 (seek from start), BX_file = [file_hnd]
    ; Save/restore BX (piece index) around the seek!
    PUSH BX
    [compute CX:DX from BX as in 3.1]
    MOV BX, [file_hnd]
    MOV AH, 42h
    MOV AL, 0
    INT 21h
    POP BX
    JC .io_error

    ; Read into cache_seg[DI]:0
    ; Must switch DS to the cache segment for the read
    PUSH DS
    MOV AX, cache_seg[DI]
    MOV DS, AX
    XOR DX, DX
    MOV BX, CS:[file_hnd]
    MOV CX, CHUNK_BYTES
    MOV AH, 3Fh
    INT 21h
    POP DS
    JC .io_error

    ; Step 2d: Update cache metadata
    INC [lru_clock]
    MOV AX, [lru_clock]
    MOV cache_lru[DI] = AX
    ; Restore piece index (was saved in PUSH BX)
    ; DI still holds the slot's word offset
    ; Convert DI to piece index: slot_number = DI/2
    MOV AX, [DI + cache_seg - (cache_seg - cache_seg)] ; = cache_seg[DI]
    ; (see note below on indexing — use parallel arrays with same DI)
    MOV cache_pi[DI] = BX_piece_index    ; piece index
    MOV AX = cache_seg[DI]               ; the allocated segment

    POP DI, SI, BX
    CF = 0
    RET

.io_error:
    POP DI, SI, BX
    CF = 1
    RET
```

**Implementation note on parallel array indexing:** `cache_seg`, `cache_pi`, and `cache_lru` all use the same word offset `DI`. When `DI` represents a slot, `DI = slot_number * 2`. Access as `[cache_seg + DI]`, `[cache_pi + DI]`, `[cache_lru + DI]`. Use `CS:` overrides when DS is switched.

---

## Phase 5 — New Function: `seek_to_line`

**Purpose:** Given a target visual line number, compute the exact `{piece_index, byte_offset}` of where that line begins. Stores the result directly into `rnd_pi` and `rnd_off`.

**Input:** `AX` = target line number (0-based, 0..`total_lines`−1)  
**Output:** `[rnd_pi]` and `[rnd_off]` set; `CF=0` on success, `CF=1` on page_in error  
**Preserved:** `AX`

### Algorithm

```
seek_to_line:
    PUSH AX BX CX DX SI

    ; Step 1: Find the best checkpoint C
    ; C = min(AX / CHKPT_INTERVAL,  chkpt_num - 1)
    MOV BX, AX
    MOV CX, CHKPT_INTERVAL
    XOR DX, DX
    DIV CX                  ; AX = AX / CHKPT_INTERVAL (quotient = C)
                            ; DX = remainder (lines_to_walk)
    ; Clamp C to chkpt_num - 1
    MOV CX, [chkpt_num]
    DEC CX
    CMP AX, CX
    JBE .c_ok
    MOV AX, CX
    ; Recompute lines_to_walk = BX - AX * CHKPT_INTERVAL
    MOV DX, AX
    MOV CX, CHKPT_INTERVAL
    MUL CX                  ; AX = C * CHKPT_INTERVAL
    MOV CX, DX              ; CX = original target saved in BX... 
    ; [careful: BX holds original target line — use it]
    MOV DX, BX              ; DX = original target
    SUB DX, AX              ; DX = lines_to_walk
    MOV AX, CX              ; AX = clamped C
.c_ok:
    ; AX = checkpoint index C,  DX = lines_to_walk

    ; Step 2: Load starting position from checkpoint C
    MOV SI, AX
    SHL SI, 1               ; SI = C * 2 (word offset)
    MOV BX, [chkpt_pi + SI] ; BX = piece index at checkpoint C
    MOV SI, [chkpt_po + SI] ; SI = byte offset within piece

    MOV [rnd_pi], BX
    MOV [rnd_off], SI

    ; If lines_to_walk == 0, we're done
    CMP DX, 0
    JE .done

    ; Step 3: Walk forward DX visual lines from {BX, SI}
    ; CX = lines remaining to skip
    MOV CX, DX

.walk_loop:
    ; Ensure piece BX is in cache
    CALL page_in            ; input: BX = piece index; output: AX = segment
    JC .page_err

    ; Set up DS:SI to read from this piece
    PUSH DS
    MOV DS, AX
    MOV DX, CS:[rnd_off]    ; DX = current byte offset (SI is our walker within piece)
    MOV SI, DX
    MOV DX, CS:[pt_len + BX*2]   ; DX = piece length (use CS:, DS is chunk now)
    ; (note: BX*2 — BX is piece index, SHL BX,1 first)
    ; Actually: save BX, shift, load, restore
    PUSH BX
    SHL BX, 1
    MOV DX, CS:[pt_len + BX]
    SHR BX, 1               ; restore BX
    POP BX

    ; Walk bytes in this piece
.inner:
    CMP SI, DX
    JAE .next_piece         ; reached end of this piece

    MOV AL, CS:[...?]       ; AL = DS:[SI] — read from chunk segment
    ; Wait: DS is chunk segment here, so [SI] reads from chunk correctly
    MOV AL, [SI]
    INC SI

    CMP AL, 0Dh             ; CR: skip
    JE .inner

    CMP AL, 0Ah             ; LF: one logical newline
    JNE .not_lf
    DEC CX
    JZ .found
    JMP .inner

.not_lf:
    ; In wrap mode, count columns
    CMP BYTE CS:[wrap_mode], 0
    JE .inner
    ; column tracking requires a local column counter register
    ; Use BP as column counter (save/restore around this function)
    INC BP
    CMP BP, SCREEN_COLS
    JB .inner
    XOR BP, BP
    DEC CX
    JZ .found
    JMP .inner

.next_piece:
    ; Advance to next piece
    POP DS
    INC BX
    MOV CS:[rnd_pi], BX
    XOR SI, SI
    MOV CS:[rnd_off], 0
    CMP BX, CS:[pt_count]
    JAE .eof            ; ran off the end of file
    JMP .walk_loop

.found:
    POP DS
    MOV [rnd_pi], BX
    MOV [rnd_off], SI   ; SI points to byte AFTER the newline/wrap point
    JMP .done

.eof:
    ; End of file before finding all lines — position at last piece start
    ; (Degenerate case for files ending without final newline)

.done:
    POP SI DX CX BX AX
    CF = 0
    RET

.page_err:
    POP SI DX CX BX AX
    CF = 1
    RET
```

**Register note:** `BP` is used as a column counter within the inner walk loop. It must be saved on entry to `seek_to_line` and zeroed at the start of the walk. The function should `PUSH BP` and `POP BP` accordingly.

---

## Phase 6 — Modify `render`

### 6.1  Replace the LI-fetch block at the top of `.row_loop`

Remove:
```asm
    ; ---- Is there a LI entry for this logical line? ----
    MOV     AX, BP
    CMP     AX, [li_count]
    JAE     .blank_row

    ; ---- Fetch LI entry AX into (rnd_pi, rnd_off) ----
    MOV     BX, AX
    SHL     BX, 1
    SHL     BX, 1
    PUSH    DS
    MOV     AX, [li_seg]
    MOV     DS, AX
    MOV     AX, [BX]
    MOV     SI, [BX+2]
    POP     DS
    MOV     [rnd_pi],  AX
    MOV     [rnd_off], SI
    ...
```

Replace with a **one-time call before the row loop begins**, placed immediately after `MOV BP, [top_line]`:

```asm
    ; Seek to the starting visual line
    MOV     AX, [top_line]
    CALL    seek_to_line
    ; rnd_pi and rnd_off are now set to the start of top_line
    ; (page_in errors during seek are silently tolerated — blank screen)
```

### 6.2  Change the row loop condition

Replace `CMP AX, [li_count]` / `JAE .blank_row` with a check against `total_lines`:

```asm
    MOV     AX, BP
    CMP     AX, [total_lines]
    JAE     .blank_row
```

### 6.3  Remove the LI-driven piece setup; use rnd_pi / rnd_off directly

The block that previously loaded `pt_seg[rnd_pi]` and `pt_len[rnd_pi]` remains, but must now call `page_in` to get the segment rather than loading from `pt_seg[]`:

```asm
    ; Get segment for current piece via demand pager
    MOV     BX, [rnd_pi]
    CALL    page_in             ; AX = segment, CF on error
    JC      .blank_row          ; on page fault, show blank row
    MOV     [rnd_seg], AX

    ; Load piece length
    MOV     BX, [rnd_pi]
    SHL     BX, 1
    MOV     DX, CS:[pt_len + BX]   ; use CS: — DS will switch shortly
    MOV     [rnd_len], DX

    ; Switch DS to chunk segment
    MOV     DS, AX
    MOV     SI, CS:[rnd_off]
```

### 6.4  Update `.adv_piece`

The existing `.adv_piece` code already uses `CS:` overrides to access `pt_count`, `pt_seg`, `pt_len`. Change it to call `page_in` instead of reading from `pt_seg[]`:

```asm
.adv_piece:
    MOV     AX, CS:[rnd_pi]
    INC     AX
    MOV     CS:[rnd_pi], AX
    CMP     AX, CS:[pt_count]
    JAE     .row_done

    ; Demand-page the new piece
    MOV     BX, AX
    PUSH    DS                  ; DS is currently chunk segment
    PUSH    CS
    POP     DS                  ; restore DS to COM segment temporarily
    CALL    page_in             ; BX = new piece index, AX = segment
    POP     DS                  ; this is now stale — overwrite immediately
    JC      .row_done           ; page fault: treat as end of row

    ; Load new piece length
    PUSH    BX
    SHL     BX, 1
    MOV     DX, [pt_len + BX]
    POP     BX
    MOV     CS:[rnd_len], DX
    MOV     CS:[rnd_seg], AX
    MOV     DS, AX
    XOR     SI, SI
    MOV     CS:[rnd_off], 0     ; update rnd_off to track position
    JMP     .char_loop
```

### 6.5  Track `rnd_off` during render

In the inner `.char_loop`, after every `INC SI`, also update `CS:[rnd_off]`:

```asm
    INC     SI
    MOV     CS:[rnd_off], SI    ; keep rnd_off in sync (needed if seek_to_line
                                ; is ever called mid-render; also aids debugging)
```

This is a minor overhead (one extra memory write per character) but keeps state consistent.

---

## Phase 7 — Modify `go_to`

Replace all references to `li_count` with `total_lines`:

```asm
; Old:
    MOV     AX, [li_count]
; New:
    MOV     AX, [total_lines]
```

This applies in two places: the `nav_max` computation and the `End` key handler in `main`.

---

## Phase 8 — Modify Status Bar in `render`

Replace `[li_count]` with `[total_lines]` in the `.do_status` section:

```asm
; Old:
    MOV     AX, [li_count]
    CALL    .wdec
; New:
    MOV     AX, [total_lines]
    CALL    .wdec
```

---

## Phase 9 — Replace `free_all`

The old `free_all` iterated over `alloc_lst[]`. Replace it with iteration over `cache_seg[0..cache_count-1]`:

```asm
free_all:
    PUSH    ES
    PUSH    CX
    PUSH    SI
    MOV     CX, [cache_count]
    JCXZ    .done
    XOR     SI, SI
.fl_lp:
    MOV     AX, [cache_seg + SI]
    MOV     ES, AX
    MOV     AH, 49h
    INT     21h
    ADD     SI, 2
    LOOP    .fl_lp
.done:
    POP     SI
    POP     CX
    POP     ES
    RET
```

---

## Phase 10 — Remove Deleted Functions

Delete the complete bodies of:

- `load_file` (entirely replaced by `scan_file`)
- `build_li` (entirely replaced by `scan_file` + `seek_to_line`)
- `alloc_li` (no longer needed)
- `alloc_seg` (replaced by direct inline allocation in `scan_file` and `page_in`)

---

## Phase 11 — String Literal Update

In the `s_loading` string, change to something that reflects the scan:

```asm
; Old:
s_loading:   DB  'Loading...',0Dh,0Ah,'$'

; New:
s_loading:   DB  'Scanning...',0Dh,0Ah,'$'
```

Also add a new error string for I/O errors during paging:

```asm
s_ioerr:     DB  'Error: file read error',0Dh,0Ah,'$'
```

---

## Phase 12 — COM Segment Size Budget

Verify the final COM binary fits within 32 768 bytes before the program is run.

Estimated sizes after changes:

| Section | Size |
|---------|------|
| Code (all procedures) | ~4 500 bytes |
| `filename` | 128 bytes |
| `pt_len[1024]` | 2 048 bytes |
| `chkpt_pi[2048]` | 4 096 bytes |
| `chkpt_po[2048]` | 4 096 bytes |
| `cache_seg/pi/lru` × 8 | 48 bytes |
| Other BSS variables | ~100 bytes |
| String literals | ~250 bytes |
| **Total** | **~15 266 bytes** |

This is comfortably under 32 768 bytes (the limit imposed by `shrink_mem`). If further functions are added, the `MAX_CHKPT` or `MAX_PIECES` values can be reduced.

---

## Phase 13 — Testing with agent86

### 13.1  Basic smoke test

```bash
agent86 TEXTREAD.ASM --build_run --screen CGA80 \
    --args "myfile.txt" \
    --events '[{"keys":"\x1B"}]'
```

Expect: `"executed":"IDLE"` or `"executed":"OK"` with a screen showing file content and the status bar.

### 13.2  Navigation test

```bash
agent86 TEXTREAD.ASM --build_run --screen CGA80 \
    --args "myfile.txt" \
    --events '[{"keys":"\x51\x51\x49\x1B"}]'
```

(Scan codes 51h = PgDn, 49h = PgUp, 1Bh = Esc — these must be injected as extended key sequences; see agent86 keyboard event format for scan-code injection.)

### 13.3  Large file testing

For files > ~5 MB the 100 M instruction limit will be hit during `scan_file`. Use:

```bash
agent86 TEXTREAD.ASM --build_run --run 1000000000 --screen CGA80 \
    --args "bigfile.txt" \
    --events '[{"keys":"\x1B"}]'
```

### 13.4  Wrap mode test

```bash
agent86 TEXTREAD.ASM --build_run --screen CGA80 \
    --args "--wrap longlines.txt" \
    --events '[{"keys":"\x1B"}]'
```

Verify the status bar shows `[WRAP]` and that long lines are visually wrapped.

### 13.5  Debug checkpoints

Use `BREAKPOINT` and `ASSERT_EQ` directives during development to verify key invariants:

```asm
; After scan_file completes:
    ASSERT_EQ [pt_count], 0     ; should NOT be 0 for a non-empty file
    ASSERT_EQ [chkpt_num], 1    ; must be at least 1
    ASSERT_EQ [total_lines], 0  ; should NOT be 0

; After seek_to_line with AX=0:
    ASSERT_EQ [rnd_pi], 0
    ASSERT_EQ [rnd_off], 0
```

Use `VRAMOUT` after render to inspect screen content:

```asm
    CALL render
    VRAMOUT FULL, ATTRS
    BREAKPOINT screen_check : VRAMOUT
```

---

## Summary of Changes by Function

| Function | Action | Reason |
|---|---|---|
| `main` | Remove `alloc_li`, `load_file`, `build_li`, close-file; add `scan_file`; add close-file in quit | New lifecycle |
| `load_file` | **Delete** | Replaced by `scan_file` |
| `build_li` | **Delete** | Replaced by `scan_file` + `seek_to_line` |
| `alloc_li` | **Delete** | No dedicated LI segment needed |
| `alloc_seg` | **Delete** | Inline alloc used in `scan_file` and `page_in` |
| `free_all` | **Rewrite** | Iterate `cache_seg[]` not `alloc_lst[]` |
| `go_to` | `li_count` → `total_lines` | New counter |
| `render` | Call `seek_to_line` once before row loop; use `page_in` in `.adv_piece` | Demand paging |
| **`scan_file`** | **New** | Streaming scan: fills `pt_len[]`, `chkpt_*`, `total_lines` |
| **`page_in`** | **New** | LRU cache manager: seeks + reads piece on demand |
| **`seek_to_line`** | **New** | Checkpoint lookup + forward walk to exact line |

