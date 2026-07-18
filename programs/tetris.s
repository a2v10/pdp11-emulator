; ===================== TETRIS for the PDP-11 =====================
;
; Korobeiniki belongs here: Tetris was born on an Elektronika-60, a
; Soviet PDP-11 clone, in 1984. This one runs on the same machine.
;
; Screen: 512x512 @ 1 bpp, framebuffer at FB, 64. bytes per row.
;   The well is 10 x 20 cells, each cell 24x24 px (3 bytes wide).
;   Interior top-left at (x=136., y=16.); byte 0 of a row is the left.
;   A cell looks like an Arkanoid brick: filled, a 1px grid gap on the
;   right and bottom, and a small 3px hole punched in the centre.
;
; Controls: left/right move, fire (space/up) rotates, down hard-drops
; (one press drops the piece all the way and locks it).
;
; Devices:
;   LKS 177546 - KW11 line clock, the 60 Hz "vsync"; the whole game
;     lives in the clock interrupt handler.
;   JOY 177570 - bit 0 left, bit 1 right, bit 2 fire, bit 3 down.
;   SPK 177544 - one-bit speaker; we toggle it for effects.
;
; The board is 20 words, one per row, bit c = column c occupied.
; Pieces are tables of four cells in a 4x4 box; a cell byte packs
; (dy<<2 | dx). No multiply or divide anywhere - the layout is all
; powers of two, so addressing stays additive, MACRO-11 style.

FB      = 60000
LKS     = 177546
JOY     = 177570
SPK     = 177544

SCBASE  = 70060            ; score digits:  x=384., y=64.
LNBASE  = 100060           ; line counter:  x=384., y=128.
LVBASE  = 110060           ; level digit:   x=384., y=192.

        . = 100            ; clock interrupt vector
        .WORD VSYNC, 340

        . = 1000
START:  MOV #60000, SP
        JSR PC, BORDER
        JSR PC, INITBD     ; clear the board words
        JSR PC, MKROWA     ; build the row-address table
        JSR PC, SHOWSC
        JSR PC, SHOWLN
        JSR PC, SHOWLV
        JSR PC, SPAWN      ; first piece (board empty: never tops out)
        JSR PC, DRAWP
        MOV #100, @#LKS    ; enable clock interrupts
IDLE:   WAIT
        BR IDLE

; ===================== frame handler =====================
VSYNC:  INC FCNT
        JSR PC, ERASEP     ; lift the active piece off the screen
        JSR PC, INPUT      ; rotate + horizontal (with DAS)
        JSR PC, GRAV       ; gravity; may lock + spawn + clear lines
        JSR PC, DRAWP      ; put the active piece back down
        RTI

; ===================== input =====================
INPUT:  MOV @#JOY, R0
        MOV R0, JOYS
        ; --- down: a single press drops the piece all the way (hard drop) ---
        BIT #10, R0
        BEQ INDU
        TST PREVD
        BNE INRJ           ; still held from an earlier frame: ignore
        MOV #1, PREVD
        JSR PC, HARDDROP   ; lands, locks and spawns the next piece
        RTS PC
INDU:   CLR PREVD
INRJ:   ; --- rotate, edge-triggered on the fire button (or up) ---
        BIT #24, R0
        BNE INRF
        CLR PREVF
        BR INHZ
INRF:   TST PREVF
        BNE INHZ
        MOV #1, PREVF
        MOV CURX, TX
        MOV CURY, TY
        MOV CURR, R1
        INC R1
        BIC #177774, R1    ; (r+1) & 3
        MOV R1, TR
        JSR PC, TRYSET
        TST R0
        BNE INRO
        MOV CURX, TX       ; wall kick: nudge left
        DEC TX
        JSR PC, TRYSET
        TST R0
        BNE INRO
        MOV CURX, TX       ; or right
        INC TX
        JSR PC, TRYSET
        TST R0
        BEQ INHZ
INRO:   JSR PC, SROT
INHZ:   ; --- horizontal motion with delayed auto-shift ---
        MOV JOYS, R0
        BIC #177774, R0    ; keep left|right
        CMP R0, #1
        BEQ INL
        CMP R0, #2
        BEQ INR
        CLR DASDIR         ; neither or both: rest the stick
        CLR DASCNT
        BR INDN
