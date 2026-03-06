{$M 64000,400000,650000}
{$S-,R-,O-,F-,I-,D-,L-,A-,V-,Q-,G-,E-}
program TextView;

{==============================================================================
  TEXTVIEW - Text file viewer for DOS with demand paging and wrap mode.
  Direct video access, 32 KB chunks, LRU cache, checkpoint navigation.

  Build: Turbo Pascal 7.0 (or compatible)
  Usage: TVIEW [--wrap] <filename>
  Keys:  PgUp/PgDn  Up/Down  Home  End  Esc=Quit

  Copyright (c) 2026 cookertron, DosWorld
  License: Public domain.

  https://github.com/DosWorld/TEXTVIEW
==============================================================================}

const
  ATTR_NORM    = $1F;                 { light grey on black }
  ATTR_STAT    = $30;                 { black on light grey }
  ATTR_SPEC    = $1E;
  ATTR_DIGIT   = $1B;

  MAX_PIECES   = 1024;                { up to 32 MB file (1024 * 32K) }
  MAX_CACHE    = 8;                   { number of cached 32K chunks }
  CHUNK_SIZE   = 32768;               { 32 KB in bytes }
  CHKPT_INTERVAL = 256;               { checkpoint every 256 visual lines }
  MAX_CHKPT    = 2048;                 { covers 524 288 lines }

  SCAN_ESC     = $01;
  SCAN_PGUP    = $49;
  SCAN_PGDN    = $51;
  SCAN_UP      = $48;
  SCAN_DOWN    = $50;
  SCAN_HOME    = $47;
  SCAN_END     = $4F;

type
  TChunk = array[0..CHUNK_SIZE-1] of Byte;
  PChunk = ^TChunk;

var
  { Direct video memory access }
  Video: PChar;

  { Command line }
  filename: string[128];
  wrap_mode: Boolean;

  { File handle }
  f: file;

  { Piece table }
  pt_count: Word;
  pt_len: array[0..MAX_PIECES-1] of Word;

  { Chunk cache }
  cache_count: Word;
  cache_ptr: array[0..MAX_CACHE-1] of PChunk;
  cache_pi: array[0..MAX_CACHE-1] of Word;      { piece index, $FFFF = empty }
  cache_lru: array[0..MAX_CACHE-1] of Word;
  lru_clock: Word;

  { Checkpoint table }
  chkpt_num: Word;
  total_lines: Word;
  chkpt_pi: array[0..MAX_CHKPT-1] of Word;
  chkpt_po: array[0..MAX_CHKPT-1] of Word;

  { View state }
  top_line: Word;                     { first visual line on screen (0-based) }

  { Saved cursor shape }
  sav_curs: Word;

  { Temporary scan buffer }
  scan_buf: PChunk;

  rnd_pi, rnd_off : word;

  text_rows,
  screen_cols, screen_rows : Integer;
  SysChars : String;
{----------------------------- Helper procedures -----------------------------}
procedure Render;forward;

function getheight : integer;assembler;
asm
        push       ds
        mov        ax, seg0040
        mov        ds, ax
        mov        al, byte ptr[$0084]
        xor        ah, ah
        inc        ax
        pop        ds
end;

function getwidth : integer;assembler;
asm
        push       ds
        mov        ax, seg0040
        mov        ds, ax
        mov        ax, word ptr[$004a]
        pop        ds
end;

function GetScanCode: byte;assembler;
asm
        xor ax,ax
        int $16
        mov al, ah
end;

procedure ErrorMsg(const s: string);
begin
  Writeln(s);
  Halt(1);
end;

{------------------------------------------------------------------------------
  Parse command line
------------------------------------------------------------------------------}
procedure ParseArgs;
begin
  wrap_mode := False;
  filename := '';
          if paramCount = 1 then begin
                      filename := ParamStr(1);
                      exit;
          end else if paramCount = 2 then begin
              if paramstr(1) = '--wrap' then begin
                      wrap_mode := True;
                      filename := ParamStr(2);
                      exit;
              end;
          end;
  ErrorMsg('Usage: TEXTVIEW [--wrap] <filename>');
end;

{------------------------------------------------------------------------------
  Free all cached chunks
------------------------------------------------------------------------------}
procedure FreeAll;
var
  i: Integer;
begin
  for i := 0 to cache_count-1 do
    if cache_ptr[i] <> nil then
      FreeMem(cache_ptr[i], CHUNK_SIZE);
  cache_count := 0;
