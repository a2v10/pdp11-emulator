; ===================== PAC-MAN for the PDP-11 =====================
;
; Screen: 512x512 @ 1 bpp, framebuffer at FB, 64. bytes per row,
; bit 0 is the leftmost pixel of a byte.
;
; The field is 28x31 tiles of 16x16 px (448x496), centered with 32 px
; side margins under a 16 px score strip. A tile is exactly 2 bytes of
; a framebuffer row, so walls and dots need no bit shifting at all.
; The maze itself is ASCII art near the end of this file; the loader
; parses it into a tile map ('#' wall, '.' dot, 'o' energizer, '-' door)
; and traces wall edges that face a corridor - boot-time auto-tiling.
;
; Sprites are 16x16 images (a 14x14 body with a 1 px margin), stored
; pre-shifted for the 4 even bit phases: everything moves 2 px/frame,
; so x is always even and a sprite needs only 3 bytes per row.
;
; Ghost brains are the arcade original's: at a tile center a ghost picks
; the direction minimizing the squared distance to its target tile and
; may not reverse. There is no multiply - SQT is a table of squares.
; Personalities are just different targets: Blinky chases the mouth,
; Pinky aims 4 tiles ahead (with the genuine 1980 overflow bug: when
; the mouth looks up, the target also slides 4 tiles left), Inky doubles
; the vector from Blinky to a point 2 ahead, Clyde hunts only from afar.
;
; Controls: arrows steer, space starts / pauses.

FB      = 60000
LKS     = 177546            ; KW11 line clock: the 60 Hz heartbeat
JOY     = 177570            ; bit 0 left, 1 right, 2 fire, 3 down, 4 up
SPK     = 177544            ; speaker: bit 0 is the cone
PCSR    = 172540            ; KW11-P clock: rate select bits 0-1, IE bit 6
PCSB    = 172542            ; KW11-P count-set buffer: the half-period

; Sound rides the KW11-P programmable clock: its external input is wired
; to a 125 kHz crystal, the preset is a note's half-period in crystal
; ticks, and every interrupt through vector 104 flips the speaker cone.
; The tone never stops at a frame boundary - which is why the frame
; handler runs at priority 4: the metronome must be able to cut in.
; Note table: preset = 125000 / (2 * freq); A4 = 142. -> 440.1 Hz.
NA3     = 284.
NA4     = 142.
NB4     = 127.
NC5     = 119.
NCS5    = 113.
ND5     = 106.
NE5     = 95.
NF5     = 89.
NG5     = 80.
NA5     = 71.

        . = 100             ; line clock: the frame handler
        .WORD VSYNC, 200    ; priority 4 - the music clock outranks it
        . = 104             ; KW11-P: half a period per interrupt
        .WORD PTICK, 340

        . = 1000
START:  MOV #60000, SP
        JSR PC, CLRFB
        JSR PC, SQINIT
        JSR PC, MAPINI
        JSR PC, DRWMAZ
        JSR PC, DRWDTS
        JSR PC, DRWSCR
        JSR PC, DRWLIV
        JSR PC, RESETA
        JSR PC, DRWACT
        MOV #100, @#LKS     ; enable clock interrupts
IDLE:   WAIT                ; the whole game runs in the frame handler
        BR IDLE

; ===================== frame handler =====================
; states: 0 attract, 1 ready pause, 2 playing, 3 dying, 4 board clear,
;         6 paused
VSYNC:  MOV R0, -(SP)
        MOV R1, -(SP)
        MOV R2, -(SP)
        MOV R3, -(SP)
        MOV R4, -(SP)
        MOV R5, -(SP)
        ; at priority 4 a slow frame (the board rebuild) can be caught
        ; by the next tick - the latch makes the late tick just drop
        TST INVS
        BEQ VSGO
        JMP VSOUT
VSGO:   MOV #1, INVS
        INC FCNT
        ; --- fire: start or pause, edge-triggered ---
        MOV @#JOY, R0
        BIT #4, R0
        BNE VF1
        CLR PREVF
        BR VF9
VF1:    TST PREVF
        BNE VF9
        MOV #1, PREVF
        MOV STATE, R1
        BNE VF2
        MOV #1, STATE       ; attract -> ready
        MOV #74, GENCNT     ; 60. frames
        BR VF9
VF2:    CMP R1, #2
        BNE VF3
        MOV #6, STATE       ; pause
        BR VF9
VF3:    CMP R1, #6
        BNE VF9
        MOV #2, STATE       ; unpause
VF9:    ; --- state dispatch ---
        MOV STATE, R1
        CMP R1, #2
        BNE VS1
        JSR PC, STPLAY
        BR VS9
VS1:    CMP R1, #1
        BNE VS2
        DEC GENCNT
        BGT VS9
        MOV #2, STATE
        BR VS9
VS2:    CMP R1, #3
        BNE VS3
        JSR PC, STDIE
        BR VS9
VS3:    CMP R1, #4
        BNE VS9
        JSR PC, STLVL
VS9:    ; any state that is not playing or dying keeps quiet
        MOV STATE, R1
        CMP R1, #2
        BEQ VS10
        CMP R1, #3
        BEQ VS10
        CLR R0
        JSR PC, PLAY
VS10:   CLR INVS
VSOUT:  MOV (SP)+, R5
        MOV (SP)+, R4
        MOV (SP)+, R3
        MOV (SP)+, R2
        MOV (SP)+, R1
        MOV (SP)+, R0
        RTI

; ===================== one frame of play =====================
STPLAY: ; cache pac's tile (clamped in the tunnel) for the hunters
        MOV PACX, R0
        BGE SPP1
        CLR R0
SPP1:   CMP R0, #660        ; 432.
        BLE SPP2
        MOV #660, R0
SPP2:   ASR R0
        ASR R0
        ASR R0
        ASR R0
        MOV R0, PTX
        MOV PACY, R0
        ASR R0
        ASR R0
        ASR R0
        ASR R0
        MOV R0, PTY
        MOV GX, R0          ; blinky's tile, for Inky's geometry
        BGE SPP3
        CLR R0
SPP3:   CMP R0, #660
        BLE SPP4
        MOV #660, R0
SPP4:   ASR R0
        ASR R0
        ASR R0
        ASR R0
        MOV R0, BLKTX
        MOV GY, R0
        ASR R0
        ASR R0
        ASR R0
        ASR R0
        MOV R0, BLKTY
        ; erase, think, move, settle, draw
        JSR PC, ERSPAC
        JSR PC, ERSGH
        JSR PC, PACMV
        JSR PC, GHOSTS
        JSR PC, MODEUP
        JSR PC, COLLS
        JSR PC, DRWPAC
        JSR PC, DRWGH
        JSR PC, ENEBLK
        ; the running script, or the blue warble, or silence
        JSR PC, SNDCUR
        TST R0
        BNE SPL1
        TST FRTCNT
        BEQ SPL1
        MOV #NA4, R0        ; two notes swapped every other frame:
        BIT #2, FCNT        ; a 15 Hz wub-wub texture, not a tune
        BEQ SPL1
        MOV #ND5, R0
SPL1:   JMP PLAY

; ===================== pac =====================
; joystick -> wanted direction (0 up, 1 left, 2 down, 3 right);
; no key keeps the previous wish - the classic buffered turn
PACIN:  MOV @#JOY, R0
        BIT #20, R0
        BEQ PIN1
        CLR R1
        BR PIN5
PIN1:   BIT #1, R0
        BEQ PIN2
        MOV #1, R1
        BR PIN5
PIN2:   BIT #10, R0
        BEQ PIN3
        MOV #2, R1
        BR PIN5
PIN3:   BIT #2, R0
        BEQ PIN9
        MOV #3, R1
PIN5:   MOV R1, PACWNT
PIN9:   RTS PC

