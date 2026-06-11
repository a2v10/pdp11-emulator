; ----- bounce demo: ball, border and a paddle (left/right arrows) -----

FB      = 60000             ; framebuffer: 512x512, 64. bytes per row
LKS     = 177546            ; KW11 line clock
JOY     = 177570            ; joystick: bit 0 - left, bit 1 - right

        . = 100             ; clock interrupt vector
        .WORD VSYNC, 340

        . = 1000
START:  MOV #60000, SP
        JSR PC, BORDER
        MOV #100, @#LKS     ; enable clock interrupts (60 Hz)
IDLE:   WAIT                ; everything happens in the frame handler
        BR IDLE

; ---- frame ----
VSYNC:  MOV BALLX, R0       ; erase the ball
        MOV BALLY, R1
        CLR R2
        JSR PC, BLOCK8

        INC FCNT            ; X moves every other frame (8 px),
        BIT #1, FCNT        ; matching 4 px/frame on Y
        BNE YMOVE
        MOV BALLX, R0
        ADD BDX, R0
        CMP R0, #1
        BLT XBNC
        CMP R0, #76         ; 62.
        BLOS XOK
XBNC:   NEG BDX
        MOV BALLX, R0
        ADD BDX, R0
XOK:    MOV R0, BALLX

YMOVE:  MOV BALLY, R1
        ADD BDY, R1
        CMP R1, #1
        BLT YBNC
        CMP R1, #755        ; 493.
        BLOS YOK
YBNC:   NEG BDY
        MOV BALLY, R1
        ADD BDY, R1
YOK:    MOV R1, BALLY

        MOV BALLX, R0       ; draw the ball
        MOV BALLY, R1
        MOV #377, R2
        JSR PC, BLOCK8

        CLR R2              ; erase the paddle
        JSR PC, PADDLE
        MOV @#JOY, R3       ; poll the joystick
        BIT #1, R3
        BEQ NOL
        DEC PADX
NOL:    BIT #2, R3
        BEQ NOR
        INC PADX
NOR:    TST PADX            ; clamp to the field
        BGE CL1
        CLR PADX
CL1:    CMP PADX, #70       ; 56.
        BLOS CL2
        MOV #70, PADX
CL2:    MOV #377, R2        ; draw the paddle
        JSR PC, PADDLE
        RTI

; ---- BLOCK8: 8x8 block. R0 = byte column, R1 = y, R2 = fill byte ----
BLOCK8: ASL R1
        ASL R1
        ASL R1
        ASL R1
        ASL R1
        ASL R1              ; y * 64.
        ADD #FB, R1
        ADD R1, R0          ; address = FB + y*64. + column
        MOV #10, R1         ; 8 rows
BLK1:   MOVB R2, (R0)
        ADD #100, R0        ; next row
        SOB R1, BLK1
        RTS PC

; ---- PADDLE: 64x4 px. PADX = byte column, R2 = fill ----
PADDLE: MOV PADX, R1
        ADD #FB+76500, R1   ; y = 501.  (501. * 64.)
        MOV #4, R3
PROW:   MOV R1, R0
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)+
        MOVB R2, (R0)
        ADD #100, R1
        SOB R3, PROW
        RTS PC

; ---- BORDER: a frame along the screen edge ----
BORDER: MOV #FB, R0         ; top row
        MOV #100, R1
TOPB:   MOVB #377, (R0)+
        SOB R1, TOPB
        MOV #FB+77700, R0   ; bottom row (511. * 64.)
        MOV #100, R1
BOTB:   MOVB #377, (R0)+
        SOB R1, BOTB
        MOV #FB, R0         ; side columns
        MOV #1000, R1       ; 512. rows
SIDES:  BISB #1, (R0)       ; left edge
        BISB #200, 77(R0)   ; right edge (+63.)
        ADD #100, R0
        SOB R1, SIDES
        RTS PC

FCNT:   .WORD 0
BALLX:  .WORD 36
BALLY:  .WORD 100
BDX:    .WORD 1
BDY:    .WORD 4
PADX:   .WORD 34

        .END START
