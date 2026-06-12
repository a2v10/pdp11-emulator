; ===================== ARKANOID for the PDP-11 =====================
;
; Screen: 512x512 @ 1 bpp, framebuffer at FB, 64. bytes per row.
; Pixel (x,y) lives at byte FB + (y * 64.) + (x / 8), bit x & 7
; (bit 0 is the leftmost pixel of a byte).
;
; Field layout:
;   header   - score digits and lives, above the top wall
;   y = 16.  - top wall; side walls at x = 0 and x = 511.
;   bricks   - 6 rows x 15 cols of 32x14 px bricks, y = 64..159.
;   paddle   - 48x4 px at y = 496.; ball - 4x4 px
;   below the paddle the ball is lost
;
; Controls: left/right arrows move, space serves the ball.

FB      = 60000
LKS     = 177546            ; KW11 line clock: the 60 Hz game timer
JOY     = 177570            ; bit 0 - left, bit 1 - right, bit 2 - fire
SPK     = 177544            ; speaker: bit 0 is the cone, toggle it for sound

        . = 100             ; clock interrupt vector
        .WORD VSYNC, 340

        . = 1000
START:  MOV #60000, SP
        JSR PC, BORDER
        JSR PC, INITBR
        JSR PC, DRWSCR
        JSR PC, DRWLIV
        MOV #100, @#LKS     ; enable clock interrupts
IDLE:   WAIT                ; the whole game runs in the frame handler
        BR IDLE

; ===================== frame handler =====================
VSYNC:  INC FCNT
        JSR PC, ERSBAL
        JSR PC, ERSPAD

        ; --- paddle: poll joystick, move, clamp to the field ---
        MOV @#JOY, R0
        BIT #1, R0
        BEQ VP1
        DEC PADB
VP1:    BIT #2, R0
        BEQ VP2
        INC PADB
VP2:    CMP PADB, #1
        BGE VP3
        MOV #1, PADB
VP3:    CMP PADB, #71       ; 57.
        BLE VP4
        MOV #71, PADB
VP4:
        ; --- fire button, edge-triggered ---
        BIT #4, R0
        BNE VF1
        CLR PREVF
        BR VF2
VF1:    TST PREVF
        BNE VF2
        MOV #1, PREVF
        TST STUCK
        BEQ VF2
        CLR STUCK           ; serve!
        JSR PC, SSERVE
        MOV #-2, BDY
        MOV #2, BDX
        BIT #1, FCNT        ; serve left or right, depending on the frame
        BEQ VF2
        MOV #-2, BDX
VF2:
        TST STUCK
        BEQ PHYS
        JSR PC, BALPAD      ; the ball rides on the paddle
        JSR PC, MUSIC       ; a serenade while we wait
        JMP DRAW            ; too far for a branch

        ; --- physics, X axis ---
PHYS:   MOV BALLX, R0
        ADD BDX, R0         ; new x
        CMP R0, #10         ; 8.
        BLT XFLIP
        CMP R0, #764        ; 500.
        BLE XBRK
XFLIP:  NEG BDX             ; wall: bounce, no move this frame
        JSR PC, SWALL
        BR XDONE
XBRK:   MOV R0, R4          ; R4 = new x (CHKBRK preserves R4)
        TST BDX
        BLT XLEAD
        ADD #3, R0          ; probe the leading edge when moving right
XLEAD:  MOV BALLY, R1
        ADD #2, R1          ; ball center y
        JSR PC, CHKBRK
        TST R0
        BEQ XMOVE
        NEG BDX             ; hit a brick from the side
        BR XDONE
XMOVE:  MOV R4, BALLX
XDONE:
        ; --- physics, Y axis ---
        MOV BALLY, R1
        ADD BDY, R1         ; new y
        CMP R1, #22         ; 18.: the top wall
        BGE YBRK
        NEG BDY
        JSR PC, SWALL
        BR YDONE
YBRK:   CMP R1, #770        ; 504.: below the paddle - ball lost
        BLE YB2
        JSR PC, LOST
        BR DRAW
YB2:    MOV R1, R4          ; R4 = new y
        MOV BALLX, R0
        ADD #2, R0          ; ball center x
        TST BDY
        BLT YLEAD
        ADD #3, R1          ; probe the leading edge when moving down
YLEAD:  JSR PC, CHKBRK
        TST R0
        BEQ YPAD
        NEG BDY             ; hit a brick
        BR YDONE