PACMV:  JSR PC, PACIN
        ; an about-face is allowed anywhere, not only on a tile center
        TST PACMOQ
        BEQ PMV1
        MOV PACDIR, R2
        ADD #2, R2
        BIC #177774, R2
        CMP R2, PACWNT
        BNE PMV1
        MOV PACWNT, PACDIR
PMV1:   ; on a tile center inside the maze: eat, then steer
        MOV PACX, R0
        BLT PMV5            ; tunnel margin: just keep rolling
        CMP R0, #660
        BGT PMV5
        BIT #17, R0
        BNE PMV5
        BIT #17, PACY
        BNE PMV5
        MOV R0, CTX
        ASR CTX
        ASR CTX
        ASR CTX
        ASR CTX
        MOV PACY, CTY
        ASR CTY
        ASR CTY
        ASR CTY
        ASR CTY
        JSR PC, EATCK
        MOV PACWNT, R4      ; first wish: the buffered turn
        JSR PC, STEPTL
        JSR PC, PASSQ
        TST R2
        BEQ PMV2
        MOV PACWNT, PACDIR
        MOV #1, PACMOQ
        BR PMV5
PMV2:   MOV PACDIR, R4      ; else straight on, if the maze allows
        JSR PC, STEPTL
        JSR PC, PASSQ
        TST R2
        BNE PMV5
        CLR PACMOQ          ; a wall: stop and close the mouth
PMV5:   TST PACMOQ
        BEQ PMV9
        MOV PACDIR, R2
        ASL R2
        ADD DXT(R2), PACX
        ADD DYT(R2), PACY
        MOV PACX, R0
        JSR PC, WRAPX
        MOV R0, PACX
        INC PACANM
PMV9:   RTS PC

; eat whatever lies on tile (CTX, CTY); the pixels die with pac's own
; erase mask - a dot is entirely inside his 14x14 body
EATCK:  MOV CTX, R0
        MOV CTY, R1
        JSR PC, TILEAD
        MOVB (R3), R2
        CMPB R2, #2
        BNE EC2
        CLRB (R3)
        DEC DOTCNT
        MOV #1, R0
        JSR PC, ADDSC
        COM WAKAF           ; waka, then wakka
        TST WAKAF
        BEQ EC1
        MOV #WAKAA, R0
        BR EC1A
EC1:    MOV #WAKAB, R0
EC1A:   JSR PC, SNDIF
        BR EC8
EC2:    CMPB R2, #3
        BNE EC9
        CLRB (R3)
        DEC DOTCNT
        MOV #5, R0
        JSR PC, ADDSC
        JSR PC, FRTON
EC8:    TST DOTCNT
        BNE EC9
        MOV #4, STATE       ; board cleared
        MOV #170, GENCNT    ; 120. frames of quiet triumph
EC9:    RTS PC

; the energizer hits: hunters turn blue, turn around, and slow down
FRTON:  MOV FRTDUR, FRTCNT
        CLR EATIX
        CLR R2
FO1:    MOV R2, R3
        ASL R3
        CMP GST(R3), #2
        BEQ FO2
        CMP GST(R3), #3
        BNE FO3
FO2:    MOV #3, GST(R3)
        MOV #1, GREV(R3)
FO3:    INC R2
        CMP R2, #4
        BLT FO1
        RTS PC

; ===================== ghosts =====================
; per-ghost state: 0 in the house, 1 leaving, 2 hunting, 3 frightened,
; 4 eyes going home, 5 sinking back in
GHOSTS: CLR GIX
GH1:    JSR PC, GONE
        INC GIX
        CMP GIX, #4
        BLT GH1
        RTS PC

; move one ghost, applying the speed rules
GONE:   MOV GIX, R5
        ASL R5
        MOV GST(R5), R0
        BNE GO1
        DEC GREL(R5)        ; bunk time
        BGE GO9
        MOV #1, GST(R5)
        BR GO9
GO1:    CMP R0, #4
        BNE GO2
        JSR PC, GSTEP       ; eyes fly home at double speed
        BR GO8
GO2:    CMP R0, #3
        BNE GO3
        BIT #1, FCNT        ; frightened: half speed
        BEQ GO9
        BR GO8
GO3:    CMP R0, #2
        BNE GO8             ; leaving/entering are scripted, full speed
        ; hunters drag their feet one frame in 32, staggered per ghost
        MOV GIX, R1
        ASL R1
        ASL R1
        ASL R1
        ADD FCNT, R1
        BIC #177740, R1
        BEQ GO9
        ; and go half speed through the tunnel
        CMP GY(R5), #340    ; 224.: the tunnel row
        BNE GO8
        MOV GX(R5), R1
        CMP R1, #100        ; 64.
        BLT GO4
        CMP R1, #560        ; 368.
        BLE GO8
GO4:    BIT #1, FCNT
        BEQ GO9
GO8:    JSR PC, GSTEP
GO9:    RTS PC

; one 2 px step for ghost GIX
GSTEP:  MOV GIX, R5
        ASL R5
        MOV GST(R5), R0
        CMP R0, #1
        BEQ GLEAV
        CMP R0, #5
        BEQ GENTR
        MOV GX(R5), R0
        BLT GSMOV           ; tunnel margin: straight on
        CMP R0, #660
        BGT GSMOV
        BIT #17, R0
        BNE GSMOV
        BIT #17, GY(R5)
        BNE GSMOV
        ; on a tile center: current tile coordinates
        MOV R0, CTX
        ASR CTX
        ASR CTX
        ASR CTX
        ASR CTX
        MOV GY(R5), CTY
        ASR CTY
        ASR CTY
        ASR CTY
        ASR CTY
        ; eyes on the doorstep sink into the house
        CMP GST(R5), #4
        BNE GS1
        CMP CTX, #15        ; (13., 11.)
        BNE GS1
        CMP CTY, #13
        BNE GS1
        MOV #5, GST(R5)
        RTS PC
GS1:    TST GREV(R5)        ; a mode change turned everyone around
        BEQ GS2
        CLR GREV(R5)
        MOV GDIR(R5), R2
        ADD #2, R2
        BIC #177774, R2
        MOV R2, GDIR(R5)
        BR GSMOV
GS2:    CMP GST(R5), #3
        BNE GS3
        JSR PC, GRND        ; blue panic is random
        BR GSMOV
GS3:    JSR PC, GAIM
GSMOV:  MOV GIX, R5
        ASL R5
        MOV GDIR(R5), R2
        ASL R2
        ADD DXT(R2), GX(R5)
        ADD DYT(R2), GY(R5)
        MOV GX(R5), R0
        JSR PC, WRAPX
        MOV R0, GX(R5)
        RTS PC

; scripted exit: sidle to the door column, rise through the door
GLEAV:  CMP GX(R5), #320    ; 208.: the door column
        BEQ GLV2
        BLT GLV1
        SUB #2, GX(R5)
        RTS PC
GLV1:   ADD #2, GX(R5)
        RTS PC
GLV2:   CMP GY(R5), #260    ; 176.: the doorstep outside
        BEQ GLV3
        SUB #2, GY(R5)
        RTS PC
GLV3:   MOV #2, GST(R5)     ; out - hunt
        MOV #1, GDIR(R5)
        RTS PC

; scripted descent after the eyes reach the doorstep
GENTR:  CMP GY(R5), #340    ; 224.: the bunk row
        BEQ GEN1
        ADD #2, GY(R5)
        RTS PC
GEN1:   MOV #1, GST(R5)     ; and straight back out
        RTS PC

; frightened: a random direction, rotated until legal (never reverse)
GRND:   JSR PC, RANDOM
        BIC #177774, R0
        MOV R0, R4
GRN1:   MOV GIX, R5
        ASL R5
        MOV GDIR(R5), R2
        ADD #2, R2
        BIC #177774, R2
        CMP R4, R2
        BEQ GRN2
        JSR PC, GTRY
        TST R2
        BNE GRN3
GRN2:   INC R4
        BIC #177774, R4
        BR GRN1
GRN3:   MOV GIX, R5
        ASL R5
        MOV R4, GDIR(R5)
        RTS PC