end;

{------------------------------------------------------------------------------
  Clear screen using direct video access
------------------------------------------------------------------------------}
procedure ClearScreen(clr : BYTE);
var
  i: Integer;
begin
  for i := 0 to screen_rows * screen_cols - 1 do
  begin
    Video[i*2] := ' ';
    Video[i*2+1] := Chr(clr);
  end;
end;

{==============================================================================
  SCANNING  one pass through the file, building piece table and checkpoints
==============================================================================}
procedure ScanFile;
var
  piece: Word;
  bytes_read: Word;
  i: Word;
  b: Byte;
  col: Word;
  lines: Word;
  chkpt_idx: Word;
  pos_in_file: LongInt;
begin
  { Allocate one temporary 32 KB scan buffer }
  GetMem(scan_buf, CHUNK_SIZE);
  if scan_buf = nil then ErrorMsg('Error: out of memory');

  pt_count := 0;
  chkpt_num := 0;
  total_lines := 0;
  col := 0;

  { Checkpoint 0: line 0 starts at piece 0, offset 0 }
  chkpt_pi[0] := 0;
  chkpt_po[0] := 0;
  chkpt_num := 1;

  piece := 0;

  while True do
  begin
    pos_in_file := LongInt(piece) * CHUNK_SIZE;
    Seek(f, pos_in_file);
    if IOResult <> 0 then Break;

    BlockRead(f, scan_buf^, CHUNK_SIZE, bytes_read);
    if bytes_read = 0 then Break;

    if piece >= MAX_PIECES then Break;      { too many pieces }
    pt_len[piece] := bytes_read;

    for i := 0 to bytes_read - 1 do
    begin
      b := scan_buf^[i];

      if b = 13 then Continue;    { skip CR }

      if b = 10 then              { LF -> end of visual line }
      begin
        col := 0;
        Inc(total_lines);

        { Checkpoint every CHKPT_INTERVAL lines }
        if (total_lines and (CHKPT_INTERVAL-1)) = 0 then
        begin
          if chkpt_num < MAX_CHKPT then
          begin
            if i+1 = bytes_read then
            begin
              { Checkpoint points to next piece (offset 0) }
              chkpt_pi[chkpt_num] := piece + 1;
              chkpt_po[chkpt_num] := 0;
            end
            else
            begin
              chkpt_pi[chkpt_num] := piece;
              chkpt_po[chkpt_num] := i + 1;
            end;
            Inc(chkpt_num);
          end;
        end;
      end
      else
      begin
        Inc(col);

        if wrap_mode and (col >= screen_cols) then
        begin
          col := 0;
          Inc(total_lines);

          if (total_lines and (CHKPT_INTERVAL-1)) = 0 then
          begin
            if chkpt_num < MAX_CHKPT then
            begin
              if i+1 = bytes_read then
              begin
                chkpt_pi[chkpt_num] := piece + 1;
                chkpt_po[chkpt_num] := 0;
              end
              else
              begin
                chkpt_pi[chkpt_num] := piece;
                chkpt_po[chkpt_num] := i + 1;
              end;
              Inc(chkpt_num);
            end;
          end;
        end;
      end;
    end;

    Inc(piece);
    if bytes_read < CHUNK_SIZE then Break;    { EOF }
  end;

  pt_count := piece;

  { Last line (file without trailing LF) }
  if pt_count > 0 then Inc(total_lines);

  FreeMem(scan_buf, CHUNK_SIZE);
end;

{==============================================================================
  CACHE MANAGEMENT  demand paging with LRU
==============================================================================}

{ Find piece index in cache; returns -1 if not found }
function FindInCache(piece: Word): Integer;
var
  i: Integer;
begin
  for i := 0 to cache_count-1 do
    if cache_pi[i] = piece then
    begin
      FindInCache := i;
      Exit;
    end;
  FindInCache := -1;
end;

{ Find index of least recently used slot (among all MAX_CACHE slots) }
function FindLRU: Integer;
var
  i, lru_idx: Integer;
  min_lru: Word;
begin
  lru_idx := 0;
  min_lru := cache_lru[0];
  for i := 1 to MAX_CACHE-1 do
    if cache_lru[i] < min_lru then
    begin
      min_lru := cache_lru[i];
      lru_idx := i;
    end;
  FindLRU := lru_idx;