YPAD:   ; --- paddle bounce: moving down and new y in [492., 496.] ---
        TST BDY
        BLE YMOVE
        CMP R4, #754        ; 492.
        BLT YMOVE
        CMP R4, #760        ; 496.
        BGT YMOVE
        MOV PADB, R2
        ASL R2
        ASL R2
        ASL R2              ; paddle x in pixels
        MOV BALLX, R3
        ADD #4, R3
        CMP R3, R2
        BLT YMOVE           ; ball is left of the paddle
        MOV R2, R3
        ADD #57, R3         ; 47.
        CMP BALLX, R3
        BGT YMOVE           ; ball is right of the paddle
        NEG BDY             ; bounce; the hit position picks the angle
        JSR PC, SPADL       ; (preserves R2 - the paddle x is still live)
        MOV BALLX, R3
        ADD #2, R3
        SUB R2, R3          ; 0..47 across the paddle
        CMP R3, #14         ; 12.
        BGE PD1
        MOV #-2, BDX
        BR YDONE
PD1:    CMP R3, #30         ; 24.
        BGE PD2
        MOV #-1, BDX
        BR YDONE
PD2:    CMP R3, #44         ; 36.
        BGE PD3
        MOV #1, BDX
        BR YDONE
PD3:    MOV #2, BDX
        BR YDONE
YMOVE:  MOV R4, BALLY
YDONE:
        ; --- field cleared? lay the bricks again ---
        TST BRKCNT
        BNE DRAW
        JSR PC, INITBR
        MOV #1, STUCK

DRAW:   JSR PC, DRWPAD
        JSR PC, DRWBAL
        RTI

; ===================== game subroutines =====================

; ---- BALPAD: put the ball on the paddle center ----
BALPAD: MOV PADB, R0
        ASL R0
        ASL R0
        ASL R0
        ADD #26, R0         ; 22.: center minus half the ball
        MOV R0, BALLX
        MOV #752, BALLY     ; 490.
        RTS PC

; ---- LOST: a life is gone ----
LOST:   JSR PC, SLOST       ; the dying buzz (the game freezes for it,
                            ; six frames - the Spectrum did the same)
        DEC LIVES
        JSR PC, DRWLIV
        TST LIVES
        BGT LO1
        HALT                ; game over
LO1:    MOV #1, STUCK
        JSR PC, BALPAD
        RTS PC

; ---- CHKBRK: probe point (R0 = x, R1 = y). If a live brick is
;      there: kill it, erase it, add score. R0 = 1 on hit, else 0.
;      Preserves R4, R5. ----
CHKBRK: CMP R1, #100        ; above the brick band? (64.)
        BLT CBNO
        CMP R1, #237        ; below it? (159.)
        BGT CBNO
        SUB #20, R0         ; bricks start at x = 16.
        BLT CBNO
        ASR R0
        ASR R0
        ASR R0
        ASR R0
        ASR R0              ; / 32. -> column
        CMP R0, #16         ; 14.
        BGT CBNO
        SUB #100, R1
        ASR R1
        ASR R1
        ASR R1
        ASR R1              ; / 16. -> row
        MOV R1, R2          ; index = row * 15. + column
        ASL R2
        ASL R2
        ASL R2
        ASL R2
        SUB R1, R2
        ADD R0, R2
        TSTB BRICKS(R2)
        BEQ CBNO
        CLRB BRICKS(R2)
        DEC BRKCNT
        MOV R0, R2          ; swap: ERSBRK wants R0 = row, R1 = col
        MOV R1, R0
        MOV R2, R1
        JSR PC, ERSBRK
        JSR PC, ADD10
        JSR PC, SBRICK
        MOV #1, R0
        RTS PC
CBNO:   CLR R0
        RTS PC

; ===================== sound =====================
; The speaker is one bit: the program toggles the cone and the toggle
; rate is the pitch - Spectrum-style, there is no tone generator.
; One half-period costs 3*R0 + 10 cycles on our ~1 MHz machine.

; ---- TONE: square wave. R0 = delay count (pitch), R1 = number of
;      half-periods (length). Clobbers R0-R3. ----
TONE:   CLR R3
TON1:   COM R3
        MOV R3, @#SPK
        MOV R0, R2
TON2:   SOB R2, TON2
        SOB R1, TON1
        CLR @#SPK
        RTS PC

; ---- effect presets: pitch and length for TONE ----
SWALL:  MOV #243, R0        ; 1 kHz, 2 ms: the wall
        MOV #4, R1
        BR TONE
SBRICK: MOV #145, R0        ; 1.6 kHz, 3 ms: a brick dies
        MOV #12, R1
        BR TONE
SPADL:  MOV R2, -(SP)       ; the caller's R2 is live
        MOV #353, R0        ; 700 Hz, 3 ms: the paddle
        MOV #4, R1
        JSR PC, TONE
        MOV (SP)+, R2
        RTS PC
SSERVE: MOV #210, R0        ; 1.2 kHz, 5 ms: serve
        MOV #14, R1
        BR TONE