; the arcade rule: try each direction in up-left-down-right priority,
; keep the one whose next tile is nearest the target (never reverse)
GAIM:   JSR PC, TARGET
        MOV #77777, BSTD
        CLR BSTI
        CLR R4
GA1:    MOV GIX, R5
        ASL R5
        MOV GDIR(R5), R2
        ADD #2, R2
        BIC #177774, R2
        CMP R4, R2
        BEQ GA8
        JSR PC, GTRY
        TST R2
        BEQ GA8
        ; squared distance via the table - no multiply in 1975
        MOV TGX, R2
        SUB R0, R2
        BGE GA2
        NEG R2
GA2:    CMP R2, #77
        BLE GA3
        MOV #77, R2
GA3:    ASL R2
        MOV SQT(R2), R3
        MOV TGY, R2
        SUB R1, R2
        BGE GA4
        NEG R2
GA4:    CMP R2, #77
        BLE GA5
        MOV #77, R2
GA5:    ASL R2
        ADD SQT(R2), R3
        CMP R3, BSTD
        BGE GA8
        MOV R3, BSTD
        MOV R4, BSTI
GA8:    INC R4
        CMP R4, #4
        BLT GA1
        MOV GIX, R5
        ASL R5
        MOV BSTI, GDIR(R5)
        RTS PC

; candidate tile one step in direction R4 from (CTX, CTY) -> PASSQ
GTRY:   MOV R4, R2
        ASL R2
        MOV CTX, R0
        ADD TDX(R2), R0
        MOV CTY, R1
        ADD TDY(R2), R1
        JMP PASSQ

; the four personalities: fill TGX/TGY for ghost GIX
TARGET: MOV GIX, R5
        ASL R5
        CMP GST(R5), #4
        BNE TG1
        MOV #15, TGX        ; eyes: the doorstep (13., 11.)
        MOV #13, TGY
        RTS PC
TG1:    TST MODE            ; 0 scatter, 1 chase
        BNE TG2
        MOV SCTX(R5), TGX
        MOV SCTY(R5), TGY
        RTS PC
TG2:    MOV GIX, R0
        BEQ TGB
        CMP R0, #1
        BEQ TGP
        CMP R0, #2
        BEQ TGI
        ; --- Clyde: brave beyond 8 tiles, shy inside them ---
        MOV PTX, R2
        SUB CTX, R2
        BGE TGC1
        NEG R2
TGC1:   ASL R2
        MOV SQT(R2), R3
        MOV PTY, R2
        SUB CTY, R2
        BGE TGC2
        NEG R2
TGC2:   ASL R2
        ADD SQT(R2), R3
        CMP R3, #100        ; 64. = 8 tiles, squared
        BGT TGB
        MOV SCTX(R5), TGX
        MOV SCTY(R5), TGY
        RTS PC
TGB:    ; --- Blinky: the mouth itself ---
        MOV PTX, TGX
        MOV PTY, TGY
        RTS PC
TGP:    ; --- Pinky: 4 tiles ahead of the mouth. When pac looks up the
        ;     original's 8-bit overflow also slides the target 4 left;
        ;     reproduced here on purpose - it is history ---
        MOV PACDIR, R2
        ASL R2
        MOV TDX(R2), R0
        ASL R0
        ASL R0
        ADD PTX, R0
        MOV TDY(R2), R1
        ASL R1
        ASL R1
        ADD PTY, R1
        TST PACDIR
        BNE TGP1
        SUB #4, R0
TGP1:   MOV R0, TGX
        MOV R1, TGY
        RTS PC
TGI:    ; --- Inky: double the vector from Blinky to 2-ahead-of-pac ---
        MOV PACDIR, R2
        ASL R2
        MOV TDX(R2), R0
        ASL R0
        ADD PTX, R0
        MOV TDY(R2), R1
        ASL R1
        ADD PTY, R1
        TST PACDIR
        BNE TGI1
        SUB #2, R0          ; the same bug, half strength
TGI1:   ASL R0
        ASL R1
        SUB BLKTX, R0
        SUB BLKTY, R1
        MOV R0, TGX
        MOV R1, TGY
        RTS PC

; ===================== modes and collisions =====================
; scatter/chase waves; the wave clock freezes while the blue fear lasts
MODEUP: TST FRTCNT
        BEQ MU2
        DEC FRTCNT
        BNE MU9
        CLR R0              ; fright over: the blue ones snap back
MU1:    MOV R0, R3
        ASL R3
        CMP GST(R3), #3
        BNE MU1A
        MOV #2, GST(R3)
MU1A:   INC R0
        CMP R0, #4
        BLT MU1
MU9:    RTS PC
MU2:    DEC MODCNT
        BGT MU9
        ADD #2, MODP
        MOV MODP, R2
        MOV (R2), R3
        CMP R3, #177777
        BNE MU4
        MOV #1, MODE        ; the last chase never ends
        MOV #77777, MODCNT
        BR MU5
MU4:    MOV R3, MODCNT
        INC MODE
        BIC #177776, MODE
MU5:    CLR R0              ; everyone turns on their heel
MU6:    MOV R0, R3
        ASL R3
        CMP GST(R3), #2
        BNE MU7
        MOV #1, GREV(R3)
MU7:    INC R0
        CMP R0, #4
        BLT MU6
        RTS PC

; tile-grid contact, checked once per frame - which means pac and a
; ghost can swap tiles between checks and ghost through each other.
; The arcade had exactly this bug; players called it a pass-through.
COLLS:  MOV PACX, R0
        BLT CL9
        CMP R0, #660
        BGT CL9
        CLR GIX
CL1:    MOV GIX, R5
        ASL R5
        MOV GX(R5), R0
        BLT CL8
        CMP R0, #660
        BGT CL8
        ASR R0
        ASR R0
        ASR R0
        ASR R0
        CMP R0, PTX
        BNE CL8
        MOV GY(R5), R1
        ASR R1
        ASR R1
        ASR R1
        ASR R1
        CMP R1, PTY
        BNE CL8
        MOV GST(R5), R2
        CMP R2, #3
        BEQ CLEAT
        CMP R2, #2
        BNE CL8
        ; caught
        MOV #3, STATE
        MOV #170, GENCNT    ; 120. frames of the death scene
        CLR DYFLG
        CLR PACMOQ
        MOV #DTHSND, R0
        JSR PC, SNDSET
        RTS PC
CLEAT:  MOV #4, GST(R5)     ; blue one eaten: 200, 400, 800, 1600
        MOV EATIX, R2
        ASL R2
        MOV ETAB(R2), R0
        JSR PC, ADDSC
        INC EATIX
        CMP EATIX, #4
        BLT CLE1
        MOV #3, EATIX
CLE1:   MOV #EATSND, R0
        JSR PC, SNDSET
CL8:    INC GIX
        CMP GIX, #4
        BLT CL1
CL9:    RTS PC

; ===================== dying and the next board =====================
STDIE:  TST DYFLG
        BNE SDI1
        MOV #1, DYFLG
        JSR PC, ERSGH
SDI1:   DEC GENCNT
        BLE SDI5
        MOV GENCNT, R0      ; pac blinks out, closed-mouthed
        BIC #177770, R0
        BNE SDI8
        TST PLIMG
        BEQ SDI2
        JSR PC, ERSPAC
        BR SDI8
SDI2:   JSR PC, DRWPAC
SDI8:   JSR PC, SNDCUR
        JMP PLAY
SDI5:   JSR PC, ERSPAC
        DEC LIVES
        JSR PC, DRWLIV
        TST LIVES
        BGT SDI6
        HALT                ; game over
SDI6:   JSR PC, RESETA
        CLR DYFLG
        JSR PC, DRWACT
        MOV #1, STATE
        MOV #74, GENCNT
        RTS PC