INL:    MOV #177777, R1    ; -1
        BR INDAS
INR:    MOV #1, R1
INDAS:  CMP R1, DASDIR
        BEQ INHELD
        MOV R1, DASDIR     ; fresh press: move once now
        MOV #16., DASCNT   ; then wait out the DAS delay
        BR INMV
INHELD: DEC DASCNT
        BGT INDN
        MOV #6., DASCNT    ; auto-repeat cadence
INMV:   MOV CURX, TX
        ADD DASDIR, TX
        MOV CURY, TY
        MOV CURR, TR
        JSR PC, TRYSET
INDN:   RTS PC

; ---- TRYSET: if (TX,TY,TR) is legal, commit it. R0 = 1 if moved ----
TRYSET: JSR PC, CHKPOS
        TST R0
        BNE TSF
        MOV TX, CURX
        MOV TY, CURY
        MOV TR, CURR
        MOV #1, R0
        RTS PC
TSF:    CLR R0
        RTS PC

; ===================== gravity =====================
GRAV:   INC GTIMER
        MOV LEVEL, R0
        ASL R0
        MOV GRAVT(R0), R1  ; frames per cell at this level
        CMP GTIMER, R1
        BLT GRVD
        CLR GTIMER
        MOV CURX, TX
        MOV CURY, TY
        INC TY
        MOV CURR, TR
        JSR PC, CHKPOS
        TST R0
        BNE GRVL
        INC CURY           ; one cell down
        BR GRVD
GRVL:   JSR PC, LOCKSEQ    ; can't fall: lock and bring the next piece
GRVD:   RTS PC

; ---- HARDDROP: fall until something stops the piece, then lock it ----
HARDDROP:
HD1:    MOV CURX, TX
        MOV CURY, TY
        INC TY
        MOV CURR, TR
        JSR PC, CHKPOS
        TST R0
        BNE HD2
        INC CURY
        BR HD1
HD2:    JSR PC, LOCKSEQ
        RTS PC

; ---- LOCKSEQ: stamp the piece into the board, clear full lines,
;      score them, and spawn the next piece. Tops out via HALT. ----
LOCKSEQ:JSR PC, LOCKP
        JSR PC, CLEARLN
        MOV R0, NLINES
        TST R0
        BEQ LSNO
        JSR PC, ADDSCR
        JSR PC, ADDLN
        JSR PC, REDRAW     ; the stack shifted: repaint the well
        JSR PC, SHOWSC
        JSR PC, SHOWLN
        JSR PC, SHOWLV
        JSR PC, SLINE
        BR LSSP
LSNO:   JSR PC, DRAWP      ; nothing cleared: just show the locked piece
        JSR PC, SLOCK
LSSP:   JSR PC, SPAWN
        TST R0
        BNE LSOVER
        RTS PC
LSOVER: HALT               ; game over

; ===================== collision =====================
; ---- CHKPOS: does piece CURP, rotation TR at (TX,TY) collide with a
;      wall, the floor, or the stack? R0 = 1 on collision, else 0. ----
CHKPOS: MOV CURP, R5
        ASL R5
        ASL R5
        ASL R5
        ASL R5             ; piece * 16.
        MOV TR, R0
        ASL R0
        ASL R0             ; rotation * 4
        ADD R0, R5
        ADD #PIECES, R5    ; R5 -> four cell bytes
        MOV #4, PCNT
CK1:    MOVB (R5)+, R0
        MOV R0, R1
        BIC #177774, R0    ; dx
        ASR R1
        ASR R1
        BIC #177774, R1    ; dy
        ADD TX, R0         ; column
        ADD TY, R1         ; row
        TST R0
        BLT CKHIT          ; off the left wall
        CMP R0, #9.
        BGT CKHIT          ; off the right wall
        CMP R1, #19.
        BGT CKHIT          ; through the floor
        MOV R1, R2
        ASL R2
        MOV BOARD(R2), R3
        MOV R0, R2
        ASL R2
        BIT BITMSK(R2), R3
        BNE CKHIT          ; into the stack
        DEC PCNT
        BNE CK1
        CLR R0
        RTS PC