SLOST:  MOV #2124, R0       ; 150 Hz, 100 ms: the ball is gone
        MOV #36, R1
        BR TONE

; ---- MUSIC: one frame's slice of the tune, called while the ball
;      waits on the paddle. A note is (delay count, half-periods per
;      frame, frames); delay 0 is a rest, 177777 loops the tune.
;      The last two frames of a note are silent - that gap is what
;      separates repeated notes. Clobbers R0-R3, R5. ----
MUSIC:  TST MTIME
        BGT MUS1            ; the current note still sounds
        MOV MNOTE, R5       ; it ended: advance
        ADD #6, R5
        TST (R5)
        BGE MUS0
        MOV #MTUNE, R5      ; da capo
MUS0:   MOV R5, MNOTE
        MOV 4(R5), MTIME
MUS1:   DEC MTIME
        MOV MNOTE, R5
        MOV (R5), R0
        BEQ MUS9            ; a rest
        CMP MTIME, #2
        BLT MUS9            ; the gap between notes
        MOV 2(R5), R1
        JSR PC, TONE
MUS9:   RTS PC

; ---- BRKADR: R0 = row, R1 = col -> R2 = brick top-left address ----
BRKADR: MOV R0, R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2              ; row * 16.
        ADD #100, R2        ; + band top (64.)
        ASL R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2              ; * 64. -> row address
        ADD #FB+2, R2       ; field starts at byte 2
        MOV R1, R3
        ASL R3
        ASL R3              ; col * 4
        ADD R3, R2
        RTS PC

; ---- DRWBRK / ERSBRK: paint or clear one brick (R0 = row, R1 = col)
;      a brick is 30x14 px in its 32x16 cell - the gap shows the grid ----
DRWBRK: JSR PC, BRKADR
        MOV #16, R3         ; 14. rows
DB1:    MOVB #377, (R2)+
        MOVB #377, (R2)+
        MOVB #377, (R2)+
        MOVB #77, (R2)      ; rightmost 2 px stay dark
        ADD #75, R2         ; 61.: to the next row
        SOB R3, DB1
        RTS PC

ERSBRK: JSR PC, BRKADR
        MOV #16, R3
EB1:    CLRB (R2)+
        CLRB (R2)+
        CLRB (R2)+
        CLRB (R2)
        ADD #75, R2
        SOB R3, EB1
        RTS PC

; ---- INITBR: all 90. bricks alive and painted ----
INITBR: MOV #BRICKS, R0
        MOV #132, R1        ; 90.
IB1:    MOVB #1, (R0)+
        SOB R1, IB1
        MOV #132, BRKCNT
        CLR R4              ; row
IB2:    CLR R5              ; column
IB3:    MOV R4, R0
        MOV R5, R1
        JSR PC, DRWBRK
        INC R5
        CMP R5, #17         ; 15.
        BLT IB3
        INC R4
        CMP R4, #6
        BLT IB2
        RTS PC

; ---- BALMSK: ball address and pixel masks from BALLX/BALLY ----
;      R2 = byte address, R4/R5 = masks for the two bytes the
;      4-pixel run may straddle
BALMSK: MOV BALLY, R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2
        ASL R2              ; y * 64.
        ADD #FB, R2
        MOV BALLX, R3
        ASR R3
        ASR R3
        ASR R3
        ADD R3, R2
        MOV BALLX, R3
        BIC #177770, R3     ; x & 7
        MOVB MASKL(R3), R4
        MOVB MASKR(R3), R5
        RTS PC

DRWBAL: JSR PC, BALMSK
        MOV #4, R3
DBL1:   BISB R4, (R2)
        BISB R5, 1(R2)
        ADD #100, R2
        SOB R3, DBL1
        RTS PC

ERSBAL: JSR PC, BALMSK
        MOV #4, R3
EBL1:   BICB R4, (R2)
        BICB R5, 1(R2)
        ADD #100, R2
        SOB R3, EBL1
        RTS PC

; ---- DRWPAD / ERSPAD: the 48x4 px paddle at y = 496. ----
DRWPAD: MOV #377, R0
        BR PADGO
ERSPAD: CLR R0
PADGO:  MOV PADB, R1
        ADD #FB+76000, R1   ; 496. * 64.
        MOV #4, R3
PAD1:   MOV R1, R2
        MOVB R0, (R2)+
        MOVB R0, (R2)+
        MOVB R0, (R2)+
        MOVB R0, (R2)+
        MOVB R0, (R2)+
        MOVB R0, (R2)
        ADD #100, R1
        SOB R3, PAD1
        RTS PC

; ---- ADD10: score += 10, repaint the digits ----
ADD10:  INCB SCORE+2
        CMPB SCORE+2, #12   ; 10.
        BLT AS9
        CLRB SCORE+2
        INCB SCORE+1
        CMPB SCORE+1, #12
        BLT AS9
        CLRB SCORE+1
        INCB SCORE