STLVL:  DEC GENCNT
        BGT SLV9
        JSR PC, ERSPAC
        JSR PC, ERSGH
        JSR PC, MAPINI      ; refill the larder
        MOV #1, EVIS
        JSR PC, DRWDTS
        JSR PC, RESETA
        INC LEVEL
        SUB #74, FRTDUR     ; the blue time shrinks each board
        CMP FRTDUR, #74
        BGE SLV1
        MOV #74, FRTDUR
SLV1:   JSR PC, DRWACT
        MOV #1, STATE
        MOV #74, GENCNT
SLV9:   RTS PC

; ===================== actors on screen =====================
; sprites draw with BISB and erase with BICB using the same mask, so
; they never chip the walls; each actor remembers the image it drew
; last, and the erase uses exactly that image
ERSPAC: MOV PLIMG, R2
        BEQ EPC9
        MOV PACX, R0
        MOV PACY, R1
        JSR PC, ERSPR
        CLR PLIMG
        MOV PACX, R0
        MOV PACY, R1
        JMP RSTDOT
EPC9:   RTS PC

DRWPAC: JSR PC, PACIMG
        MOV R2, PLIMG
        MOV PACX, R0
        MOV PACY, R1
        JMP DRSPR

ERSGH:  CLR GIX
EG1:    MOV GIX, R5
        ASL R5
        MOV GLIMG(R5), R2
        BEQ EG8
        CLR GLIMG(R5)
        MOV GX(R5), R0
        MOV GY(R5), R1
        JSR PC, ERSPR
        MOV GIX, R5
        ASL R5
        MOV GX(R5), R0
        MOV GY(R5), R1
        JSR PC, RSTDOT
EG8:    INC GIX
        CMP GIX, #4
        BLT EG1
        RTS PC

DRWGH:  CLR GIX
DWG1:   JSR PC, GIMG
        MOV GIX, R5
        ASL R5
        MOV R2, GLIMG(R5)
        MOV GX(R5), R0
        MOV GY(R5), R1
        JSR PC, DRSPR
        INC GIX
        CMP GIX, #4
        BLT DWG1
        RTS PC

DRWACT: JSR PC, DRWPAC
        JMP DRWGH

; pac's face: closed when standing, chewing while under way
PACIMG: TST PACMOQ
        BNE PIM1
        MOV #PACC, R2
        RTS PC
PIM1:   MOV PACANM, R2
        ASR R2
        ASR R2
        BIC #177774, R2
        ASL R2
        MOV PACDIR, R3
        ASL R3
        ASL R3
        ASL R3
        ADD R3, R2
        MOV PTAB(R2), R2
        RTS PC

; ghost's look for its state, with the walk wobble and the blue flash
GIMG:   MOV GIX, R5
        ASL R5
        MOV GST(R5), R0
        CMP R0, #4
        BNE GIM1
        MOV #GEYES, R2
        RTS PC
GIM1:   CMP R0, #3
        BNE GINRM
        CMP FRTCNT, #74     ; the last second: the warning flash
        BGT GIFR
        BIT #10, FCNT
        BNE GINRM
GIFR:   BIT #4, FCNT
        BEQ GIF1
        MOV #GFRB, R2
        RTS PC
GIF1:   MOV #GFRA, R2
        RTS PC
GINRM:  BIT #4, FCNT
        BEQ GIN1
        MOV #GBODB, R2
        RTS PC
GIN1:   MOV #GBODA, R2
        RTS PC

; ===================== sprite plumbing =====================
; SPRAD: x in R0 (maze px, even, may be negative in the tunnel), y in R1
; -> R3 = framebuffer byte address, R4 = phase block offset; clobbers R2
SPRAD:  MOV R1, R3
        ADD #20, R3         ; + the score strip
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3              ; * 64.
        ADD #FB, R3
        MOV R0, R2
        ADD #40, R2         ; + the left margin (32.)
        ASR R2
        ASR R2
        ASR R2
        ADD R2, R3
        MOV R0, R2
        BIC #177771, R2     ; phase = x & 6
        MOV R2, R4
        ASL R4
        ADD R2, R4
        ASL R4
        ASL R4
        ASL R4              ; phase * 24. = block of 48. bytes per 2 px
        RTS PC

; DRSPR / ERSPR: image R2 at (R0, R1); 16 rows of 3 bytes, OR in / AND out
DRSPR:  MOV R2, -(SP)
        JSR PC, SPRAD
        MOV (SP)+, R2
        ADD R4, R2
        MOV #20, R4
DSP1:   BISB (R2)+, (R3)+
        BISB (R2)+, (R3)+
        BISB (R2)+, (R3)
        ADD #76, R3         ; 62.: to the next row
        SOB R4, DSP1
        RTS PC

ERSPR:  MOV R2, -(SP)
        JSR PC, SPRAD
        MOV (SP)+, R2
        ADD R4, R2
        MOV #20, R4
ESP1:   BICB (R2)+, (R3)+
        BICB (R2)+, (R3)+
        BICB (R2)+, (R3)
        ADD #76, R3
        SOB R4, ESP1
        RTS PC

; repaint the dots in the (up to four) tiles a sprite at (R0, R1) covers
RSTDOT: MOV R1, R2
        ASR R2
        ASR R2
        ASR R2
        ASR R2
        MOV R2, TY0
        MOV R0, R2
        ASR R2
        ASR R2
        ASR R2
        ASR R2
        MOV R2, TX0
        MOV TX0, R0
        MOV TY0, R1
        JSR PC, REDOT
        MOV TX0, R0
        INC R0
        MOV TY0, R1
        JSR PC, REDOT
        MOV TX0, R0
        MOV TY0, R1
        INC R1
        JSR PC, REDOT
        MOV TX0, R0
        INC R0
        MOV TY0, R1
        INC R1
        JMP REDOT

; repaint whatever the map says lives in tile (R0, R1), if it is on-map
REDOT:  CMP R0, #0
        BLT RDT9
        CMP R0, #33         ; 27.
        BGT RDT9
        CMP R1, #0
        BLT RDT9
        CMP R1, #36         ; 30.
        BGT RDT9
        JSR PC, TILEAD
        MOVB (R3), R2
        CMPB R2, #2
        BNE RDT2
        JMP DRWDOT
RDT2:   CMPB R2, #3
        BNE RDT3
        TST EVIS
        BEQ RDT9
        JMP DRWENE
RDT3:   CMPB R2, #4
        BNE RDT9
        JSR PC, CELLA       ; a passing ghost bites the door bar -
        ADD #700, R3        ; hang it back on its hinges
        BISB #377, (R3)
        BISB #377, 1(R3)
RDT9:   RTS PC

; ===================== the maze on screen =====================
; CELLA: R0 = tx, R1 = ty -> R3 = byte address of the tile's top-left
CELLA:  MOV R1, R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ADD #20, R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ASL R3
        ADD #FB+4, R3
        MOV R0, R2
        ASL R2
        ADD R2, R3
        RTS PC

; TILEAD: R0 = tx, R1 = ty -> R3 = &MAP[ty*28+tx]; clobbers R2
TILEAD: MOV R1, R2
        ASL R2
        ASL R2              ; ty*4
        MOV R2, R3
        ASL R3
        ASL R3
        ASL R3              ; ty*32
        SUB R2, R3          ; ty*28 - one subtract instead of a multiply
        ADD R0, R3
        ADD #MAP, R3
        RTS PC

; NBQ: is tile (R0, R1) open? off the map counts as open, so the outer
; border traces its own outline. Preserves R0, R1; answer in R2.
NBQ:    CMP R0, #0
        BLT NBQ1
        CMP R0, #33
        BGT NBQ1
        CMP R1, #0
        BLT NBQ1
        CMP R1, #36
        BGT NBQ1
        JSR PC, TILEAD
        CMPB (R3), #1
        BEQ NBQ0
NBQ1:   MOV #1, R2
        RTS PC
NBQ0:   CLR R2
        RTS PC