end;

{ Load piece into cache, return pointer to chunk data, or nil on error }
function PageIn(piece: Word): PChunk;
var
  idx: Integer;
  pos: LongInt;
  bytes_read: Word;
  newptr: PChunk;
begin
  { Cache hit? }
  idx := FindInCache(piece);
  if idx >= 0 then
  begin
    Inc(lru_clock);
    cache_lru[idx] := lru_clock;
    PageIn := cache_ptr[idx];
    Exit;
  end;

  { Miss: need to load }
  if cache_count < MAX_CACHE then
  begin
    idx := cache_count;           { first free slot }
    Inc(cache_count);
  end
  else
  begin
    idx := FindLRU;                { evict LRU slot }
    if cache_ptr[idx] <> nil then
      FreeMem(cache_ptr[idx], CHUNK_SIZE);
  end;

  { Allocate new chunk }
  GetMem(newptr, CHUNK_SIZE);
  if newptr = nil then
  begin
    PageIn := nil;
    Exit;
  end;

  { Seek to piece offset in file }
  pos := LongInt(piece) * CHUNK_SIZE;
  Seek(f, pos);
  if IOResult <> 0 then
  begin
    FreeMem(newptr, CHUNK_SIZE);
    PageIn := nil;
    Exit;
  end;

  BlockRead(f, newptr^, CHUNK_SIZE, bytes_read);
  { Ignore short read; pt_len[piece] contains actual length }

  { Fill cache slot }
  cache_ptr[idx] := newptr;
  cache_pi[idx] := piece;
  Inc(lru_clock);
  cache_lru[idx] := lru_clock;

  PageIn := newptr;
end;

{==============================================================================
  NAVIGATION  seek to a specific visual line
==============================================================================}

{ Given target visual line (0-based), compute piece index and byte offset.
  Returns False on page-in error. }
function SeekToLine(target: Word): Boolean;
var
  c, lines_left: Word;
  pi, off: Word;
  chunk: PChunk;
  chunk_len: Word;
  col: Word;
  b: Byte;
begin
  SeekToLine := False;

  { Find checkpoint index = target div CHKPT_INTERVAL (power of two) }
  c := target shr 8;                 { same as target div 256 }
  lines_left := target and $FF;       { remainder }

  if c >= chkpt_num then
  begin
    c := chkpt_num - 1;
    lines_left := target - (c shl 8);
  end;

  pi := chkpt_pi[c];
  off := chkpt_po[c];

  if lines_left = 0 then
  begin
    rnd_pi := pi;
    rnd_off := off;
    SeekToLine := True;
    Exit;
  end;

  col := 0;
  while lines_left > 0 do
  begin
    chunk := PageIn(pi);
    if chunk = nil then Exit;

    chunk_len := pt_len[pi];

    while off < chunk_len do
    begin
      b := chunk^[off];
      Inc(off);

      if b = 13 then Continue;

      if b = 10 then          { LF -> end of visual line }
      begin
        col := 0;
        Dec(lines_left);
        if lines_left = 0 then Break;
      end
      else
      begin
        if wrap_mode then
        begin
          Inc(col);
          if col >= screen_cols then
          begin
            col := 0;
            Dec(lines_left);
            if lines_left = 0 then Break;
          end;
        end;
      end;
    end;

    if lines_left > 0 then
    begin
      { Move to next piece }
      Inc(pi);
      off := 0;
      if pi >= pt_count then Break;   { EOF }
    end;
  end;

  rnd_pi := pi;
  rnd_off := off;
  SeekToLine := True;
end;

{------------------------------------------------------------------------------
  Clamp and set new top line, then render
------------------------------------------------------------------------------}
procedure GoToLine(line: Integer);
var
  max_line: Integer;
begin
  if line < 0 then line := 0;
  max_line := total_lines - text_rows;
  if max_line < 0 then max_line := 0;
  if line > max_line then line := max_line;
  top_line := line;
  Render;
end;

{==============================================================================
  RENDERING  paint text and status bar directly to video memory
==============================================================================}

{ Write a Pascal string to video at position DI, using status attribute }
procedure WriteStr(var di: Word; const s: String);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
  begin
    Video[di] := s[i];
    Video[di+1] := Chr(ATTR_STAT);
    Inc(di, 2);
  end;
end;

