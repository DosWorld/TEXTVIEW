; ============================================================
; TEXTREAD.ASM  -  8086 Text File Viewer for MS-DOS
;
; Build:  agent86 TEXTREAD.ASM
; Usage:  TEXTREAD [--wrap] <filename>
; Keys:   PgUp/PgDn  Up/Down  Home  End  Esc=Quit
;
; ---- Architecture -----------------------------------------------
;
;  DEMAND-PAGED PIECE TABLE
;    The file is scanned once at startup (streaming, data not
;    retained) to record piece lengths and a sparse checkpoint
;    table.  Only MAX_CACHE (8) chunk segments are resident in
;    RAM at any time; pages are loaded on demand via LRU eviction.
;
;  CHECKPOINT TABLE
;    Every CHKPT_INTERVAL visual lines, the piece index and
;    byte offset are recorded.  To seek to any line:
;      1. O(1) checkpoint lookup
;      2. O(CHKPT_INTERVAL) forward walk from checkpoint
;
;  VIDEO OUTPUT
;    Text is written directly to the CGA/EGA/VGA text buffer at
;    B800:0000 — no BIOS calls for character output.
;
;  MEMORY LIFE-CYCLE
;    1. Startup: shrink COM block to 32 KB  (INT 21h / AH=4Ah)
;    2. scan_file: alloc+free one temp 32 KB scan buffer
;    3. page_in: alloc up to MAX_CACHE segments on demand
;    4. On exit: close file handle, free cache segments
;
;  Max file size: 1024 pieces x 32 KB = 32 MB
;  Max visual lines: 524 288
; ============================================================

    ORG     100h

; ------------------------------------------------------------
; CONSTANTS
; ------------------------------------------------------------

SCREEN_COLS    EQU  80
SCREEN_ROWS    EQU  25
TEXT_ROWS      EQU  24          ; rows 0-23 text, row 24 status bar
VIDEO_SEG      EQU  0B800h
ATTR_NORM      EQU  07h         ; light grey on black
ATTR_STAT      EQU  70h         ; black on light grey (status bar)

MAX_PIECES     EQU  1024        ; covers files up to 32 MB
MAX_CACHE      EQU  8           ; chunk segments resident simultaneously
CHUNK_PARA     EQU  0800h       ; 2048 paragraphs = 32 768 bytes
CHUNK_BYTES    EQU  8000h

CHKPT_INTERVAL EQU  256         ; checkpoint every 256 visual lines
MAX_CHKPT      EQU  2048        ; max checkpoints (covers 524 288 lines)

KEY_ESC        EQU  1Bh
SCAN_PGUP      EQU  49h
SCAN_PGDN      EQU  51h
SCAN_UP        EQU  48h
SCAN_DOWN      EQU  50h
SCAN_HOME      EQU  47h
SCAN_END       EQU  4Fh

; ============================================================
;  ENTRY  — jump over BSS + data to main
; ============================================================

    JMP     main

; ------------------------------------------------------------
; BSS  (DOS zeroes COM memory, so these start at 0)
; ------------------------------------------------------------

filename:    RESB 128   ; null-terminated from PSP command tail
wrap_mode:   RESB 1     ; 0 = truncate,  1 = wrap
file_hnd:    RESW 1     ; DOS file handle

; ---- Piece Table (metadata only, no allocated memory per piece) ----
pt_count:    RESW 1              ; total number of pieces
pt_len:      RESW MAX_PIECES     ; byte count of each piece

; ---- Chunk Cache ----
cache_count: RESW 1              ; slots currently allocated (0..MAX_CACHE)
cache_seg:   RESW MAX_CACHE      ; DOS segment address of each slot
cache_pi:    RESW MAX_CACHE      ; piece index held in slot (0FFFFh = empty)
cache_lru:   RESW MAX_CACHE      ; LRU timestamp for each slot
lru_clock:   RESW 1              ; global counter, incremented on cache hit

; ---- Checkpoint Table ----
chkpt_num:   RESW 1              ; number of checkpoints recorded
total_lines: RESW 1              ; total visual lines in the file
chkpt_pi:    RESW MAX_CHKPT      ; piece index at each checkpoint
chkpt_po:    RESW MAX_CHKPT      ; byte offset within piece at each checkpoint

; ---- View state ----
top_line:    RESW 1     ; visual line index of first visible row
nav_max:     RESW 1     ; scratch: max valid top_line

; ---- Saved hardware cursor shape ----
sav_curs:    RESW 1

; ---- Render-inner-loop scratch ----
rnd_pi:      RESW 1     ; current piece index while rendering a row
rnd_seg:     RESW 1     ; current chunk segment
rnd_off:     RESW 1     ; current byte offset within chunk
rnd_len:     RESW 1     ; current piece length
rnd_row:     RESW 1     ; current screen row (0..TEXT_ROWS-1)

; ---- seek_to_line scratch ----
stl_col:     RESW 1     ; column counter for wrap-mode walk