; may an actor step into tile (R0, R1)? Doors are walls to everyone -
; the two scripted house moves never ask. Off-map is only the tunnel.
PASSQ:  CMP R0, #0
        BLT PQT
        CMP R0, #33
        BGT PQT
        CMP R1, #0
        BLT PQ0
        CMP R1, #36
        BGT PQ0
        JSR PC, TILEAD
        MOVB (R3), R2
        CMPB R2, #1
        BEQ PQ0
        CMPB R2, #4
        BEQ PQ0
        MOV #1, R2
        RTS PC
PQT:    CMP R1, #16         ; 14.: the tunnel row
        BEQ PQ1
PQ0:    CLR R2
        RTS PC
PQ1:    MOV #1, R2
        RTS PC

; tunnel wrap: past either mouth the world is round
WRAPX:  CMP R0, #-20
        BGE WRX1
        MOV #700, R0        ; 448.
        RTS PC
WRX1:   CMP R0, #700
        BLE WRX2
        MOV #-20, R0
WRX2:   RTS PC

; candidate tile one step in direction R4 from (CTX, CTY)
STEPTL: MOV R4, R2
        ASL R2
        MOV CTX, R0
        ADD TDX(R2), R0
        MOV CTY, R1
        ADD TDY(R2), R1
        RTS PC

; boot: trace every wall edge that faces an open tile, bar the doors
DRWMAZ: CLR TYV
DM1:    CLR TXV
DM2:    MOV TXV, R0
        MOV TYV, R1
        JSR PC, TILEAD
        MOVB (R3), R5
        CMPB R5, #4
        BNE DM3
        MOV TXV, R0         ; the door: a bar across the middle
        MOV TYV, R1
        JSR PC, CELLA
        ADD #700, R3        ; + 7 rows
        BISB #377, (R3)
        BISB #377, 1(R3)
        BR DM9
DM3:    CMPB R5, #1
        BNE DM9
        MOV TXV, R0
        MOV TYV, R1
        DEC R1
        JSR PC, NBQ
        TST R2
        BEQ DM4
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, CELLA
        BISB #377, (R3)
        BISB #377, 1(R3)
DM4:    MOV TXV, R0
        MOV TYV, R1
        INC R1
        JSR PC, NBQ
        TST R2
        BEQ DM5
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, CELLA
        ADD #1700, R3       ; + 15 rows
        BISB #377, (R3)
        BISB #377, 1(R3)
DM5:    MOV TXV, R0
        DEC R0
        MOV TYV, R1
        JSR PC, NBQ
        TST R2
        BEQ DM6
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, CELLA
        MOV #20, R2
DM5A:   BISB #1, (R3)
        ADD #100, R3
        SOB R2, DM5A
DM6:    MOV TXV, R0
        INC R0
        MOV TYV, R1
        JSR PC, NBQ
        TST R2
        BEQ DM9
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, CELLA
        INC R3
        MOV #20, R2
DM6A:   BISB #200, (R3)
        ADD #100, R3
        SOB R2, DM6A
DM9:    INC TXV
        CMP TXV, #34        ; 28.
        BLT DM2
        INC TYV
        CMP TYV, #37        ; 31.
        BLT DM1
        RTS PC

; a dot is 4x4 in the tile's center: bits 6-7 of the left byte and
; 0-1 of the right one - byte-clean, like everything on this field
DRWDOT: JSR PC, CELLA
        ADD #600, R3        ; + 6 rows
        MOV #4, R4
DDO1:   BISB #300, (R3)
        BISB #3, 1(R3)
        ADD #100, R3
        SOB R4, DDO1
        RTS PC

ERSDOT: JSR PC, CELLA
        ADD #600, R3
        MOV #4, R4
EDO1:   BICB #300, (R3)
        BICB #3, 1(R3)
        ADD #100, R3
        SOB R4, EDO1
        RTS PC

DRWENE: JSR PC, CELLA
        ADD #400, R3        ; + 4 rows: the energizer is 8x8
        MOV #10, R4
DEN1:   BISB #360, (R3)
        BISB #17, 1(R3)
        ADD #100, R3
        SOB R4, DEN1
        RTS PC

ERSENE: JSR PC, CELLA
        ADD #400, R3
        MOV #10, R4
EEN1:   BICB #360, (R3)
        BICB #17, 1(R3)
        ADD #100, R3
        SOB R4, EEN1
        RTS PC

; paint every dot and energizer the map knows about
DRWDTS: CLR TYV
DT1:    CLR TXV
DT2:    MOV TXV, R0
        MOV TYV, R1
        JSR PC, TILEAD
        MOVB (R3), R2
        CMPB R2, #2
        BNE DT3
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, DRWDOT
        BR DT4
DT3:    CMPB R2, #3
        BNE DT4
        MOV TXV, R0
        MOV TYV, R1
        JSR PC, DRWENE
DT4:    INC TXV
        CMP TXV, #34
        BLT DT2
        INC TYV
        CMP TYV, #37
        BLT DT1
        RTS PC

; the energizers wink every 16 frames
ENEBLK: MOV FCNT, R0
        BIC #177760, R0
        BNE EB9
        COM EVIS
        MOV #EPOS, EPTR
EB1:    MOV EPTR, R4
        MOV (R4)+, R0
        MOV (R4)+, R1
        MOV R4, EPTR
        JSR PC, TILEAD
        CMPB (R3), #3
        BNE EB2
        TST EVIS
        BEQ EB1A
        JSR PC, DRWENE
        BR EB2
EB1A:   JSR PC, ERSENE
EB2:    CMP EPTR, #EPOS+20
        BLT EB1
EB9:    RTS PC

; ===================== score and lives =====================
; ADDSC: score += R0 * 10 and repaint. Digits live as six words,
; most significant first; the units digit stays honestly zero.
ADDSC:  ADD R0, DIGS+10
        MOV #DIGS+10, R2
ASC1:   CMP (R2), #12
        BLT ASC2
        SUB #12, (R2)
        INC -2(R2)
        BR ASC1
ASC2:   SUB #2, R2
        CMP R2, #DIGS
        BGE ASC1
        JMP DRWSCR

DRWSCR: MOV #DIGS, R3
        MOV #FB+404, R4     ; y = 4, byte 4
        MOV #6, R5
DSC1:   MOV (R3)+, R0
        MOV R4, R1
        MOV R3, -(SP)
        MOV R4, -(SP)
        MOV R5, -(SP)
        JSR PC, DRWDIG
        MOV (SP)+, R5
        MOV (SP)+, R4
        MOV (SP)+, R3
        INC R4
        SOB R5, DSC1
        RTS PC

DRWDIG: ASL R0
        ASL R0
        ASL R0              ; glyphs are 8 bytes apart
        ADD #DFONT, R0
        MOV #7, R2
DDG1:   MOVB (R0)+, (R1)
        ADD #100, R1
        SOB R2, DDG1
        RTS PC

; one block per remaining life, top right
DRWLIV: MOV #FB+467, R4     ; y = 4, byte 55.
        MOV #1, R5
DLV1:   MOV R4, R1
        MOV #7, R2
        CMP R5, LIVES
        BGT DLERA
DLV2:   MOVB #77, (R1)
        ADD #100, R1
        SOB R2, DLV2
        BR DLNXT
DLERA:  CLRB (R1)
        ADD #100, R1
        SOB R2, DLERA
DLNXT:  ADD #2, R4
        INC R5
        CMP R5, #3
        BLE DLV1
        RTS PC

; ===================== boot chores =====================
CLRFB:  MOV #FB, R0
        MOV #40000, R1      ; 16384. words
CFB1:   CLR (R0)+
        DEC R1
        BNE CFB1
        RTS PC

; the squares table, built the schoolbook way: (n+1)^2 = n^2 + 2n + 1
SQINIT: MOV #SQT, R0
        CLR R1
        CLR R2
SQI1:   MOV R2, (R0)+
        ADD R1, R2
        ADD R1, R2
        ADD #1, R2
        INC R1
        CMP R1, #100        ; 64.
        BLT SQI1
        RTS PC