CKHIT:  MOV #1, R0
        RTS PC

; ---- LOCKP: set the board bits for the active piece ----
LOCKP:  JSR PC, PCELLS
        MOV #4, PCNT
LKP1:   MOVB (R5)+, R0
        MOV R0, R1
        BIC #177774, R0
        ASR R1
        ASR R1
        BIC #177774, R1
        ADD CURX, R0
        ADD CURY, R1
        MOV R1, R2
        ASL R2
        MOV R0, R3
        ASL R3
        BIS BITMSK(R3), BOARD(R2)
        DEC PCNT
        BNE LKP1
        RTS PC

; ===================== line clearing =====================
; ---- CLEARLN: drop every full row, return the count in R0 ----
CLEARLN:CLR R4
        MOV #19., R1       ; scan from the bottom up
LC1:    TST R1
        BLT LC9
        MOV R1, R2
        ASL R2
        CMP BOARD(R2), #1777
        BNE LCN            ; not full
        INC R4
        MOV R1, R3         ; pull everything above down by one
LCS:    TST R3
        BEQ LCT
        MOV R3, R0
        ASL R0
        MOV R0, R5
        SUB #2, R5
        MOV BOARD(R5), BOARD(R0)
        DEC R3
        BR LCS
LCT:    CLR BOARD          ; row 0 comes in empty
        BR LC1             ; recheck this row - more may have fallen in
LCN:    DEC R1
        BR LC1
LC9:    MOV R4, R0
        RTS PC

; ---- REDRAW: paint the whole well from the board bits ----
REDRAW: CLR RDROW
RD1:    CLR RDCOL
RD2:    MOV RDROW, R1
        MOV R1, R2
        ASL R2
        MOV BOARD(R2), R3
        MOV RDCOL, R0
        MOV R0, R2
        ASL R2
        BIT BITMSK(R2), R3
        BEQ RDER
        MOV RDCOL, R0
        MOV RDROW, R1
        JSR PC, DCELL
        BR RD3
RDER:   MOV RDCOL, R0
        MOV RDROW, R1
        JSR PC, ECELL
RD3:    INC RDCOL
        CMP RDCOL, #10.
        BLT RD2
        INC RDROW
        CMP RDROW, #20.
        BLT RD1
        RTS PC

; ===================== scoring =====================
; ---- ADDSCR: add the line bonus (BCD) for NLINES cleared ----
ADDSCR: MOV NLINES, R0
        DEC R0
        MOV R0, R1
        ASL R1             ; *2
        ASL R0
        ASL R0             ; *4
        ADD R1, R0         ; *6 -> byte offset into SCOREINC
        ADD #SCOREINC, R0
        MOV R0, R5
        MOV #SCORE, R2
        MOV #6, R3
        CLR R4             ; carry
ASC1:   MOVB (R5)+, R0
        ADD R4, R0
        MOVB (R2), R1
        ADD R1, R0
        CLR R4
        CMP R0, #10.
        BLT ASC2
        SUB #10., R0
        MOV #1, R4
ASC2:   MOVB R0, (R2)+
        DEC R3
        BNE ASC1
        RTS PC

; ---- ADDLN: add NLINES to the line counter, recompute the level ----
ADDLN:  MOV NLINES, R4
ALNL:   INCB LINES
        CMPB LINES, #10.
        BLT ALNX
        CLRB LINES
        INCB LINES+1
        CMPB LINES+1, #10.
        BLT ALNX
        CLRB LINES+1
        INCB LINES+2
ALNX:   DEC R4
        BNE ALNL
        TSTB LINES+2       ; level = lines / 10., capped at 9.
        BEQ ALV1
        MOV #9., LEVEL
        RTS PC
ALV1:   CLR LEVEL
        MOVB LINES+1, LEVEL
        RTS PC