; ------------------------------------------------------------
; STRING LITERALS (INT 21h AH=09h  '$'-terminated)
; ------------------------------------------------------------

s_usage:     DB  'Usage: TEXTREAD [--wrap] <filename>',0Dh,0Ah,'$'
s_nofile:    DB  'Error: cannot open file',0Dh,0Ah,'$'
s_nomem:     DB  'Error: out of memory',0Dh,0Ah,'$'
s_loading:   DB  'Scanning...',0Dh,0Ah,'$'
s_stat_hdr:  DB  ' TEXTREAD  Line: $'
s_stat_sep:  DB  '/$'
s_stat_wrap: DB  ' [WRAP]$'
s_stat_keys: DB  '  PgUp/Dn Up/Dn Home End  Esc=Quit$'

; ============================================================
;                           MAIN
; ============================================================

main:
    ; Keep stack well below the 32 KB boundary we will set
    MOV     SP, 7FFEh

    ; ---- Release excess DOS memory (keep 32 KB) ----
    CALL    shrink_mem

    ; ---- Parse command line -> filename[], wrap_mode ----
    CALL    parse_args
    JC      .err_usage

    ; ---- Open file ----
    CALL    open_file
    JC      .err_nofile

    ; Brief status on stdout before taking over the display
    MOV     DX, s_loading
    MOV     AH, 09h
    INT     21h

    ; ---- Scan file: measure pieces + build checkpoint table ----
    CALL    scan_file
    JC      .err_nomem

    ; NOTE: file handle stays OPEN — do NOT close it here

    ; ---- Save & hide hardware cursor ----
    MOV     AH, 03h
    XOR     BH, BH
    INT     10h
    MOV     [sav_curs], CX
    MOV     AH, 01h
    MOV     CX, 2000h        ; no cursor
    INT     10h

    ; ---- Initial paint ----
    CALL    clear_scr
    MOV     WORD [top_line], 0
    CALL    render

    ; ================================================================
    ;  MAIN EVENT LOOP
    ; ================================================================
.evloop:
    XOR     AH, AH
    INT     16h              ; wait for key: AH = scan, AL = ASCII

    CMP     AL, KEY_ESC
    JE      .quit

    CMP     AH, SCAN_PGDN
    JNE     .ck_pgup
    MOV     AX, [top_line]
    ADD     AX, TEXT_ROWS
    CALL    go_to
    JMP     .evloop

.ck_pgup:
    CMP     AH, SCAN_PGUP
    JNE     .ck_dn
    MOV     AX, [top_line]
    SUB     AX, TEXT_ROWS
    CALL    go_to
    JMP     .evloop

.ck_dn:
    CMP     AH, SCAN_DOWN
    JNE     .ck_up
    MOV     AX, [top_line]
    INC     AX
    CALL    go_to
    JMP     .evloop

.ck_up:
    CMP     AH, SCAN_UP
    JNE     .ck_home
    MOV     AX, [top_line]
    DEC     AX
    CALL    go_to
    JMP     .evloop

.ck_home:
    CMP     AH, SCAN_HOME
    JNE     .ck_end
    XOR     AX, AX
    CALL    go_to
    JMP     .evloop

.ck_end:
    CMP     AH, SCAN_END
    JNE     .evloop
    MOV     AX, [total_lines]
    SUB     AX, TEXT_ROWS
    CALL    go_to
    JMP     .evloop

    ; ----------------------------------------------------------------
    ;  QUIT
    ; ----------------------------------------------------------------
.quit:
    ; Restore cursor shape
    MOV     AH, 01h
    MOV     CX, [sav_curs]
    INT     10h
    ; Park cursor at top-left
    MOV     AH, 02h
    XOR     BX, BX
    XOR     DX, DX
    INT     10h
    CALL    clear_scr
    ; Close the file handle (kept open since startup)
    MOV     BX, [file_hnd]
    MOV     AH, 3Eh
    INT     21h
    CALL    free_all
    INT     20h

    ; ---- Pre-screen error exits ----
.err_usage:
    MOV     DX, s_usage
    MOV     AH, 09h
    INT     21h
    INT     20h

.err_nofile:
    MOV     DX, s_nofile
    MOV     AH, 09h
    INT     21h
    INT     20h

.err_nomem:
    MOV     DX, s_nomem
    MOV     AH, 09h
    INT     21h
    INT     20h

; ============================================================
; GO_TO  — navigate to logical line AX, clamp, then render
; ============================================================

go_to:
    ; Clamp negative (bit 15 set after subtraction underflow)
    TEST    AX, 8000h
    JNZ     .zero

    ; nav_max = max(0, total_lines - TEXT_ROWS)
    PUSH    AX
    MOV     AX, [total_lines]
    CMP     AX, TEXT_ROWS
    JBE     .small_file
    SUB     AX, TEXT_ROWS
    MOV     [nav_max], AX
    POP     AX
    CMP     AX, [nav_max]
    JBE     .set
    MOV     AX, [nav_max]
    JMP     .set