; parse the ASCII maze into tile codes: 0 empty, 1 wall, 2 dot,
; 3 energizer, 4 door - and count the larder
MAPINI: MOV #ART, R0
        MOV #MAP, R1
        MOV #1544, R2       ; 868. tiles
        CLR DOTCNT
MI1:    MOVB (R0)+, R3
        CLR R4
        CMPB R3, #43        ; '#'
        BNE MI2
        MOV #1, R4
        BR MI8
MI2:    CMPB R3, #56        ; '.'
        BNE MI3
        MOV #2, R4
        INC DOTCNT
        BR MI8
MI3:    CMPB R3, #157       ; 'o'
        BNE MI4
        MOV #3, R4
        INC DOTCNT
        BR MI8
MI4:    CMPB R3, #55        ; '-'
        BNE MI8
        MOV #4, R4
MI8:    MOVB R4, (R1)+
        DEC R2
        BNE MI1
        RTS PC

; actors to their posts: pac below the house, Blinky on the doorstep,
; the other three bunked with staggered leave passes
RESETA: MOV #320, PACX      ; (13., 23.)
        MOV #560, PACY
        MOV #1, PACDIR
        MOV #1, PACWNT
        CLR PACMOQ
        CLR PACANM
        CLR FRTCNT
        CLR PLIMG
        MOV #320, GX        ; blinky, out at (13., 11.)
        MOV #260, GY
        MOV #1, GDIR
        MOV #2, GST
        CLR GREL
        CLR GREV
        CLR GLIMG
        MOV #320, GX+2      ; pinky
        MOV #340, GY+2
        CLR GDIR+2
        CLR GST+2
        MOV #170, GREL+2    ; 120. frames in the bunk
        CLR GREV+2
        CLR GLIMG+2
        MOV #260, GX+4      ; inky at (11., 14.)
        MOV #340, GY+4
        CLR GDIR+4
        CLR GST+4
        MOV #550, GREL+4    ; 360.
        CLR GREV+4
        CLR GLIMG+4
        MOV #400, GX+6      ; clyde at (16., 14.)
        MOV #340, GY+6
        CLR GDIR+6
        CLR GST+6
        MOV #1130, GREL+6   ; 600.
        CLR GREV+6
        CLR GLIMG+6
        RTS PC

; ===================== sound =====================
; The KW11-P does the toggling in the background; the frame handler
; only decides *which* note sounds. Scripts are (note, frames) pairs,
; note 0 is a rest, 177777 ends the script. SNDSET starts a jingle;
; SNDIF only bothers if nothing is playing.

; the metronome itself: half a period per interrupt, no registers
PTICK:  COM SPKSH
        MOV SPKSH, @#SPK
        RTI

SNDSET: MOV R0, SNDP
        CLR SNDF
        RTS PC
SNDIF:  TST SNDP
        BNE SIF9
        MOV R0, SNDP
        CLR SNDF
SIF9:   RTS PC

; SNDCUR: advance the running script; R0 = this frame's note (0 = none)
SNDCUR: MOV SNDP, R5
        BNE SCU1
        CLR R0
        RTS PC
SCU1:   TST SNDF
        BNE SCU2
        MOV 2(R5), SNDF     ; a fresh note: latch its length
SCU2:   MOV (R5), R4
        DEC SNDF
        BNE SCU3
        ADD #4, SNDP        ; note over: step to the next pair
        MOV SNDP, R5
        CMP (R5), #177777
        BNE SCU3
        CLR SNDP
SCU3:   MOV R4, R0
        RTS PC

; PLAY: sound note R0 (a half-period preset), or 0 for silence.
; Writing the buffer mid-note only changes the *next* reload, so a
; pitch change never resets the phase - no clicks, no 60 Hz hum.
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

; a 16-bit Galois shift register - the house pseudo-random
RANDOM: MOV SEED, R0
        CLC
        ROR R0
        BCC RND1
        MOV #132000, R1
        XOR R1, R0
RND1:   MOV R0, SEED
        RTS PC

; ===================== variables =====================
STATE:  .WORD 0
FCNT:   .WORD 0
GENCNT: .WORD 0
PREVF:  .WORD 0
LIVES:  .WORD 3
LEVEL:  .WORD 1
DOTCNT: .WORD 0
DIGS:   .WORD 0, 0, 0, 0, 0, 0
PACX:   .WORD 0
PACY:   .WORD 0
PACDIR: .WORD 1
PACWNT: .WORD 1
PACMOQ: .WORD 0
PACANM: .WORD 0
PLIMG:  .WORD 0
PTX:    .WORD 0
PTY:    .WORD 0
CTX:    .WORD 0
CTY:    .WORD 0
TX0:    .WORD 0
TY0:    .WORD 0
GIX:    .WORD 0
GX:     .WORD 0, 0, 0, 0
GY:     .WORD 0, 0, 0, 0
GDIR:   .WORD 0, 0, 0, 0
GST:    .WORD 0, 0, 0, 0
GREL:   .WORD 0, 0, 0, 0
GREV:   .WORD 0, 0, 0, 0
GLIMG:  .WORD 0, 0, 0, 0
BLKTX:  .WORD 0
BLKTY:  .WORD 0
TGX:    .WORD 0
TGY:    .WORD 0
BSTD:   .WORD 0
BSTI:   .WORD 0
MODE:   .WORD 0             ; 0 scatter, 1 chase
MODP:   .WORD MODTAB
MODCNT: .WORD 644           ; 420.: the first scatter
FRTCNT: .WORD 0
FRTDUR: .WORD 310           ; 200.: 3.3 seconds of fear
EATIX:  .WORD 0
EVIS:   .WORD 1
EPTR:   .WORD 0
TXV:    .WORD 0
TYV:    .WORD 0
SEED:   .WORD 30071
WAKAF:  .WORD 0
SNDP:   .WORD 0
SNDF:   .WORD 0
CURNT:  .WORD 0             ; the note sounding right now
SPKSH:  .WORD 0             ; the metronome's speaker shadow
INVS:   .WORD 0             ; frame handler re-entry latch
DYFLG:  .WORD 0

; ===================== tables =====================
; direction order everywhere: 0 up, 1 left, 2 down, 3 right -
; exactly the arcade's tie-breaking priority
DXT:    .WORD 0, -2, 0, 2
DYT:    .WORD -2, 0, 2, 0
TDX:    .WORD 0, -1, 0, 1
TDY:    .WORD -1, 0, 1, 0

; scatter corners: Blinky NE, Pinky NW, Inky SE, Clyde SW
SCTX:   .WORD 32, 1, 32, 1
SCTY:   .WORD 1, 1, 35, 35

; the scatter/chase waves, in frames; the last chase is forever
MODTAB: .WORD 644, 2260, 644, 2260, 454, 2260, 454, 177777

; ghost bounties, in tens: 200, 400, 800, 1600
ETAB:   .WORD 24, 50, 120, 240

; energizer tiles, (tx, ty) pairs, for the wink
EPOS:   .WORD 1, 3, 32, 3, 1, 26, 32, 26

; pac's mouth cycle per direction: closed, half, wide, half
PTAB:   .WORD PACC, PACH0, PACW0, PACH0
        .WORD PACC, PACH1, PACW1, PACH1
        .WORD PACC, PACH2, PACW2, PACH2
        .WORD PACC, PACH3, PACW3, PACH3

; sound scripts: (note, frames) pairs, 0 is a rest, 177777 ends
WAKAA:  .WORD NA5, 2, NE5, 1, 177777
WAKAB:  .WORD NE5, 2, NA5, 1, 177777
EATSND: .WORD NA4, 2, NCS5, 2, NE5, 2, NA5, 4, 177777
DTHSND: .WORD NA5, 6, NG5, 6, NF5, 6, NE5, 6, ND5, 6, NC5, 6
        .WORD NB4, 6, NA4, 10, 0, 4, NA3, 14
        .WORD 177777