; ===================== spawning =====================
; ---- SPAWN: pick the next piece, place it at the top. R0 = 1 if it
;      cannot be placed (the stack reached the top: game over). ----
SPAWN:  JSR PC, NEXTP
        MOV R0, CURP
        MOV #3, CURX
        CLR CURY
        CLR CURR
        CLR GTIMER         ; the next piece gets a full drop interval
        MOV CURX, TX
        MOV CURY, TY
        MOV CURR, TR
        JSR PC, CHKPOS
        RTS PC

; ---- NEXTP: a piece index 0..6 from the LFSR (reroll the 8th) ----
NEXTP:  JSR PC, LFSR
        MOV SEED, R0
        BIC #177770, R0    ; & 7
        CMP R0, #7
        BEQ NEXTP
        RTS PC

; ---- LFSR: 16-bit Galois generator, poly 0xB400 ----
LFSR:   CLC
        ROR SEED
        BCC LFR
        MOV #132000, R0
        XOR R0, SEED
LFR:    RTS PC

; ===================== piece geometry helpers =====================
; ---- PCELLS: R5 -> the four cell bytes of (CURP, CURR) ----
PCELLS: MOV CURP, R5
        ASL R5
        ASL R5
        ASL R5
        ASL R5
        MOV CURR, R0
        ASL R0
        ASL R0
        ADD R0, R5
        ADD #PIECES, R5
        RTS PC

; ---- DRAWP / ERASEP: paint or lift the four cells of the piece ----
DRAWP:  JSR PC, PCELLS
        MOV #4, PCNT
DP1:    MOVB (R5)+, R0
        MOV R0, R1
        BIC #177774, R0
        ASR R1
        ASR R1
        BIC #177774, R1
        ADD CURX, R0
        ADD CURY, R1
        JSR PC, DCELL
        DEC PCNT
        BNE DP1
        RTS PC

ERASEP: JSR PC, PCELLS
        MOV #4, PCNT
EP1:    MOVB (R5)+, R0
        MOV R0, R1
        BIC #177774, R0
        ASR R1
        ASR R1
        BIC #177774, R1
        ADD CURX, R0
        ADD CURY, R1
        JSR PC, ECELL
        DEC PCNT
        BNE EP1
        RTS PC

; ===================== cell rasteriser =====================
; ---- CELLADR: R0 = col, R1 = row -> R2 = framebuffer address.
;      Clobbers R0, R1. ----
CELLADR:MOV R1, R2
        ASL R2             ; row * 2 -> table index
        MOV ROWA(R2), R2   ; top-left of column 0 in this row
        MOV R0, R1
        ASL R0
        ADD R1, R0         ; col * 3 bytes
        ADD R0, R2
        RTS PC

; ---- DCELL: draw a filled cell (R0 = col, R1 = row), 3 bytes/row ----
DCELL:  JSR PC, CELLADR
        MOV #CELLP, R3
        MOV #24., R4
DC1:    MOVB (R3)+, (R2)
        MOVB (R3)+, 1(R2)
        MOVB (R3)+, 2(R2)
        ADD #100, R2
        SOB R4, DC1
        RTS PC

; ---- ECELL: clear a cell (R0 = col, R1 = row) ----
ECELL:  JSR PC, CELLADR
        MOV #24., R4
EC1:    CLRB (R2)
        CLRB 1(R2)
        CLRB 2(R2)
        ADD #100, R2
        SOB R4, EC1
        RTS PC

; ===================== sound =====================
; The speaker is one bit; the toggle rate is the pitch, Spectrum-style.
TONE:   CLR R3
TON1:   COM R3
        MOV R3, @#SPK
        MOV R0, R2
TON2:   SOB R2, TON2
        SOB R1, TON1
        CLR @#SPK
        RTS PC
SROT:   MOV #150, R0       ; rotate blip
        MOV #4, R1
        BR TONE
SLOCK:  MOV #400, R0       ; lock thud
        MOV #6, R1
        BR TONE
SLINE:  MOV #100, R0       ; line-clear zap
        MOV #30., R1
        BR TONE

; ===================== display =====================
; ---- SHOWSC: six score digits, most significant first ----
SHOWSC: MOV #SCORE+5, R3
        MOV #SCBASE, R1
        MOV #6, R4