.small_file:
    POP     AX
.zero:
    XOR     AX, AX
.set:
    MOV     [top_line], AX
    CALL    render
    RET

; ============================================================
; SHRINK_MEM  — resize our COM segment to 32 KB (2048 paras)
; ============================================================

shrink_mem:
    PUSH    ES
    MOV     AX, CS
    MOV     ES, AX
    MOV     AH, 4Ah
    MOV     BX, 0800h
    INT     21h
    POP     ES
    RET

; ============================================================
; PARSE_ARGS
; Reads PSP tail at DS:80h.  Sets filename[], wrap_mode.
; Returns CF=1 if no filename found.
; ============================================================

parse_args:
    MOV     BYTE [wrap_mode], 0
    MOV     SI, 81h
    XOR     CH, CH
    MOV     CL, [80h]
    CMP     CX, 0
    JE      .no_fn

    ; Skip leading spaces
.skip1:
    TEST    CX, CX
    JZ      .no_fn
    MOV     AL, [SI]
    CMP     AL, ' '
    JNE     .got_tok
    INC     SI
    DEC     CX
    JMP     .skip1

.got_tok:
    ; Check for "--wrap" token
    CMP     CX, 6
    JB      .copy_fn
    CMP     BYTE [SI],   '-'
    JNE     .copy_fn
    CMP     BYTE [SI+1], '-'
    JNE     .copy_fn
    MOV     AL, [SI+2]
    OR      AL, 20h          ; fold to lower case
    CMP     AL, 'w'
    JNE     .copy_fn
    ; Matched "--w..." — accept as --wrap
    MOV     BYTE [wrap_mode], 1
    ADD     SI, 6
    SUB     CX, 6
    JBE     .no_fn
    ; Skip spaces between flag and filename
.skip2:
    JCXZ    .no_fn
    MOV     AL, [SI]
    CMP     AL, ' '
    JNE     .copy_fn
    INC     SI
    DEC     CX
    JMP     .skip2

    ; Copy filename until whitespace or end
.copy_fn:
    JCXZ    .no_fn
    MOV     DI, filename
.cfloop:
    JCXZ    .fn_done
    MOV     AL, [SI]
    CMP     AL, ' '
    JE      .fn_done
    CMP     AL, 0Dh
    JE      .fn_done
    CMP     AL, 0Ah
    JE      .fn_done
    MOV     [DI], AL
    INC     SI
    INC     DI
    DEC     CX
    JMP     .cfloop
.fn_done:
    MOV     BYTE [DI], 0
    CMP     DI, filename
    JE      .no_fn
    CLC
    RET
.no_fn:
    STC
    RET

; ============================================================
; OPEN_FILE  — open filename[] read-only (AH=3Dh)
; Returns CF=1 on error.
; ============================================================

open_file:
    MOV     DX, filename
    XOR     AL, AL
    MOV     AH, 3Dh
    INT     21h
    JC      .err
    MOV     [file_hnd], AX
    CLC
    RET
.err:
    STC
    RET

; ============================================================
; SCAN_FILE
; Streaming pass over the entire file to:
;   - Determine piece count and each piece's byte length
;   - Count total visual lines
;   - Record checkpoints every CHKPT_INTERVAL lines
;
; Allocates one temporary 32 KB scan buffer, frees before return.
; Returns CF=0 on success, CF=1 if scan buffer alloc fails.
; ============================================================

scan_file:
    PUSH    BX
    PUSH    CX
    PUSH    DX
    PUSH    SI
    PUSH    DI
    PUSH    BP
    PUSH    ES

    ; Allocate one 32 KB scan buffer
    MOV     BX, CHUNK_PARA
    MOV     AH, 48h
    INT     21h
    JC      .sf_fail
    ; AX = scan buffer segment — save in ES for later free
    MOV     ES, AX

    ; Initialise state
    MOV     WORD [pt_count], 0
    MOV     WORD [chkpt_num], 0
    MOV     WORD [total_lines], 0
    MOV     WORD [cache_count], 0
    MOV     WORD [lru_clock], 0

    ; Record checkpoint 0: line 0 begins at piece 0, offset 0
    MOV     WORD [chkpt_pi], 0
    MOV     WORD [chkpt_po], 0
    MOV     WORD [chkpt_num], 1

    XOR     BP, BP            ; BP = piece_index
    MOV     WORD [stl_col], 0 ; column counter for wrap