; 5x7 digit font, bit 0 = leftmost pixel, 8 bytes per glyph
DFONT:  .BYTE 16, 21, 21, 21, 21, 21, 16, 0     ; 0
        .BYTE 4, 6, 4, 4, 4, 4, 16, 0           ; 1
        .BYTE 16, 21, 20, 10, 4, 2, 37, 0       ; 2
        .BYTE 37, 10, 4, 10, 20, 21, 16, 0      ; 3
        .BYTE 10, 14, 12, 11, 37, 10, 10, 0     ; 4
        .BYTE 37, 1, 17, 20, 20, 21, 16, 0      ; 5
        .BYTE 16, 1, 1, 17, 21, 21, 16, 0       ; 6
        .BYTE 37, 20, 10, 4, 2, 2, 2, 0         ; 7
        .BYTE 16, 21, 21, 16, 21, 21, 16, 0     ; 8
        .BYTE 16, 21, 21, 36, 20, 21, 16, 0     ; 9

; ===================== the maze =====================
; 31 rows by 28 columns; '#' wall, '.' dot, 'o' energizer, '-' door,
; space - bare corridor. Not Namco's board - ours, same spirit.
ART:    .ASCII /############################/
        .ASCII /#............##............#/
        .ASCII /#.####.#####.##.#####.####.#/
        .ASCII /#o####.#####.##.#####.####o#/
        .ASCII /#..........................#/
        .ASCII /#.####.##.########.##.####.#/
        .ASCII /#......##..........##......#/
        .ASCII /######.##.########.##.######/
        .ASCII /######.##.########.##.######/
        .ASCII /######................######/
        .ASCII /#########.########.#########/
        .ASCII /#########          #########/
        .ASCII /######### ###--### #########/
        .ASCII /######### #      # #########/
        .ASCII /          #      #          /
        .ASCII /######### #      # #########/
        .ASCII /######### ######## #########/
        .ASCII /#########          #########/
        .ASCII /#########.########.#########/
        .ASCII /#########.########.#########/
        .ASCII /#..........................#/
        .ASCII /#.####.#####.##.#####.####.#/
        .ASCII /#o####.#####.##.#####.####o#/
        .ASCII /#............  ............#/
        .ASCII /#.####.#####.##.#####.####.#/
        .ASCII /#.####.#####.##.#####.####.#/
        .ASCII /#......##....##....##......#/
        .ASCII /#.####.##.########.##.####.#/
        .ASCII /#.####.##.########.##.####.#/
        .ASCII /#..........................#/
        .ASCII /############################/

        .EVEN
MAP:    .BLKB 1544          ; 868. tile codes
        .EVEN
SQT:    .BLKW 100           ; squares of 0..63.

; --- sprites begin (generated by gen-sprites.mjs, do not edit) ---
PACC:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACH0:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 40, 4, 0
	.BYTE 70, 34, 0
	.BYTE 74, 74, 0
	.BYTE 74, 74, 0
	.BYTE 76, 174, 0
	.BYTE 176, 176, 0
	.BYTE 176, 176, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 20, 0
	.BYTE 340, 160, 0
	.BYTE 360, 360, 0
	.BYTE 360, 360, 0
	.BYTE 370, 360, 1
	.BYTE 370, 371, 1
	.BYTE 370, 371, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 102, 0
	.BYTE 200, 303, 1
	.BYTE 300, 303, 3
	.BYTE 300, 303, 3
	.BYTE 340, 303, 7
	.BYTE 340, 347, 7
	.BYTE 340, 347, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 10, 1
	.BYTE 0, 16, 7
	.BYTE 0, 17, 17
	.BYTE 0, 17, 17
	.BYTE 200, 17, 37
	.BYTE 200, 237, 37
	.BYTE 200, 237, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACH1:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 376, 177, 0
	.BYTE 300, 177, 0
	.BYTE 0, 177, 0
	.BYTE 0, 177, 0
	.BYTE 300, 177, 0
	.BYTE 376, 177, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 370, 377, 1
	.BYTE 0, 377, 1
	.BYTE 0, 374, 1
	.BYTE 0, 374, 1
	.BYTE 0, 377, 1
	.BYTE 370, 377, 1
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 377, 7
	.BYTE 0, 374, 7
	.BYTE 0, 360, 7
	.BYTE 0, 360, 7
	.BYTE 0, 374, 7
	.BYTE 340, 377, 7
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 377, 37
	.BYTE 0, 360, 37
	.BYTE 0, 300, 37
	.BYTE 0, 300, 37
	.BYTE 0, 360, 37
	.BYTE 200, 377, 37
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACH2:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 176, 176, 0
	.BYTE 176, 176, 0
	.BYTE 76, 174, 0
	.BYTE 74, 74, 0
	.BYTE 74, 74, 0
	.BYTE 70, 34, 0
	.BYTE 40, 4, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 371, 1
	.BYTE 370, 371, 1
	.BYTE 370, 360, 1
	.BYTE 360, 360, 0
	.BYTE 360, 360, 0
	.BYTE 340, 160, 0
	.BYTE 200, 20, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 347, 7
	.BYTE 340, 347, 7
	.BYTE 340, 303, 7
	.BYTE 300, 303, 3
	.BYTE 300, 303, 3
	.BYTE 200, 303, 1
	.BYTE 0, 102, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 237, 37
	.BYTE 200, 237, 37
	.BYTE 200, 17, 37
	.BYTE 0, 17, 17
	.BYTE 0, 17, 17
	.BYTE 0, 16, 7
	.BYTE 0, 10, 1
	.BYTE 0, 0, 0
