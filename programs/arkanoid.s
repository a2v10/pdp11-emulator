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
SPK     = 177544            ; speaker: bit 0 is the cone
PCSR    = 172540            ; KW11-P clock: rate select bits 0-1, IE bit 6
PCSB    = 172542            ; KW11-P count-set buffer: the half-period

; Sound rides the KW11-P programmable clock: its external input is wired
; to a 125 kHz crystal, the preset is a note's half-period in crystal
; ticks, and every interrupt through vector 104 flips the speaker cone.
; Nothing busy-waits on the speaker any more, so a note goes on sounding
; while the game runs - which is why the frame handler drops to
; priority 4: the metronome has to be able to cut in.
; Note table: preset = 125000 / (2 * freq); A4 = 142. -> 440.1 Hz.
NA4     = 142.
NB4     = 127.
NC5     = 119.
ND5     = 106.
NE5     = 95.
NG5     = 80.
NA5     = 71.
NB5     = 63.
NC6     = 60.
ND6     = 53.
NE6     = 47.
NG6     = 40.
NA6     = 36.

        . = 100             ; line clock: the frame handler
        .WORD VSYNC, 200    ; priority 4 - the music clock outranks it
        . = 104             ; KW11-P: half a period per interrupt
        .WORD PTICK, 340

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
; At priority 4 a slow frame (laying the bricks again) can be caught by
; the next tick - the latch makes the late tick simply drop out.
VSYNC:  TST INVS
        BEQ VSGO
        RTI
VSGO:   MOV #1, INVS
        INC FCNT
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
        ; --- fire button (or up), edge-triggered ---
        BIT #24, R0
        BNE VF1
        CLR PREVF
        BR VF2
VF1:    TST PREVF
        BNE VF2
        MOV #1, PREVF
        TST STUCK
        BEQ VF2
        CLR STUCK           ; serve!
        JSR PC, MUSOFF      ; the serenade is over
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
        JSR PC, MUSGO       ; a serenade while we wait
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
        JSR PC, SPADL       ; (only R0 dies - the paddle x in R2 is live)
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
        JSR PC, SNDFRM
        TST OVER            ; game over: let the buzz play itself out
        BEQ DRW9
        DEC OVER
        BNE DRW9
        CLR @#PCSR          ; the machine goes quiet, then stops
        CLR @#SPK
        HALT
DRW9:   CLR INVS
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
LOST:   DEC LIVES
        JSR PC, DRWLIV
        MOV #1, STUCK
        TST LIVES
        BLE LO2
        JSR PC, SLOST       ; the dying buzz - the clock plays it in the
        JSR PC, BALPAD      ; background now, the game no longer freezes
        RTS PC
LO2:    JSR PC, SOVER       ; last life: the descent, and then silence
        MOV #44., OVER      ; exactly as long as the script
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
; Nothing here toggles the cone by hand: the KW11-P does it, half a
; period per interrupt, so a note keeps sounding across frame borders
; and the game never has to stand still for a beep.
;
; A script is a list of (preset, frames) pairs, preset 0 is a rest and
; 177777 ends it. Two scripts run at once - an effect and the tune. The
; effect owns the speaker while it lasts; the tune counts on underneath,
; so it comes back on the beat instead of restarting.

; the metronome itself: half a period per interrupt, no registers
PTICK:  COM SPKSH
        MOV SPKSH, @#SPK
        RTI

; ---- SFXSET: R0 -> an effect script; it takes the speaker at once ----
SFXSET: MOV R0, SFXP
        CLR SFXF
        RTS PC

; ---- effects: each is a script, so they cost the frame nothing ----
SWALL:  MOV #SNWALL, R0
        BR SFXSET
SBRICK: MOV #SNBRIK, R0
        BR SFXSET
SPADL:  MOV #SNPADL, R0
        BR SFXSET
SSERVE: MOV #SNSERV, R0
        BR SFXSET
SLOST:  MOV #SNLOST, R0
        BR SFXSET
SOVER:  MOV #SNOVER, R0
        BR SFXSET

; ---- MUSGO / MUSOFF: the tune plays only while the ball waits, and it
;      always starts from the top - but never on top of an effect ----
MUSGO:  TST SFXP
        BNE MGO9            ; let the dying buzz finish first
        TST MUSP
        BNE MGO9
        MOV #MTUNE, MUSP
        CLR MUSF
MGO9:   RTS PC
MUSOFF: CLR MUSP
        RTS PC

; ---- SNDSTP: one frame of the script whose (pointer, timer) pair sits
;      at R5; R1 = where to restart when it ends (0 = just stop).
;      Returns R0 = the note to sound this frame. Clobbers R0-R2. ----
SNDSTP: MOV (R5), R2        ; R2 -> the current (preset, frames) pair
        BNE SST1
        CLR R0              ; no script running
        RTS PC
SST1:   TST 2(R5)
        BNE SST2
        MOV 2(R2), 2(R5)    ; a fresh note: latch its length
SST2:   MOV (R2), R0
        DEC 2(R5)
        BNE SST9
        CLR R0              ; a note's last frame is silent: that gap is
                            ; what separates two equal notes in a row
        ADD #4, R2          ; and the script steps on
        MOV R2, (R5)
        CMP (R2), #177777
        BNE SST9
        MOV R1, (R5)        ; the end: da capo, or stop