.sf_next_piece:
    ; Bail if piece table full
    CMP     BP, MAX_PIECES
    JAE     .sf_done

    ; Seek to piece_index * CHUNK_BYTES
    ; Compute CX:DX = BP * 8000h
    ; Low word  = (BP & 1) << 15
    ; High word = BP >> 1
    MOV     DX, BP
    AND     DX, 1
    MOV     CL, 15
    SHL     DX, CL         ; DX = low word
    MOV     AX, BP
    SHR     AX, 1
    MOV     CX, AX         ; CX = high word
    ; Now CX:DX = 32-bit file offset
    MOV     BX, [file_hnd]
    MOV     AX, 4200h      ; AH=42h, AL=0 (seek from start)
    INT     21h
    JC      .sf_done        ; seek error = treat as done

    ; Read CHUNK_BYTES into scan buffer (ES:0)
    PUSH    DS
    PUSH    ES
    POP     DS              ; DS = scan buffer segment
    XOR     DX, DX          ; buffer at DS:0000
    MOV     BX, CS:[file_hnd]
    MOV     CX, CHUNK_BYTES
    MOV     AH, 3Fh
    INT     21h
    POP     DS
    JC      .sf_done        ; read error

    ; AX = bytes actually read
    TEST    AX, AX
    JZ      .sf_done        ; 0 bytes = EOF

    ; Store pt_len[piece_index] = AX
    MOV     SI, BP
    SHL     SI, 1
    MOV     [SI + pt_len], AX

    ; Save bytes_read for comparison later
    MOV     DI, AX          ; DI = bytes_read

    INC     BP              ; piece_index++

    ; Walk the bytes just read (SI = 0..AX-1)
    PUSH    DS
    PUSH    ES
    POP     DS              ; DS = scan buffer segment
    XOR     SI, SI          ; SI = byte offset within buffer

.sf_byte_loop:
    CMP     SI, DI
    JAE     .sf_end_walk

    MOV     AL, [SI]
    INC     SI

    ; CR: skip
    CMP     AL, 0Dh
    JE      .sf_byte_loop

    ; LF: newline
    CMP     AL, 0Ah
    JNE     .sf_not_lf

    MOV     WORD CS:[stl_col], 0
    INC     WORD CS:[total_lines]

    ; Check if checkpoint is due: (total_lines % CHKPT_INTERVAL) == 0
    MOV     AX, CS:[total_lines]
    TEST    AX, CHKPT_INTERVAL - 1   ; CHKPT_INTERVAL is power of 2
    JNZ     .sf_byte_loop

    ; Record checkpoint
    CALL    .sf_record_chkpt
    JMP     .sf_byte_loop

.sf_not_lf:
    INC     WORD CS:[stl_col]

    ; In wrap mode: did we reach the right edge?
    CMP     BYTE CS:[wrap_mode], 0
    JE      .sf_byte_loop
    MOV     AX, CS:[stl_col]
    CMP     AX, SCREEN_COLS
    JB      .sf_byte_loop

    ; Wrap: reset column, count visual line
    MOV     WORD CS:[stl_col], 0
    INC     WORD CS:[total_lines]

    ; Check if checkpoint is due
    MOV     AX, CS:[total_lines]
    TEST    AX, CHKPT_INTERVAL - 1
    JNZ     .sf_byte_loop

    ; Record checkpoint (po = SI, the byte AFTER the wrap point)
    CALL    .sf_record_chkpt
    JMP     .sf_byte_loop

.sf_end_walk:
    POP     DS              ; restore COM segment

    ; If short read, we're at EOF
    CMP     DI, CHUNK_BYTES
    JB      .sf_done

    ; Otherwise try next piece
    JMP     .sf_next_piece

.sf_done:
    ; pt_count = piece_index
    MOV     [pt_count], BP

    ; total_lines += 1 (last line has no trailing LF)
    ; But only if we actually read data
    CMP     BP, 0
    JE      .sf_no_plus
    INC     WORD [total_lines]
.sf_no_plus:

    ; Free the scan buffer segment (ES = scan_seg)
    MOV     AH, 49h
    INT     21h

    POP     ES
    POP     BP
    POP     DI
    POP     SI
    POP     DX
    POP     CX
    POP     BX
    CLC
    RET

.sf_fail:
    POP     ES
    POP     BP
    POP     DI
    POP     SI
    POP     DX
    POP     CX
    POP     BX
    STC
    RET