SS1:    MOVB (R3), R0
        MOV R3, -(SP)
        MOV R1, -(SP)
        MOV R4, -(SP)
        JSR PC, DRWDIG
        MOV (SP)+, R4
        MOV (SP)+, R1
        MOV (SP)+, R3
        INC R1
        DEC R3
        DEC R4
        BNE SS1
        RTS PC

; ---- SHOWLN: three line-count digits ----
SHOWLN: MOV #LINES+2, R3
        MOV #LNBASE, R1
        MOV #3, R4
SL1:    MOVB (R3), R0
        MOV R3, -(SP)
        MOV R1, -(SP)
        MOV R4, -(SP)
        JSR PC, DRWDIG
        MOV (SP)+, R4
        MOV (SP)+, R1
        MOV (SP)+, R3
        INC R1
        DEC R3
        DEC R4
        BNE SL1
        RTS PC

; ---- SHOWLV: the single level digit ----
SHOWLV: MOV LEVEL, R0
        MOV #LVBASE, R1
        JSR PC, DRWDIG
        RTS PC

; ---- DRWDIG: digit R0 (0..9) at byte address R1 ----
DRWDIG: ASL R0
        ASL R0
        ASL R0             ; glyphs are 8. bytes apart
        ADD #FONT, R0
        MOV #7, R2
DG1:    MOVB (R0)+, (R1)
        ADD #100, R1
        SOB R2, DG1
        RTS PC

; ===================== setup =====================
; ---- BORDER: the walls around the well ----
BORDER: MOV #61600, R0     ; first wall row, y = 14.
        MOV #484., R1
BV1:    BISB #300, 20(R0)  ; left wall  (x = 134..135)
        BISB #3, 57(R0)    ; right wall (x = 376..377)
        ADD #100, R0
        SOB R1, BV1
        MOV #61600, R0     ; top cap, y = 14.
        JSR PC, HBAR
        MOV #61700, R0
        JSR PC, HBAR
        MOV #156000, R0    ; bottom cap, y = 496.
        JSR PC, HBAR
        MOV #156100, R0
        JSR PC, HBAR
        RTS PC
; ---- HBAR: fill the interior width (30. bytes) across row R0; the
;      wall pixels at either end are already set by the BV1 loop ----
HBAR:   MOV R0, R2
        ADD #21, R2
        MOV #30., R3
HB1:    MOVB #377, (R2)+
        SOB R3, HB1
        RTS PC

; ---- INITBD: empty the board ----
INITBD: MOV #BOARD, R0
        MOV #20., R1
CB1:    CLR (R0)+
        SOB R1, CB1
        RTS PC

; ---- MKROWA: the per-row framebuffer addresses (top-left of each
;      board row). Row 0 at 062021, each row 24. lines (03000) below. ----
MKROWA: MOV #ROWA, R0
        MOV #62021, R1
        MOV #20., R2
MR1:    MOV R1, (R0)+
        ADD #3000, R1
        SOB R2, MR1
        RTS PC

; ===================== data =====================
CURP:   .WORD 0            ; current piece 0..6
CURR:   .WORD 0            ; current rotation 0..3
CURX:   .WORD 0            ; piece origin column (signed)
CURY:   .WORD 0            ; piece origin row
TX:     .WORD 0            ; candidate position for CHKPOS/TRYSET
TY:     .WORD 0
TR:     .WORD 0
PCNT:   .WORD 0            ; cell loop counter
GTIMER: .WORD 0            ; frames since the last gravity step
LEVEL:  .WORD 0
NLINES: .WORD 0            ; lines cleared by the last lock
RDROW:  .WORD 0
RDCOL:  .WORD 0
DASDIR: .WORD 0            ; -1 / 0 / +1: held horizontal direction
DASCNT: .WORD 0
PREVF:  .WORD 0            ; fire button last frame (rotate edge)
PREVD:  .WORD 0            ; down button last frame (hard-drop edge)
JOYS:   .WORD 0            ; joystick snapshot for this frame
SEED:   .WORD 52525        ; LFSR state (nonzero)
FCNT:   .WORD 0
SCORE:  .BYTE 0,0,0,0,0,0  ; six decimal digits, units first
LINES:  .BYTE 0,0,0        ; three decimal digits, units first
        .EVEN