AS9:    JSR PC, DRWSCR
        RTS PC

; ---- DRWSCR: four score digits in the header. Preserves R4, R5 ----
DRWSCR: MOV R4, -(SP)
        MOV R5, -(SP)
        MOV #SCORE, R3
        MOV #FB+402, R4     ; y = 4, byte 2
        MOV #4, R5
DS1:    MOVB (R3)+, R0
        MOV R4, R1
        MOV R3, -(SP)
        JSR PC, DRWDIG
        MOV (SP)+, R3
        INC R4
        SOB R5, DS1
        MOV (SP)+, R5
        MOV (SP)+, R4
        RTS PC

; ---- DRWDIG: digit R0 (0..9) at byte address R1 ----
DRWDIG: ASL R0
        ASL R0
        ASL R0              ; glyphs are 8 bytes apart
        ADD #FONT, R0
        MOV #7, R2
DG1:    MOVB (R0)+, (R1)
        ADD #100, R1
        SOB R2, DG1
        RTS PC

; ---- DRWLIV: one block per remaining life, top right. Preserves R4, R5 ----
DRWLIV: MOV R4, -(SP)
        MOV R5, -(SP)
        MOV #FB+471, R4     ; y = 4, byte 57.
        MOV #1, R5          ; life number 1..3
DL1:    MOV R4, R1
        MOV #7, R2
        CMP R5, LIVES
        BGT DLERA
DL2:    MOVB #77, (R1)
        ADD #100, R1
        SOB R2, DL2
        BR DLNXT
DLERA:  CLRB (R1)
        ADD #100, R1
        SOB R2, DLERA
DLNXT:  ADD #2, R4
        INC R5
        CMP R5, #3
        BLE DL1
        MOV (SP)+, R5
        MOV (SP)+, R4
        RTS PC

; ---- BORDER: the top wall at y = 16. and the side walls ----
BORDER: MOV #FB+2000, R0    ; 16. * 64.
        MOV #100, R1
BD1:    MOVB #377, (R0)+
        SOB R1, BD1
        MOV #FB, R0
        MOV #1000, R1       ; 512. rows
BD2:    BISB #1, (R0)       ; left edge
        BISB #200, 77(R0)   ; right edge (byte 63.)
        ADD #100, R0
        SOB R1, BD2
        RTS PC

; ===================== data =====================

BALLX:  .WORD 260           ; 176.
BALLY:  .WORD 752           ; 490.
BDX:    .WORD 2
BDY:    .WORD -2
PADB:   .WORD 35            ; 29.: paddle byte column
STUCK:  .WORD 1             ; ball waits on the paddle
LIVES:  .WORD 3
BRKCNT: .WORD 132           ; 90.
PREVF:  .WORD 0
FCNT:   .WORD 0
MNOTE:  .WORD MTUNE         ; the note now playing
MTIME:  .WORD 24            ; frames it has left (the first note's length)
SCORE:  .BYTE 0, 0, 0, 0    ; four decimal digits

; masks of a 4-pixel run at offset x&7 inside a byte pair
MASKL:  .BYTE 17, 36, 74, 170, 360, 340, 300, 200
MASKR:  .BYTE 0, 0, 0, 0, 0, 1, 3, 7

; Korobeiniki - what else do you play on a PDP-11? Tetris was written
; on an Elektronika-60, a Soviet PDP-11 clone. A note is (delay count,
; half-periods per frame, frames): quarter = 24, eighth = 12 frames.
MTUNE:  .WORD 372, 17, 24   ; E5
        .WORD 516, 13, 12   ; B4
        .WORD 473, 14, 12   ; C5
        .WORD 431, 16, 24   ; D5
        .WORD 473, 14, 12   ; C5
        .WORD 516, 13, 12   ; B4
        .WORD 567, 12, 24   ; A4
        .WORD 567, 12, 12   ; A4
        .WORD 473, 14, 12   ; C5
        .WORD 372, 17, 24   ; E5
        .WORD 431, 16, 12   ; D5
        .WORD 473, 14, 12   ; C5
        .WORD 516, 13, 36   ; B4, dotted
        .WORD 473, 14, 12   ; C5
        .WORD 431, 16, 24   ; D5
        .WORD 372, 17, 24   ; E5
        .WORD 473, 14, 24   ; C5
        .WORD 567, 12, 24   ; A4
        .WORD 567, 12, 24   ; A4
        .WORD 0, 0, 36      ; a breath before da capo
        .WORD 177777        ; end of tune

; 5x7 digit font, bit 0 = leftmost pixel, 8 bytes per glyph
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
BRICKS: .BLKB 132           ; 90. brick flags

        .END START