; ---- .sf_record_chkpt: record a checkpoint ----
; Called with DS = scan buffer, CS: for all COM vars
; SI = current byte offset in buffer (byte AFTER the LF/wrap)
; BP = current piece_index (already incremented, so piece = BP-1)
.sf_record_chkpt:
    PUSH    BX
    PUSH    AX

    MOV     AX, CS:[chkpt_num]
    CMP     AX, MAX_CHKPT
    JAE     .sf_rc_done

    ; Compute slot offset
    MOV     BX, AX
    SHL     BX, 1           ; BX = chkpt_num * 2

    ; Candidate: pi = BP-1 (current piece), po = SI
    MOV     AX, BP
    DEC     AX              ; AX = piece index of current piece

    ; Check boundary: if SI >= pt_len[pi], move to next piece
    PUSH    SI
    PUSH    AX
    MOV     SI, AX
    SHL     SI, 1
    MOV     SI, CS:[SI + pt_len]  ; SI = pt_len[pi]
    POP     AX
    ; Now compare original SI (on stack) with piece length (in SI reg)
    ; Need to get original SI back... awkward. Let me restructure.
    POP     SI              ; restore SI = byte offset

    ; DI was saved as bytes_read, but let's check against piece length
    ; Since we're walking piece (BP-1) and DI = bytes_read = pt_len[BP-1],
    ; if SI == DI then we're at piece boundary
    CMP     SI, DI
    JB      .sf_rc_store

    ; At piece boundary: point to start of next piece
    MOV     AX, BP          ; BP = next piece index (already incremented)
    XOR     SI, SI           ; offset 0 of next piece
    ; But we need to restore SI for the byte loop after return!
    ; Actually SI is the walk pointer. If SI == DI, the byte loop
    ; will exit at .sf_end_walk anyway. So this checkpoint correctly
    ; points to start of next piece, and SI continues as-is.

.sf_rc_store:
    MOV     CS:[BX + chkpt_pi], AX
    MOV     CS:[BX + chkpt_po], SI
    INC     WORD CS:[chkpt_num]

.sf_rc_done:
    POP     AX
    POP     BX
    RET

; ============================================================
; PAGE_IN
; Ensure piece BX is resident in the cache.
; Input:  BX = piece index (0..pt_count-1)
; Output: AX = segment, CF=0 on success; CF=1 on error
; Preserved: BX, CX, DX, SI, DI, BP
; ============================================================

page_in:
    PUSH    SI
    PUSH    DI
    PUSH    CX
    PUSH    DX
    PUSH    BP

    ; Step 1: Search cache_pi[] for a hit
    MOV     CX, [cache_count]
    JCXZ    .pi_miss
    XOR     SI, SI          ; SI = word offset into cache arrays
.pi_scan:
    CMP     [SI + cache_pi], BX
    JE      .pi_hit
    ADD     SI, 2
    LOOP    .pi_scan

.pi_miss:
    ; Step 2: Cache miss — need to load piece BX

    ; Step 2a: Find a free slot or choose LRU victim
    MOV     AX, [cache_count]
    CMP     AX, MAX_CACHE
    JAE     .pi_evict

    ; Free slot available at index cache_count
    MOV     DI, AX          ; DI = slot index (not word offset yet)
    SHL     DI, 1           ; DI = word offset of free slot

    ; Allocate a new 32 KB segment for this slot
    PUSH    BX
    MOV     BX, CHUNK_PARA
    MOV     AH, 48h
    INT     21h
    POP     BX
    JC      .pi_err

    ; Store segment in cache_seg[DI]
    MOV     [DI + cache_seg], AX
    INC     WORD [cache_count]
    JMP     .pi_load

.pi_evict:
    ; Find LRU victim: lowest cache_lru value
    XOR     SI, SI
    MOV     DI, 0           ; DI = word offset of best candidate
    MOV     AX, [cache_lru] ; AX = lowest LRU seen (start with slot 0)
    ADD     SI, 2
    MOV     CX, MAX_CACHE - 1
.pi_lru_scan:
    CMP     [SI + cache_lru], AX
    JAE     .pi_lru_next
    MOV     AX, [SI + cache_lru]
    MOV     DI, SI
.pi_lru_next:
    ADD     SI, 2
    LOOP    .pi_lru_scan
    ; DI = word offset of LRU slot

.pi_load:
    ; Step 2b: DI = word offset of target slot
    ; Mark it with the new piece index
    MOV     [DI + cache_pi], BX

    ; Step 2c: Seek to piece BX's file position
    ; Compute CX:DX = BX * CHUNK_BYTES (= BX * 8000h)
    PUSH    BX              ; save piece index
    MOV     DX, BX
    AND     DX, 1
    MOV     CL, 15
    SHL     DX, CL          ; DX = low word
    MOV     AX, BX
    SHR     AX, 1
    MOV     CX, AX          ; CX = high word
    MOV     BX, [file_hnd]
    MOV     AX, 4200h       ; seek from start
    INT     21h
    POP     BX              ; restore piece index
    JC      .pi_io_err

    ; Step 2d: Read into cache_seg[DI]:0
    PUSH    DS
    MOV     AX, [DI + cache_seg]
    MOV     DS, AX
    PUSH    DX              ; save DX
    XOR     DX, DX          ; buffer at DS:0000
    PUSH    BX              ; save piece index
    MOV     BX, CS:[file_hnd]
    MOV     CX, CHUNK_BYTES
    MOV     AH, 3Fh
    INT     21h
    POP     BX              ; restore piece index
    POP     DX              ; restore DX
    POP     DS
    JC      .pi_io_err

    ; Step 2e: Update LRU
    INC     WORD [lru_clock]
    MOV     AX, [lru_clock]
    MOV     [DI + cache_lru], AX

    ; Return the segment
    MOV     AX, [DI + cache_seg]

    POP     BP
    POP     DX
    POP     CX
    POP     DI
    POP     SI
    CLC
    RET