SST9:   RTS PC

; ---- SNDFRM: one frame of sound, effect over tune ----
SNDFRM: MOV #MUSP, R5
        MOV #MTUNE, R1
        JSR PC, SNDSTP      ; the tune keeps time even while muted
        MOV R0, R3
        MOV #SFXP, R5
        CLR R1
        JSR PC, SNDSTP
        TST R0
        BNE SFR9            ; an effect: it wins the speaker
        MOV R3, R0
SFR9:   ; fall through to PLAY

; ---- PLAY: sound note R0 (a half-period preset), 0 for silence.
;      Writing the buffer mid-note only changes the next reload, so a
;      pitch change never resets the phase - no clicks, no 60 Hz hum. ----
PLAY:   CMP R0, CURNT
        BEQ PLY9
        MOV R0, CURNT
        BNE PLY1
        CLR @#PCSR          ; stop the clock
        CLR SPKSH
        CLR @#SPK
        RTS PC
PLY1:   MOV R0, @#PCSB
        MOV #103, @#PCSR    ; IE + the 125 kHz crystal
PLY9:   RTS PC

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
SFXP:   .WORD 0             ; the effect script now running
SFXF:   .WORD 0             ; frames left in its note (must follow SFXP)
MUSP:   .WORD 0             ; the tune, or 0 while it is off
MUSF:   .WORD 0             ; (must follow MUSP)
CURNT:  .WORD 0             ; the note sounding right now
SPKSH:  .WORD 0             ; the metronome's speaker shadow
INVS:   .WORD 0             ; frame handler re-entry latch
OVER:   .WORD 0             ; frames left before the machine stops
SCORE:  .BYTE 0, 0, 0, 0    ; four decimal digits

; masks of a 4-pixel run at offset x&7 inside a byte pair
MASKL:  .BYTE 17, 36, 74, 170, 360, 340, 300, 200
MASKR:  .BYTE 0, 0, 0, 0, 0, 1, 3, 7

; ---- effect scripts: (preset, frames), 177777 ends one ----
SNWALL: .WORD 62., 3.       ; 1 kHz: the wall
        .WORD 177777
SNBRIK: .WORD 39., 3.       ; 1.6 kHz: a brick dies
        .WORD 177777
SNPADL: .WORD 89., 3.       ; 700 Hz: the paddle
        .WORD 177777
SNSERV: .WORD 52., 5.       ; 1.2 kHz: serve
        .WORD 177777
SNLOST: .WORD 417., 24.     ; 150 Hz: the ball is gone
        .WORD 177777
SNOVER: .WORD 417., 8.      ; and on the last life it keeps falling:
        .WORD 496., 8.      ; 150, 126, 100, 75 Hz - 44. frames, which
        .WORD 625., 12.     ; is what OVER counts down before the HALT
        .WORD 833., 16.
        .WORD 177777

; In the Hall of the Mountain King (Grieg, 1875 - the same year this
; machine would have been new). The trolls come round twice: first at
; an eighth = 12 frames, then an octave up and half again as fast, and
; then from the top - the ball has been sitting on that paddle long
; enough. A note is (preset, frames); the last frame of each is the
; release, which is what tells two equal notes apart.
MTUNE:  .WORD NA4, 12.
        .WORD NB4, 12.
        .WORD NC5, 12.
        .WORD ND5, 12.
        .WORD NE5, 12.
        .WORD NC5, 12.
        .WORD NE5, 24.
        .WORD ND5, 12.
        .WORD NB4, 12.
        .WORD ND5, 12.
        .WORD NC5, 12.
        .WORD NA4, 12.
        .WORD NC5, 36.
        .WORD NA4, 12.
        .WORD NB4, 12.
        .WORD NC5, 12.
        .WORD ND5, 12.
        .WORD NE5, 12.
        .WORD NC5, 12.
        .WORD NE5, 24.
        .WORD NA5, 12.
        .WORD NG5, 12.
        .WORD NE5, 12.
        .WORD NC5, 12.
        .WORD ND5, 12.
        .WORD NE5, 36.
        .WORD NA5, 8.       ; da capo, an octave up and quicker
        .WORD NB5, 8.
        .WORD NC6, 8.
        .WORD ND6, 8.
        .WORD NE6, 8.
        .WORD NC6, 8.
        .WORD NE6, 16.
        .WORD ND6, 8.
        .WORD NB5, 8.
        .WORD ND6, 8.
        .WORD NC6, 8.
        .WORD NA5, 8.
        .WORD NC6, 24.
        .WORD NA5, 8.
        .WORD NB5, 8.
        .WORD NC6, 8.
        .WORD ND6, 8.
        .WORD NE6, 8.
        .WORD NC6, 8.
        .WORD NE6, 16.
        .WORD NA6, 8.
        .WORD NG6, 8.
        .WORD NE6, 8.
        .WORD NC6, 8.
        .WORD ND6, 8.
        .WORD NE6, 24.
        .WORD 0, 24.        ; a breath, and the trolls start over
        .WORD 177777

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