PACH3:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 376, 177, 0
	.BYTE 376, 3, 0
	.BYTE 376, 0, 0
	.BYTE 376, 0, 0
	.BYTE 376, 3, 0
	.BYTE 376, 177, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 370, 377, 1
	.BYTE 370, 17, 0
	.BYTE 370, 3, 0
	.BYTE 370, 3, 0
	.BYTE 370, 17, 0
	.BYTE 370, 377, 1
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 377, 7
	.BYTE 340, 77, 0
	.BYTE 340, 17, 0
	.BYTE 340, 17, 0
	.BYTE 340, 77, 0
	.BYTE 340, 377, 7
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 377, 37
	.BYTE 200, 377, 0
	.BYTE 200, 77, 0
	.BYTE 200, 77, 0
	.BYTE 200, 377, 0
	.BYTE 200, 377, 37
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACW0:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 4, 40, 0
	.BYTE 14, 60, 0
	.BYTE 36, 170, 0
	.BYTE 76, 174, 0
	.BYTE 176, 176, 0
	.BYTE 176, 176, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 20, 200, 0
	.BYTE 60, 300, 0
	.BYTE 170, 340, 1
	.BYTE 370, 360, 1
	.BYTE 370, 371, 1
	.BYTE 370, 371, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 100, 0, 2
	.BYTE 300, 0, 3
	.BYTE 340, 201, 7
	.BYTE 340, 303, 7
	.BYTE 340, 347, 7
	.BYTE 340, 347, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 1, 10
	.BYTE 0, 3, 14
	.BYTE 200, 7, 36
	.BYTE 200, 17, 37
	.BYTE 200, 237, 37
	.BYTE 200, 237, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACW1:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 360, 77, 0
	.BYTE 340, 77, 0
	.BYTE 300, 177, 0
	.BYTE 200, 177, 0
	.BYTE 0, 176, 0
	.BYTE 0, 176, 0
	.BYTE 200, 177, 0
	.BYTE 300, 177, 0
	.BYTE 340, 77, 0
	.BYTE 360, 77, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 300, 377, 0
	.BYTE 200, 377, 0
	.BYTE 0, 377, 1
	.BYTE 0, 376, 1
	.BYTE 0, 370, 1
	.BYTE 0, 370, 1
	.BYTE 0, 376, 1
	.BYTE 0, 377, 1
	.BYTE 200, 377, 0
	.BYTE 300, 377, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 0, 377, 3
	.BYTE 0, 376, 3
	.BYTE 0, 374, 7
	.BYTE 0, 370, 7
	.BYTE 0, 340, 7
	.BYTE 0, 340, 7
	.BYTE 0, 370, 7
	.BYTE 0, 374, 7
	.BYTE 0, 376, 3
	.BYTE 0, 377, 3
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 374, 17
	.BYTE 0, 370, 17
	.BYTE 0, 360, 37
	.BYTE 0, 340, 37
	.BYTE 0, 200, 37
	.BYTE 0, 200, 37
	.BYTE 0, 340, 37
	.BYTE 0, 360, 37
	.BYTE 0, 370, 17
	.BYTE 0, 374, 17
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
PACW2:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 176, 176, 0
	.BYTE 176, 176, 0
	.BYTE 76, 174, 0
	.BYTE 36, 170, 0
	.BYTE 14, 60, 0
	.BYTE 4, 40, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 371, 1
	.BYTE 370, 371, 1
	.BYTE 370, 360, 1
	.BYTE 170, 340, 1
	.BYTE 60, 300, 0
	.BYTE 20, 200, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 347, 7
	.BYTE 340, 347, 7
	.BYTE 340, 303, 7
	.BYTE 340, 201, 7
	.BYTE 300, 0, 3
	.BYTE 100, 0, 2
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 237, 37
	.BYTE 200, 237, 37
	.BYTE 200, 17, 37
	.BYTE 200, 7, 36
	.BYTE 0, 3, 14
	.BYTE 0, 1, 10
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
PACW3:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 17, 0
	.BYTE 374, 7, 0
	.BYTE 376, 3, 0
	.BYTE 376, 1, 0
	.BYTE 176, 0, 0
	.BYTE 176, 0, 0
	.BYTE 376, 1, 0
	.BYTE 376, 3, 0
	.BYTE 374, 7, 0
	.BYTE 374, 17, 0
	.BYTE 370, 37, 0
	.BYTE 340, 7, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 77, 0
	.BYTE 360, 37, 0
	.BYTE 370, 17, 0
	.BYTE 370, 7, 0
	.BYTE 370, 1, 0
	.BYTE 370, 1, 0
	.BYTE 370, 7, 0
	.BYTE 370, 17, 0
	.BYTE 360, 37, 0
	.BYTE 360, 77, 0
	.BYTE 340, 177, 0
	.BYTE 200, 37, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 0
	.BYTE 300, 177, 0
	.BYTE 340, 77, 0
	.BYTE 340, 37, 0
	.BYTE 340, 7, 0
	.BYTE 340, 7, 0
	.BYTE 340, 37, 0
	.BYTE 340, 77, 0
	.BYTE 300, 177, 0
	.BYTE 300, 377, 0
	.BYTE 200, 377, 1
	.BYTE 0, 176, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 3
	.BYTE 0, 377, 1
	.BYTE 200, 377, 0
	.BYTE 200, 177, 0
	.BYTE 200, 37, 0
	.BYTE 200, 37, 0
	.BYTE 200, 177, 0
	.BYTE 200, 377, 0
	.BYTE 0, 377, 1
	.BYTE 0, 377, 3
	.BYTE 0, 376, 7
	.BYTE 0, 370, 1
	.BYTE 0, 0, 0
GBODA:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 316, 163, 0
	.BYTE 316, 163, 0
	.BYTE 316, 163, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 146, 146, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 70, 317, 1
	.BYTE 70, 317, 1
	.BYTE 70, 317, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 230, 231, 1
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 74, 7
	.BYTE 340, 74, 7
	.BYTE 340, 74, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 140, 146, 6
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 363, 34
	.BYTE 200, 363, 34
	.BYTE 200, 363, 34
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 231, 31
	.BYTE 0, 0, 0
GBODB:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 370, 37, 0
	.BYTE 374, 77, 0
	.BYTE 374, 77, 0
	.BYTE 316, 163, 0
	.BYTE 316, 163, 0
	.BYTE 316, 163, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 376, 177, 0
	.BYTE 314, 63, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 340, 177, 0
	.BYTE 360, 377, 0
	.BYTE 360, 377, 0
	.BYTE 70, 317, 1
	.BYTE 70, 317, 1
	.BYTE 70, 317, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 370, 377, 1
	.BYTE 60, 317, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 377, 1
	.BYTE 300, 377, 3
	.BYTE 300, 377, 3
	.BYTE 340, 74, 7
	.BYTE 340, 74, 7
	.BYTE 340, 74, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 340, 377, 7
	.BYTE 300, 74, 3
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 376, 7
	.BYTE 0, 377, 17
	.BYTE 0, 377, 17
	.BYTE 200, 363, 34
	.BYTE 200, 363, 34
	.BYTE 200, 363, 34
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 200, 377, 37
	.BYTE 0, 363, 14
	.BYTE 0, 0, 0
GFRA:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 30, 30, 0
	.BYTE 4, 40, 0
	.BYTE 4, 40, 0
	.BYTE 2, 100, 0
	.BYTE 62, 114, 0
	.BYTE 62, 114, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 232, 131, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 146, 146, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 140, 140, 0
	.BYTE 20, 200, 0
	.BYTE 20, 200, 0
	.BYTE 10, 0, 1
	.BYTE 310, 60, 1
	.BYTE 310, 60, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 150, 146, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 230, 231, 1
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 201, 1
	.BYTE 100, 0, 2
	.BYTE 100, 0, 2
	.BYTE 40, 0, 4
	.BYTE 40, 303, 4
	.BYTE 40, 303, 4
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 240, 231, 5
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 140, 146, 6
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 6, 6
	.BYTE 0, 1, 10
	.BYTE 0, 1, 10
	.BYTE 200, 0, 20
	.BYTE 200, 14, 23
	.BYTE 200, 14, 23
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 200, 146, 26
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 200, 231, 31
	.BYTE 0, 0, 0
GFRB:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 340, 7, 0
	.BYTE 30, 30, 0
	.BYTE 4, 40, 0
	.BYTE 4, 40, 0
	.BYTE 2, 100, 0
	.BYTE 62, 114, 0
	.BYTE 62, 114, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 232, 131, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 2, 100, 0
	.BYTE 314, 63, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 200, 37, 0
	.BYTE 140, 140, 0
	.BYTE 20, 200, 0
	.BYTE 20, 200, 0
	.BYTE 10, 0, 1
	.BYTE 310, 60, 1
	.BYTE 310, 60, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 150, 146, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 10, 0, 1
	.BYTE 60, 317, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 176, 0
	.BYTE 200, 201, 1
	.BYTE 100, 0, 2
	.BYTE 100, 0, 2
	.BYTE 40, 0, 4
	.BYTE 40, 303, 4
	.BYTE 40, 303, 4
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 240, 231, 5
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 40, 0, 4
	.BYTE 300, 74, 3
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 370, 1
	.BYTE 0, 6, 6
	.BYTE 0, 1, 10
	.BYTE 0, 1, 10
	.BYTE 200, 0, 20
	.BYTE 200, 14, 23
	.BYTE 200, 14, 23
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 200, 146, 26
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 200, 0, 20
	.BYTE 0, 363, 14
	.BYTE 0, 0, 0
GEYES:
	; phase 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 30, 30, 0
	.BYTE 74, 74, 0
	.BYTE 74, 74, 0
	.BYTE 30, 30, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 2
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 140, 140, 0
	.BYTE 360, 360, 0
	.BYTE 360, 360, 0
	.BYTE 140, 140, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 4
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 200, 201, 1
	.BYTE 300, 303, 3
	.BYTE 300, 303, 3
	.BYTE 200, 201, 1
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	; phase 6
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 6, 6
	.BYTE 0, 17, 17
	.BYTE 0, 17, 17
	.BYTE 0, 6, 6
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
	.BYTE 0, 0, 0
; --- sprites end ---

        .END START