.pi_hit:
    ; Cache hit — update LRU and return segment
    INC     WORD [lru_clock]
    MOV     AX, [lru_clock]
    MOV     [SI + cache_lru], AX
    MOV     AX, [SI + cache_seg]

    POP     BP
    POP     DX
    POP     CX
    POP     DI
    POP     SI
    CLC
    RET

.pi_io_err:
    ; Mark slot as empty on I/O error
    MOV     WORD [DI + cache_pi], 0FFFFh
.pi_err:
    POP     BP
    POP     DX
    POP     CX
    POP     DI
    POP     SI
    STC
    RET

; ============================================================
; SEEK_TO_LINE
; Given target visual line AX, compute {piece_index, byte_offset}
; and store into rnd_pi, rnd_off.
; Input:  AX = target line number (0-based)
; Output: [rnd_pi], [rnd_off] set; CF=0 OK, CF=1 page_in error
; Preserved: AX
; ============================================================

seek_to_line:
    PUSH    AX
    PUSH    BX
    PUSH    CX
    PUSH    DX
    PUSH    SI
    PUSH    DI
    PUSH    BP

    ; Save target line in DI for later
    MOV     DI, AX

    ; Step 1: Find checkpoint C = AX / CHKPT_INTERVAL
    ; Since CHKPT_INTERVAL = 256 (power of 2), use shifts
    ; C = AX >> 8,  remainder = AX & 0FFh
    MOV     BX, AX          ; BX = target line
    MOV     CL, 8
    SHR     AX, CL          ; AX = C (quotient)
    MOV     DX, BX
    AND     DX, 0FFh        ; DX = remainder (lines_to_walk)

    ; Clamp C to chkpt_num - 1
    MOV     CX, [chkpt_num]
    DEC     CX
    CMP     AX, CX
    JBE     .stl_c_ok

    ; C was clamped — recompute lines_to_walk
    MOV     AX, CX          ; AX = clamped C
    ; lines_to_walk = target - C * CHKPT_INTERVAL
    ; C * 256 = C << 8
    MOV     DX, AX
    MOV     CL, 8
    SHL     DX, CL          ; DX = C * 256
    MOV     CX, DI          ; CX = original target
    SUB     CX, DX          ; CX = lines_to_walk
    MOV     DX, CX          ; DX = lines_to_walk

.stl_c_ok:
    ; AX = checkpoint index C, DX = lines_to_walk

    ; Step 2: Load starting position from checkpoint C
    MOV     SI, AX
    SHL     SI, 1            ; SI = C * 2 (word offset)
    MOV     BX, [SI + chkpt_pi]   ; BX = piece index
    MOV     SI, [SI + chkpt_po]   ; SI = byte offset within piece

    MOV     [rnd_pi], BX
    MOV     [rnd_off], SI

    ; If lines_to_walk == 0, we're done
    TEST    DX, DX
    JZ      .stl_done

    ; Step 3: Walk forward DX visual lines from {BX, SI}
    MOV     CX, DX          ; CX = lines remaining to skip
    MOV     WORD [stl_col], 0  ; reset column counter

.stl_walk_loop:
    ; Ensure piece BX is in cache
    CALL    page_in          ; BX = piece index, AX = segment
    JC      .stl_page_err

    ; Set up to read from this piece
    PUSH    DS
    MOV     DS, AX           ; DS = chunk segment

    ; Get piece length
    PUSH    BX
    SHL     BX, 1
    MOV     DX, CS:[BX + pt_len]
    POP     BX               ; BX = piece index again

    ; SI = current byte offset within piece (from rnd_off)
    MOV     SI, CS:[rnd_off]

.stl_inner:
    CMP     SI, DX
    JAE     .stl_next_piece

    MOV     AL, [SI]
    INC     SI

    CMP     AL, 0Dh          ; CR: skip
    JE      .stl_inner

    CMP     AL, 0Ah          ; LF: newline
    JNE     .stl_not_lf

    MOV     WORD CS:[stl_col], 0
    DEC     CX
    JZ      .stl_found
    JMP     .stl_inner

.stl_not_lf:
    ; In wrap mode, count columns
    CMP     BYTE CS:[wrap_mode], 0
    JE      .stl_inner
    INC     WORD CS:[stl_col]
    MOV     AX, CS:[stl_col]
    CMP     AX, SCREEN_COLS
    JB      .stl_inner

    ; Wrap point
    MOV     WORD CS:[stl_col], 0
    DEC     CX
    JZ      .stl_found
    JMP     .stl_inner

.stl_next_piece:
    POP     DS               ; restore COM segment
    INC     BX
    MOV     [rnd_pi], BX
    XOR     SI, SI
    MOV     [rnd_off], SI    ; = 0
    CMP     BX, [pt_count]
    JAE     .stl_eof
    JMP     .stl_walk_loop