; column bit masks, cols 0..9
BITMSK: .WORD 1, 2, 4, 10, 20, 40, 100, 200, 400, 1000

; frames per cell drop, by level 0..9
GRAVT:  .WORD 48., 43., 38., 33., 28., 23., 18., 13., 8., 6.

; score bonus per number of lines (BCD, units first): 40/100/300/1200
SCOREINC:.BYTE 0,4,0,0,0,0
        .BYTE 0,0,1,0,0,0
        .BYTE 0,0,3,0,0,0
        .BYTE 0,0,2,1,0,0
        .EVEN

; one cell, 24 rows x 3 bytes: filled, right/bottom grid gap, and a 3px
; hole punched dead centre. Per row: byte0 cols 0-7, byte1 8-15, byte2
; 16-23; col 23 stays dark for the grid, the hole clears cols 10-12.
CELLP:  .BYTE 377,377,177, 377,377,177, 377,377,177, 377,377,177, 377,377,177
        .BYTE 377,377,177, 377,377,177, 377,377,177, 377,377,177, 377,377,177
        .BYTE 377,343,177, 377,343,177, 377,343,177
        .BYTE 377,377,177, 377,377,177, 377,377,177, 377,377,177, 377,377,177
        .BYTE 377,377,177, 377,377,177, 377,377,177, 377,377,177, 377,377,177
        .BYTE 0,0,0
        .EVEN

; seven pieces x four rotations x four cells; byte = (dy<<2 | dx)
PIECES: .BYTE 4, 5, 6, 7         ; I
        .BYTE 2, 6, 12, 16
        .BYTE 10, 11, 12, 13
        .BYTE 1, 5, 11, 15
        .BYTE 1, 2, 5, 6         ; O
        .BYTE 1, 2, 5, 6
        .BYTE 1, 2, 5, 6
        .BYTE 1, 2, 5, 6
        .BYTE 1, 4, 5, 6         ; T
        .BYTE 1, 5, 6, 11
        .BYTE 4, 5, 6, 11
        .BYTE 1, 4, 5, 11
        .BYTE 1, 2, 4, 5         ; S
        .BYTE 1, 5, 6, 12
        .BYTE 5, 6, 10, 11
        .BYTE 0, 4, 5, 11
        .BYTE 0, 1, 5, 6         ; Z
        .BYTE 2, 5, 6, 11
        .BYTE 4, 5, 11, 12
        .BYTE 1, 4, 5, 10
        .BYTE 0, 4, 5, 6         ; J
        .BYTE 1, 2, 5, 11
        .BYTE 4, 5, 6, 12
        .BYTE 1, 5, 10, 11
        .BYTE 2, 4, 5, 6         ; L
        .BYTE 1, 5, 11, 12
        .BYTE 4, 5, 6, 10
        .BYTE 0, 1, 5, 11
        .EVEN

; 5x7 digit font, bit 0 = leftmost pixel, 8. bytes per glyph
FONT:   .BYTE 16, 21, 21, 21, 21, 21, 16, 0     ; 0
        .BYTE 4, 6, 4, 4, 4, 4, 16, 0           ; 1
        .BYTE 16, 21, 20, 10, 4, 2, 37, 0       ; 2
        .BYTE 37, 10, 4, 10, 20, 21, 16, 0      ; 3
        .BYTE 10, 14, 12, 11, 37, 10, 10, 0     ; 4
        .BYTE 37, 1, 17, 20, 20, 21, 16, 0      ; 5
        .BYTE 16, 1, 1, 17, 21, 21, 16, 0       ; 6
        .BYTE 37, 20, 10, 4, 2, 2, 2, 0         ; 7
        .BYTE 16, 21, 21, 16, 21, 21, 16, 0     ; 8
        .BYTE 16, 21, 21, 36, 20, 21, 16, 0     ; 9
        .EVEN

ROWA:   .BLKW 20.          ; framebuffer address of each board row
BOARD:  .BLKW 20.          ; 20 rows, bit c = column c occupied

        .END START