{ Write a word as decimal to video at DI }
procedure WriteDec(var di: Word; val: Word);
var
  buf: string[16];
  i: Integer;
begin
  Str(val, buf);
  for i := 1 to Length(buf) do
  begin
    Video[di] := buf[i];
    Video[di+1] := Chr(ATTR_STAT);
    Inc(di, 2);
  end;
end;

{ Main render routine }
procedure Render;
var
  line_num: Word;               { current logical line (0-based) }
  row: Word;                     { current screen row (0..23) }
  di: Word;                      { video offset for current row }
  col: Word;                      { column on screen }
  chunk: PChunk;
  chunk_len: Word;
  pi, off: Word;
  b: Byte;
begin
  { Seek to the first line to display }
  if not SeekToLine(top_line) then
  begin
    ClearScreen(ATTR_NORM);
    Exit;
  end;

  pi := rnd_pi;
  off := rnd_off;
  line_num := top_line;
  row := 0;


  { --- Status bar (row 24) --- }
  di := 0;
  WriteStr(di, ' Line: ');
  WriteDec(di, top_line + 1);
  WriteStr(di, ' / ');
  WriteDec(di, total_lines);
  WriteStr(di, '  ');
  if wrap_mode then
    WriteStr(di, '[WRAP] ');
  WriteStr(di, 'Esc=Quit');

  { Pad to the end of status line }
  while di < screen_cols * 2 do
  begin
    Video[di] := ' ';
    Video[di+1] := Chr(ATTR_STAT);
    Inc(di, 2);
  end;

  while row < text_rows do
  begin
    di := (row + 1) * screen_cols * 2;

    if line_num >= total_lines then
    begin
      { Blank line }
      FillChar(Video[di], screen_cols*2, Ord(' '));
      for col := 1 to screen_cols do
        Video[di + col*2 - 1] := Chr(ATTR_NORM);
      Inc(row);
      Inc(line_num);
      Continue;
    end;

    chunk := PageIn(pi);
    if chunk = nil then
    begin
      { Page error -> blank line }
      FillChar(Video[di], screen_cols*2, Ord(' '));
      for col := 1 to screen_cols do
        Video[di + col*2 - 1] := Chr(ATTR_NORM);
      Inc(row);
      Inc(line_num);
      Continue;
    end;

    chunk_len := pt_len[pi];
    col := 0;

    { Fill the screen row character by character }
    while col < screen_cols do
    begin
      { If current piece exhausted, move to next }
      if off >= chunk_len then
      begin
        Inc(pi);
        off := 0;
        if pi >= pt_count then Break;        { EOF }
        chunk := PageIn(pi);
        if chunk = nil then Break;
        chunk_len := pt_len[pi];
      end;

      b := chunk^[off];
      Inc(off);

      if b = 13 then Continue;                { skip CR }

      if b = 10 then                          { LF -> end of logical line }
      begin
        Inc(line_num);
        Break;
      end;

      { Normal character }
      Video[di] := Chr(b);
      Video[di+1] := Chr(ATTR_NORM);
      Inc(di, 2);
      Inc(col);

      { Wrap mode: if we reached the right edge, the logical line continues
        on the next screen row without incrementing line_num. }
      if wrap_mode and (col >= screen_cols) then
        Break;
    end;

    { Pad the rest of the row with spaces }
    while col < screen_cols do
    begin
      Video[di] := ' ';
      Video[di+1] := Chr(ATTR_NORM);
      Inc(di, 2);
      Inc(col);
    end;

    Inc(row);
    { If we exited because of wrap, line_num stays unchanged;
      otherwise it already advanced on LF or EOF. }
  end;
  di := screen_cols shl 1;
  while di < (screen_cols * screen_rows) shl 1 do
  begin
    Video[di+1] := SysChars[ord(Video[di])];
    Inc(di, 2);
  end;
end;