.stl_found:
    POP     DS               ; restore COM segment
    MOV     [rnd_pi], BX
    MOV     [rnd_off], SI    ; SI = byte AFTER the newline/wrap

.stl_done:
    POP     BP
    POP     DI
    POP     SI
    POP     DX
    POP     CX
    POP     BX
    POP     AX
    CLC
    RET

.stl_eof:
    ; End of file before finding all lines
    ; Leave rnd_pi/rnd_off at last known position
    JMP     .stl_done

.stl_page_err:
    POP     BP
    POP     DI
    POP     SI
    POP     DX
    POP     CX
    POP     BX
    POP     AX
    STC
    RET

; ============================================================
; RENDER
; Paint TEXT_ROWS rows of text + status bar onto B800.
;
; Calls seek_to_line once for top_line, then streams forward
; row by row using page_in for demand paging.
; ============================================================

render:
    PUSH    DS
    PUSH    ES
    PUSH    BP
    PUSH    BX
    PUSH    SI
    PUSH    DI

    ; ES = video segment throughout the whole render
    MOV     AX, VIDEO_SEG
    MOV     ES, AX

    ; BP = top_line snapshot (logical index of first row)
    MOV     BP, [top_line]

    ; Seek to the starting visual line
    MOV     AX, [top_line]
    CALL    seek_to_line
    ; rnd_pi and rnd_off are now set to the start of top_line

    MOV     WORD [rnd_row], 0  ; screen row counter (0..23)

; ----------------------------------------------------------------
;  ROW LOOP
; ----------------------------------------------------------------
.row_loop:
    MOV     AX, [rnd_row]
    CMP     AX, TEXT_ROWS
    JAE     .do_status

    ; DI = video byte offset of start of this row  = row * 160
    MOV     CX, SCREEN_COLS * 2
    MUL     CX
    MOV     DI, AX

    ; ---- Is there content for this logical line? ----
    MOV     AX, BP
    CMP     AX, [total_lines]
    JAE     .blank_row

    ; ---- Get segment for current piece via demand pager ----
    MOV     BX, [rnd_pi]
    CMP     BX, [pt_count]
    JAE     .blank_row       ; past last piece
    CALL    page_in          ; AX = segment, CF on error
    JC      .blank_row       ; on page fault, show blank row
    MOV     [rnd_seg], AX

    ; Load piece length
    MOV     BX, [rnd_pi]
    SHL     BX, 1
    MOV     DX, [BX + pt_len]
    MOV     [rnd_len], DX

    ; Switch DS to chunk segment
    MOV     DS, AX           ; DS = chunk segment
    MOV     SI, CS:[rnd_off] ; SI = starting byte offset

    ; CX = column counter (0..SCREEN_COLS-1)
    XOR     CX, CX

; ---- INNER CHARACTER LOOP ----
.char_loop:
    CMP     CX, SCREEN_COLS
    JAE     .row_done

    ; Check end of current piece
    CMP     SI, CS:[rnd_len]
    JAE     .adv_piece

    MOV     AL, [SI]
    INC     SI

    CMP     AL, 0Dh           ; CR: skip
    JE      .char_loop

    CMP     AL, 0Ah           ; LF: end of logical line
    JE      .row_done_lf

    ; Write character + attribute to video
    MOV     ES:[DI],   AL
    MOV     BYTE ES:[DI+1], ATTR_NORM
    ADD     DI, 2
    INC     CX
    JMP     .char_loop

.adv_piece:
    ; Advance to next piece
    MOV     AX, CS:[rnd_pi]
    INC     AX
    MOV     CS:[rnd_pi], AX
    CMP     AX, CS:[pt_count]
    JAE     .row_done         ; no more pieces -> treat as end of file

    ; Demand-page the new piece
    MOV     BX, AX
    PUSH    DS
    PUSH    CS
    POP     DS               ; restore DS to COM segment temporarily
    CALL    page_in          ; BX = piece index, AX = segment
    POP     DS               ; pop stale DS (overwrite immediately)
    JC      .row_done        ; page fault: treat as end of row

    ; Load new piece length
    PUSH    BX
    SHL     BX, 1
    MOV     DX, CS:[BX + pt_len]
    POP     BX
    MOV     CS:[rnd_len], DX
    MOV     CS:[rnd_seg], AX
    MOV     DS, AX
    XOR     SI, SI
    MOV     WORD CS:[rnd_off], 0
    JMP     .char_loop

.row_done_lf:
    ; After LF: update rnd_off to point past it, for next row
    MOV     CS:[rnd_off], SI
    JMP     .row_pad

.row_done:
    ; End of row (columns full, or end-of-piece/file)
    ; Update rnd_off to current position for next row
    MOV     CS:[rnd_off], SI

.row_pad:
    ; DS is currently chunk segment — restore
    PUSH    CS
    POP     DS

    ; Pad remainder of row with spaces
    ; CX = columns written so far
    MOV     AX, SCREEN_COLS
    SUB     AX, CX
    MOV     CX, AX            ; CX = spaces to pad
    JCXZ    .row_next
.pad_loop:
    MOV     BYTE ES:[DI],   ' '
    MOV     BYTE ES:[DI+1], ATTR_NORM
    ADD     DI, 2
    LOOP    .pad_loop
    JMP     .row_next

.blank_row:
    ; No content — fill row with spaces
    MOV     CX, SCREEN_COLS
.blank_loop:
    MOV     BYTE ES:[DI],   ' '
    MOV     BYTE ES:[DI+1], ATTR_NORM
    ADD     DI, 2
    LOOP    .blank_loop

.row_next:
    INC     WORD [rnd_row]    ; next screen row
    INC     BP                ; next logical line
    JMP     .row_loop

; ================================================================
;  STATUS BAR  (row 24)
; ================================================================
.do_status:
    ; DI = start of row 24
    MOV     DI, TEXT_ROWS * SCREEN_COLS * 2

    ; Restore DS = COM segment
    PUSH    CS
    POP     DS

    ; "TEXTREAD  Line: "
    MOV     SI, s_stat_hdr
    CALL    .wstr

    ; Current line number (top_line + 1, 1-based)
    MOV     AX, [top_line]
    INC     AX
    CALL    .wdec

    ; "/"
    MOV     SI, s_stat_sep
    CALL    .wstr

    ; Total lines
    MOV     AX, [total_lines]
    CALL    .wdec

    ; "[WRAP]" if wrap mode active
    CMP     BYTE [wrap_mode], 0
    JE      .no_wrap_lbl
    MOV     SI, s_stat_wrap
    CALL    .wstr
.no_wrap_lbl:

    ; Key hints
    MOV     SI, s_stat_keys
    CALL    .wstr

    ; Pad rest of status bar
.stat_pad:
    CMP     DI, (SCREEN_ROWS) * SCREEN_COLS * 2
    JAE     .stat_done
    MOV     BYTE ES:[DI],   ' '
    MOV     BYTE ES:[DI+1], ATTR_STAT
    ADD     DI, 2
    JMP     .stat_pad
.stat_done:

    POP     DI
    POP     SI
    POP     BX
    POP     BP
    POP     ES
    POP     DS
    RET

; ---- .wstr : write '$'-terminated string at DS:SI to ES:DI ----
.wstr:
.ws_lp:
    MOV     AL, [SI]
    CMP     AL, '$'
    JE      .ws_done
    MOV     ES:[DI],   AL
    MOV     BYTE ES:[DI+1], ATTR_STAT
    ADD     DI, 2
    INC     SI
    JMP     .ws_lp
.ws_done:
    RET

; ---- .wdec : write AX as decimal digits to ES:DI ----
.wdec:
    PUSH    AX
    PUSH    BX
    PUSH    CX
    PUSH    DX

    MOV     BX, 10
    XOR     CX, CX

    TEST    AX, AX
    JNZ     .wd_split

    ; Special-case zero
    MOV     BYTE ES:[DI],   '0'
    MOV     BYTE ES:[DI+1], ATTR_STAT
    ADD     DI, 2
    JMP     .wd_done

.wd_split:
    ; Divide AX by 10 repeatedly, push remainders
    TEST    AX, AX
    JZ      .wd_emit
    XOR     DX, DX
    DIV     BX
    PUSH    DX
    INC     CX
    JMP     .wd_split

.wd_emit:
    POP     DX
    MOV     AL, DL
    ADD     AL, '0'
    MOV     ES:[DI],   AL
    MOV     BYTE ES:[DI+1], ATTR_STAT
    ADD     DI, 2
    LOOP    .wd_emit

.wd_done:
    POP     DX
    POP     CX
    POP     BX
    POP     AX
    RET

; ============================================================
; CLEAR_SCR  — fill 80x25 with spaces (ATTR_NORM)
; ============================================================

clear_scr:
    PUSH    ES
    PUSH    DI
    PUSH    CX
    MOV     AX, VIDEO_SEG
    MOV     ES, AX
    XOR     DI, DI
    MOV     CX, SCREEN_ROWS * SCREEN_COLS
.cl_lp:
    MOV     BYTE ES:[DI],   ' '
    MOV     BYTE ES:[DI+1], ATTR_NORM
    ADD     DI, 2
    LOOP    .cl_lp
    POP     CX
    POP     DI
    POP     ES
    RET

; ============================================================
; FREE_ALL  — release all cache segments
; ============================================================

free_all:
    PUSH    ES
    PUSH    CX
    PUSH    SI
    MOV     CX, [cache_count]
    JCXZ    .done
    XOR     SI, SI
.fl_lp:
    MOV     AX, [SI + cache_seg]
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

; ============================================================
; End of TEXTREAD.ASM
; ============================================================