procedure Init;
var     i : integer;
begin
        FillChar(SysChars[1], 255, Chr(ATTR_NORM));
        SysChars[0] := #255;
        SysChars[ord('+')] := Chr(ATTR_SPEC);
        SysChars[ord('-')] := Chr(ATTR_SPEC);
        SysChars[ord('*')] := Chr(ATTR_SPEC);
        SysChars[ord('.')] := Chr(ATTR_SPEC);
        SysChars[ord(',')] := Chr(ATTR_SPEC);
        SysChars[ord('?')] := Chr(ATTR_SPEC);
        SysChars[ord('!')] := Chr(ATTR_SPEC);
        SysChars[ord('(')] := Chr(ATTR_SPEC);
        SysChars[ord(')')] := Chr(ATTR_SPEC);
        SysChars[ord('[')] := Chr(ATTR_SPEC);
        SysChars[ord(']')] := Chr(ATTR_SPEC);
        SysChars[ord('{')] := Chr(ATTR_SPEC);
        SysChars[ord('}')] := Chr(ATTR_SPEC);
        SysChars[ord('|')] := Chr(ATTR_SPEC);
        SysChars[ord('/')] := Chr(ATTR_SPEC);
        SysChars[ord('\')] := Chr(ATTR_SPEC);
        SysChars[ord('%')] := Chr(ATTR_SPEC);
        SysChars[ord('@')] := Chr(ATTR_SPEC);
        SysChars[ord('#')] := Chr(ATTR_SPEC);
        SysChars[ord('$')] := Chr(ATTR_SPEC);
        SysChars[ord('%')] := Chr(ATTR_SPEC);
        SysChars[ord('^')] := Chr(ATTR_SPEC);
        SysChars[ord('&')] := Chr(ATTR_SPEC);
        SysChars[ord('_')] := Chr(ATTR_SPEC);
        SysChars[ord('=')] := Chr(ATTR_SPEC);
        SysChars[ord('<')] := Chr(ATTR_SPEC);
        SysChars[ord('>')] := Chr(ATTR_SPEC);
        SysChars[ord('~')] := Chr(ATTR_SPEC);
        SysChars[ord('`')] := Chr(ATTR_SPEC);
        SysChars[ord('"')] := Chr(ATTR_SPEC);
        SysChars[$27] := Chr(ATTR_SPEC);
        for i := $b3 to $da do SysChars[i] := Chr(ATTR_SPEC);
        SysChars[ord(':')] := Chr(ATTR_SPEC);
        SysChars[ord(';')] := Chr(ATTR_SPEC);
        SysChars[ord('0')] := Chr(ATTR_DIGIT);
        SysChars[ord('1')] := Chr(ATTR_DIGIT);
        SysChars[ord('2')] := Chr(ATTR_DIGIT);
        SysChars[ord('3')] := Chr(ATTR_DIGIT);
        SysChars[ord('4')] := Chr(ATTR_DIGIT);
        SysChars[ord('5')] := Chr(ATTR_DIGIT);
        SysChars[ord('6')] := Chr(ATTR_DIGIT);
        SysChars[ord('7')] := Chr(ATTR_DIGIT);
        SysChars[ord('8')] := Chr(ATTR_DIGIT);
        SysChars[ord('9')] := Chr(ATTR_DIGIT);

  screen_cols  := getwidth;
  screen_rows  := getheight;
  text_rows := screen_rows - 1;
  Video := Ptr(SegB800,0000);
end;

{==============================================================================
  MAIN
==============================================================================}
var
  scan: Byte;
begin
  Init;
  { Parse command line }
  ParseArgs;

  { Open file }
  Assign(f, filename);
  Reset(f, 1);
  if IOResult <> 0 then ErrorMsg('Error: cannot open file');

  { Initial message }
  Writeln('Scanning...');

  { Scan file and build metadata }
  ScanFile;

  { Save cursor shape (BIOS call) }
  asm
    mov ah, 03h
    xor bh, bh
    int 10h
    mov sav_curs, cx
  end;

  { Hide cursor }
  asm
    mov ah, 01h
    mov cx, 2000h
    int 10h
  end;

  { Initial display }
  ClearScreen(ATTR_NORM);
  top_line := 0;
  Render;

  { Event loop }
  repeat
      scan := GetScanCode;
      case scan of
        SCAN_PGDN: GoToLine(top_line + text_rows);
        SCAN_PGUP: GoToLine(top_line - text_rows);
        SCAN_DOWN: GoToLine(top_line + 1);
        SCAN_UP:   GoToLine(top_line - 1);
        SCAN_HOME: GoToLine(0);
        SCAN_END:  GoToLine(total_lines - text_rows);
      end;
  until scan = SCAN_ESC;

  { Restore cursor }
  asm
    mov ah, 01h
    mov cx, sav_curs
    int 10h
  end;

  { Clean up }
  Close(f);
  FreeAll;
  ClearScreen(7);
end.
