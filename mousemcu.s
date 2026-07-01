; ============================================================
; Apple II Mouse Interface Card MC68705 firmware 341-0269.2b
; Disassembly by Mike Wiese
; 2026-07-07
;
; Authors: Marks / MacDougall / MacKay / Bachman
; Apple Computer Inc. 1983
;
; MCU: Motorola MC68705P3  (6805-family 8-bit MCU)
;   2 KB internal EPROM mapped $0080–$07FF
;   128 B RAM at $0010–$008F (mirrored / overlapped by I/O)
;   I/O registers at $0000–$0009
;   Vectors at $07F8–$07FF
; ============================================================

; -- I/O Registers -------------------------------------------
PORTA           = $00   ; Port A: 8-bit bidirectional data bus <-> Apple II PIA Port A
PORTB           = $01   ; Port B: PB6 = Apple II IRQ (active low, driven by MCU)
PORTC           = $02   ; Port C handshake (PC0/PC1 = inputs, PC2/PC3 = outputs)
DDRA            = $04   ; Port A Data Direction Register (0=input, 1=output)
DDRB            = $05   ; Port B Data Direction Register
DDRC            = $06   ; Port C Data Direction Register ($0C: PC2,PC3=output)
TIMER           = $08   ; Timer Data Register (free-running, decrements)
TCR             = $09   ; Timer Control Register

; Port C handshake protocol:
;   PC0 in  — Apple II asserts to ACK data received from MCU
;   PC1 in  — Apple II asserts when sending command/data to MCU
;   PC2 out — MCU asserts when data ready for Apple II
;   PC3 out — MCU asserts to ACK receipt of Apple II data
;
; Port B:
;   PB6 out — Apple II IRQ (active low; initialized high = deasserted)
;   PB0-PB3 in — quadrature encoder inputs:
;       PB1 = X0 (direct)         PB3 = Y1 (direct)        <- clock / trigger lines
;       PB0 = X1 (via flip-flop)  PB2 = Y0 (via flip-flop) <- direction lines (latched at clock edge)
;     The flip-flop latches the direction line at the clock edge so the polling
;     loop reads a stable direction. Note the clock/direction roles are swapped
;     between X (clock=X0) and Y (clock=Y1), which inverts the Y count sign --
;     so Y increases downward to match Apple II screen coordinates.
;     The IIc firmware does the same Y inversion in software.
;   PB7 in  — mouse button (0 = pressed)

; -- RAM Variables ($0010–$007F) -----------------------------
XHI             = $40
YHI             = $41
XLO             = $42
YLO             = $43
PORT_STATE      = $44
NEW_STATE       = $45
BUTTON_STATUS   = $46
XMIN_HI         = $47
YMIN_HI         = $48
XMIN_LO         = $49
YMIN_LO         = $4A
XMAX_HI         = $4B
YMAX_HI         = $4C
XMAX_LO         = $4D
YMAX_LO         = $4E
TIMER_HI        = $4F
TIMER_NEG_DT_LO = $50   ; TIMER_NEG_DT = 266 - ticks/frame (a negative 16-bit value, ISR subtracts it)
TIMER_NEG_DT_HI = $51   ;   TIMER_DT = positive timer delta = ticks/frame - 266
SEED_LO         = $52
SEED_HI         = $53
SEED_DELTA_LO   = $54   ; 16-bit signed delta added to SEED (CMD_TIMEDATA bit 2)
SEED_DELTA_HI   = $55
FRAME_COUNTER   = $56   ; counts frames down to next IRQ; reloaded from FRAMES_PER_IRQ
FRAMES_PER_IRQ  = $57   ; frame divider: fire the mouse IRQ once every N frames
MOUSE_MODE      = $58   ; low 4 bits = mode (b0 on/off, b1 move IRQ, b2 btn IRQ, b3 VBL IRQ)
CMD_BYTE        = $59
MOVED_STATUS    = $5A
MOUSE_MOVED     = $5B   ; mouse moved (bit 1) since last VBL tick; folded into INT_STATUS and cleared by TIMER_ISR
INT_STATUS      = $5C   ; accumulated interrupt sources; returned/cleared by CMD_SERVEMOUSE
MOUSE_OPTIONS   = $5D   ; option bits set via CMD_OPTMOUSE
DIAG_INSTR      = $5E
DIAG_ADDR_HI    = $5F
DIAG_ADDR_LO    = $60
DIAG_ARG        = $61

; -- MCU Commands (Apple II -> MCU, high nibble selects command) -
; Bytes exchanged after the 1-byte command
; (params = Apple II -> MCU, result = MCU -> Apple II):
;
;   Command         val  params  result  payload / notes
;   CMD_SETMOUSE    $00  0       0       mode is in the command's low nibble
;   CMD_READMOUSE   $10  0       5       send XLO,XHI,YLO,YHI,STATUS; clear MOVED_STATUS
;   CMD_SERVEMOUSE  $20  0       1       send INT_STATUS byte; clear it
;   CMD_CLEARMOUSE  $30  0       0       zero position, button status, delta
;   CMD_POSMOUSE    $40  4       0       set XLO,XHI,YLO,YHI
;   CMD_INITMOUSE   $50  1       1       disable IRQ, reset, send $00 ACK, reinit
;   CMD_CLAMPMOUSE  $60  4       0       MIN_LO,MAX_LO,MIN_HI,MAX_HI (axis = bit 0)
;   CMD_HOMEMOUSE   $70  0       0       set position to clamp-min values
;   CMD_TRANSPARENT $80  0       0       set "transparent" mode (IIc tech ref): turn mouse on
;   CMD_TIMEDATA    $90  0-3     0       +2 if bit2 (16-bit delta), +1 if bit3 (FRAMES_PER_IRQ)
;   CMD_SETVBLCNTS  $A0  1       0       FRAMES_PER_IRQ
;   CMD_OPTMOUSE    $B0  0       0       options in the command's low nibble
;   CMD_STARTTIMER  $C0  0       0       restart the frame timer
;   CMD_DIAGMOUSE   $F0  2       1       read:  2 addr in, 1 byte out
;   CMD_DIAGMOUSE   $F1  3       0       write: 2 addr + 1 data in
;
;   CMD_NOP     $D0/$E0  0       0       no-op

; ════════════════════════════════════════════════════════════
; ROM code begins at $0080
; ════════════════════════════════════════════════════════════

        .org $0080

; ------------------------------------------------------------
; RECV_BYTE — receive one byte from Apple II via Port A
; Entry: (none)
; Exit:  A = byte received
; ------------------------------------------------------------

RECV_BYTE:
        $0080  03 02 FD       brclr 1, PORTC,*              ; wait: Apple II asserts PC1 (data ready)

RECV_BYTE_skip:
        $0083  B6 00          lda PORTA                     ; read byte from Port A
        $0085  16 02          bset 3, PORTC                 ; assert PC3 (MCU ack)
        $0087  02 02 FD       brset 1, PORTC,*              ; wait: Apple II de-asserts PC1
        $008A  17 02          bclr 3, PORTC                 ; clear PC3
        $008C  81             rts

SEND_BYTE:
        $008D  00 02 FD       brset 0, PORTC,*              ; wait: PC0 de-asserted (Apple II ready)
        $0090  B7 00          sta PORTA                     ; put byte on Port A
        $0092  14 02          bset 2, PORTC                 ; assert PC2 (MCU: data ready)
        $0094  01 02 FD       brclr 0, PORTC,*              ; wait: Apple II asserts PC0 (ACK)
        $0097  15 02          bclr 2, PORTC                 ; clear PC2
        $0099  81             rts

; ------------------------------------------------------------
; QUAD_MASKS — quadrature decoder bit-mask table (4 bytes)
; Indexed by axis: X_reg=0: X axis, X_reg=1: Y axis
; QUAD_MASKS[0] = $02  clock mask     X0 (PB1)   <- trigger: count on this line's edge
; QUAD_MASKS[1] = $08  clock mask     Y1 (PB3)
; QUAD_MASKS[2] = $01  direction mask X1 (PB0)   <- level at the edge gives direction
; QUAD_MASKS[3] = $04  direction mask Y0 (PB2)
; ------------------------------------------------------------

QUAD_MASKS:
        $009A  02 08 01 04    .byte $02,$08,$01,$04

; ------------------------------------------------------------
; DISPATCH_TABLE — command dispatch: 16 entries × 4 bytes
; Entry format: JMP ext (3 bytes) + $00 pad
; Index: X = (cmd >> 2) & $3C
; ------------------------------------------------------------

DISPATCH_TABLE:
        $009E  CC 04 6C 00  jmp CMD_SETMOUSE
        $00A2  CC 04 73 00  jmp CMD_READMOUSE
        $00A6  CC 04 DC 00  jmp CMD_SERVEMOUSE
        $00AA  CC 05 1B 00  jmp CMD_CLEARMOUSE
        $00AE  CC 05 2C 00  jmp CMD_POSMOUSE
        $00B2  CC 05 47 00  jmp CMD_INITMOUSE
        $00B6  CC 05 74 00  jmp CMD_CLAMPMOUSE
        $00BA  CC 05 90 00  jmp CMD_HOMEMOUSE
        $00BE  CC 05 A7 00  jmp CMD_TRANSPARENT
        $00C2  CC 05 B0 00  jmp CMD_TIMEDATA
        $00C6  CC 06 17 00  jmp CMD_SETVBLCNTS
        $00CA  CC 06 1F 00  jmp CMD_OPTMOUSE
        $00CE  CC 06 26 00  jmp CMD_STARTTIMER
        $00D2  CC 06 7A 00  jmp CMD_NOP
        $00D6  CC 06 7A 00  jmp CMD_NOP
        $00DA  CC 06 48 00  jmp CMD_DIAGMOUSE

; ------------------------------------------------------------
; $00DE–$03BF: unused EPROM ($00, except a lone $01 at $00FE)
; ------------------------------------------------------------
        .res  $00FE-$00DE, $00          ; $00DE-$00FD  unused, $00
        .byte $01                       ; $00FE        lone stray byte
        .res  $03C0-$00FF, $00          ; $00FF-$03BF  unused, $00

; ════════════════════════════════════════════════════════════
; RESET handler
; ════════════════════════════════════════════════════════════

        .org $03C0

RESET:
        $03C0  A6 00          lda #$00                      ; init Port A data = 0, all inputs
        $03C2  B7 00          sta PORTA                     ; clear Port C outputs
        $03C4  B7 02          sta PORTC
        $03C6  B7 04          sta DDRA                      ; DDRA = 0: Port A all inputs
        $03C8  A6 0C          lda #$0C                      ; DDRC = $0C: PC2,PC3 output; PC0,PC1 input
        $03CA  B7 06          sta DDRC
        $03CC  A6 40          lda #$40                      ; PB6 high = IRQ deasserted (active low)
        $03CE  B7 01          sta PORTB                     ; PORTB = $40
        $03D0  B7 05          sta DDRB                      ; DDRB = $40: PB6 output
        $03D2  C6 06 C7       lda ROM_TIMER_NEG_DT_HI       ; load timer constants from ROM data area
        $03D5  B7 51          sta TIMER_NEG_DT_HI
        $03D7  C6 06 C9       lda ROM_TIMER_NEG_DT_LO
        $03DA  B7 50          sta TIMER_NEG_DT_LO
        $03DC  C6 06 C3       lda ROM_SEED_HI
        $03DF  B7 53          sta SEED_HI
        $03E1  C6 06 C5       lda ROM_SEED_LO
        $03E4  B7 52          sta SEED_LO
        $03E6  A6 01          lda #$01
        $03E8  B7 57          sta FRAMES_PER_IRQ
        $03EA  A6 00          lda #$00
        $03EC  B7 54          sta SEED_DELTA_LO
        $03EE  B7 55          sta SEED_DELTA_HI
        $03F0  CC 04 F9       jmp INIT_RAM                  ; jump to INIT_RAM (full reset initialisation)

; ------------------------------------------------------------
; CMD_LOOP — main command receive and dispatch loop
; ------------------------------------------------------------

CMD_LOOP:
        $03F3  03 02 0D       brclr 1, PORTC,STATE_CHECK    ; wait for Apple II to assert PC1 (command ready)
        $03F6  CD 00 83       jsr RECV_BYTE_skip            ; receive command byte (skip wait, PC1 already set)
        $03F9  B7 59          sta CMD_BYTE                  ; save command byte
        $03FB  44             lsra                          ; decode: (cmd >> 2) & $3C -> X = table index
        $03FC  44             lsra
        $03FD  A4 3C          and #$3C
        $03FF  97             tax                           ; X = dispatch index
        $0400  DC 00 9E       jmp DISPATCH_TABLE,X

; ------------------------------------------------------------
; STATE_CHECK — detect Port B change, decode quadrature
; Loops over X_reg=1 (Y axis) then X_reg=0 (X axis)
; ------------------------------------------------------------

STATE_CHECK:
        $0403  B6 01          lda PORTB                     ; read Port B
        $0405  A4 0F          and #$0F                      ; keep low nibble (quadrature + button bits)
        $0407  B8 44          eor PORT_STATE                ; XOR with saved state: non-zero = state changed
        $0409  27 E8          beq CMD_LOOP                  ; no change: wait for next command
        $040B  01 58 5B       brclr 0, MOUSE_MODE,$0469     ; mouse off (mode bit 0 = 0) -> skip decode
        $040E  B7 45          sta NEW_STATE                 ; save XOR-diff = changed bits
        $0410  B8 44          eor PORT_STATE                ; A = diff XOR old = new state
        $0412  B7 44          sta PORT_STATE                ; update saved Port B state
        $0414  01 5D 08       brclr 0, MOUSE_OPTIONS,$041F  ; bit 0 clear? -> keep both edges (full res)
                                                            ;   set? fall through to rising-edge-only filter:
        $0417  A4 0A          and #$0A                      ; A = new level & clock mask (X0=PB1, Y1=PB3)
        $0419  B4 45          and NEW_STATE                 ; & changed bits -> clock bits high AND changed
        $041B  27 4C          beq $0469                     ;   = clock RISING edges; none -> skip (no count)
        $041D  B7 45          sta NEW_STATE                 ; NEW_STATE = clock rising edges only (IIc-style)
        $041F  A6 20          lda #$20
        $0421  B7 5A          sta MOVED_STATUS
        $0423  A6 02          lda #$02
        $0425  B7 5B          sta MOUSE_MOVED
        $0427  AE 01          ldx #$01                      ; loop: X=1->Y axis, X=0->X axis

QUAD_DECODE_loop:
        $0429  B6 45          lda NEW_STATE                 ; CHANGED_BITS
        $042B  D4 00 9A       and QUAD_MASKS,X              ; clock mask: X0=$02 (X) or Y1=$08 (Y)
        $042E  27 36          beq $0466                     ; this axis clock bit unchanged: skip axis
        $0430  B6 44          lda PORT_STATE                ; NEW PORT_STATE
        $0432  D4 00 9C       and QUAD_MASKS+2,X            ; direction mask: X1=$01 (X) or Y0=$04 (Y)
        $0435  27 18          beq QUAD_dec_path             ; direction line was 0: decrement
        $0437  E6 42          lda XLO,X
        $0439  E1 4D          cmp XMAX_LO,X
        $043B  26 09          bne $0446
        $043D  E6 40          lda XHI,X
        $043F  E1 4B          cmp XMAX_HI,X
        $0441  26 03          bne $0446
        $0443  CC 04 4C       jmp QUAD_DONE_inc
        $0446  6C 42          inc XLO,X
        $0448  26 02          bne QUAD_DONE_inc
        $044A  6C 40          inc XHI,X

QUAD_DONE_inc:
        $044C  CC 04 66       jmp $0466

QUAD_dec_path:
        $044F  E6 42          lda XLO,X
        $0451  E1 49          cmp XMIN_LO,X
        $0453  26 09          bne $045E
        $0455  E6 40          lda XHI,X
        $0457  E1 47          cmp XMIN_HI,X
        $0459  26 03          bne $045E
        $045B  CC 04 66       jmp $0466
        $045E  E6 42          lda XLO,X
        $0460  26 02          bne $0464
        $0462  6A 40          dec XHI,X
        $0464  6A 42          dec XLO,X
        $0466  5A             decx
        $0467  27 C0          beq QUAD_DECODE_loop
        $0469  CC 03 F3       jmp CMD_LOOP

; ------------------------------------------------------------
; CMD_SETMOUSE ($00) — SetMouse: store the mode byte into MOUSE_MODE
; ------------------------------------------------------------

CMD_SETMOUSE:
        $046C  B6 59          lda CMD_BYTE                  ; mode byte from Apple II
        $046E  B7 58          sta MOUSE_MODE
        $0470  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_READMOUSE — send XLO,XHI,YLO,YHI,STATUS to Apple II
; Status byte = (BUTTON_STATUS & $C0) | MOVED_STATUS
; If MOUSE_OPTIONS bit 1 set: zero position after read
; ------------------------------------------------------------

CMD_READMOUSE:
        $0473  A6 FF          lda #$FF
        $0475  B7 04          sta DDRA
        $0477  B6 42          lda XLO
        $0479  00 02 FD       brset 0, PORTC,*
        $047C  B7 00          sta PORTA
        $047E  14 02          bset 2, PORTC
        $0480  01 02 FD       brclr 0, PORTC,*
        $0483  15 02          bclr 2, PORTC
        $0485  B6 40          lda XHI
        $0487  00 02 FD       brset 0, PORTC,*
        $048A  B7 00          sta PORTA
        $048C  14 02          bset 2, PORTC
        $048E  01 02 FD       brclr 0, PORTC,*
        $0491  15 02          bclr 2, PORTC
        $0493  B6 43          lda YLO
        $0495  00 02 FD       brset 0, PORTC,*
        $0498  B7 00          sta PORTA
        $049A  14 02          bset 2, PORTC
        $049C  01 02 FD       brclr 0, PORTC,*
        $049F  15 02          bclr 2, PORTC
        $04A1  B6 41          lda YHI
        $04A3  00 02 FD       brset 0, PORTC,*
        $04A6  B7 00          sta PORTA
        $04A8  14 02          bset 2, PORTC
        $04AA  01 02 FD       brclr 0, PORTC,*
        $04AD  15 02          bclr 2, PORTC
        $04AF  B6 01          lda PORTB
        $04B1  A8 80          eor #$80                      ; button is active low, invert
        $04B3  48             lsla
        $04B4  36 46          ror BUTTON_STATUS             ; shift current -> prev
        $04B6  B6 46          lda BUTTON_STATUS
        $04B8  A4 C0          and #$C0
        $04BA  BA 5A          ora MOVED_STATUS
        $04BC  00 02 FD       brset 0, PORTC,*
        $04BF  B7 00          sta PORTA
        $04C1  14 02          bset 2, PORTC
        $04C3  01 02 FD       brclr 0, PORTC,*
        $04C6  15 02          bclr 2, PORTC
        $04C8  A6 00          lda #$00
        $04CA  B7 5A          sta MOVED_STATUS
        $04CC  B7 04          sta DDRA
        $04CE  03 5D 08       brclr 1, MOUSE_OPTIONS,$04D9  ; bit 1 set? -> zero XHI/XLO/YHI/YLO
        $04D1  B7 40          sta XHI
        $04D3  B7 42          sta XLO
        $04D5  B7 41          sta YHI
        $04D7  B7 43          sta YLO
        $04D9  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_SERVEMOUSE — send INT_STATUS ($5C) to Apple II; clear it
; ------------------------------------------------------------

CMD_SERVEMOUSE:
        $04DC  1C 01          bset 6, PORTB
        $04DE  A6 FF          lda #$FF
        $04E0  B7 04          sta DDRA
        $04E2  B6 5C          lda INT_STATUS
        $04E4  00 02 FD       brset 0, PORTC,*
        $04E7  B7 00          sta PORTA
        $04E9  14 02          bset 2, PORTC
        $04EB  01 02 FD       brclr 0, PORTC,*
        $04EE  15 02          bclr 2, PORTC
        $04F0  A6 00          lda #$00
        $04F2  B7 5C          sta INT_STATUS
        $04F4  B7 04          sta DDRA
        $04F6  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; INIT_RAM — zero all RAM; called from RESET
; INIT_RAM2 — subset reinit; called from CMD_INITMOUSE
; INIT_RAM3 — subset reinit; called from CMD_TRANSPARENT
; ------------------------------------------------------------

INIT_RAM:
        $04F9  B7 5B          sta MOUSE_MOVED
        $04FB  B7 5C          sta INT_STATUS

INIT_RAM2:
        $04FD  B7 58          sta MOUSE_MODE

INIT_RAM3:
        $04FF  B7 5D          sta MOUSE_OPTIONS             ; clear options (full res, no clear-on-read)
        $0501  B7 47          sta XMIN_HI
        $0503  B7 49          sta XMIN_LO
        $0505  B7 48          sta YMIN_HI
        $0507  B7 4A          sta YMIN_LO
        $0509  A6 03          lda #$03
        $050B  B7 4B          sta XMAX_HI
        $050D  B7 4C          sta YMAX_HI
        $050F  A6 FF          lda #$FF
        $0511  B7 4D          sta XMAX_LO
        $0513  B7 4E          sta YMAX_LO
        $0515  B6 01          lda PORTB
        $0517  A4 0F          and #$0F
        $0519  B7 44          sta PORT_STATE

CMD_CLEARMOUSE:
        $051B  A6 00          lda #$00
        $051D  B7 46          sta BUTTON_STATUS
        $051F  B7 5A          sta MOVED_STATUS
        $0521  B7 40          sta XHI
        $0523  B7 42          sta XLO
        $0525  B7 41          sta YHI
        $0527  B7 43          sta YLO
        $0529  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_POSMOUSE — receive XLO,XHI,YLO,YHI from Apple II; set mouse position
; ------------------------------------------------------------

CMD_POSMOUSE:
        $052C  CD 00 80       jsr RECV_BYTE
        $052F  B7 42          sta XLO
        $0531  CD 00 80       jsr RECV_BYTE
        $0534  B7 40          sta XHI
        $0536  CD 00 80       jsr RECV_BYTE
        $0539  B7 43          sta YLO
        $053B  CD 00 80       jsr RECV_BYTE
        $053E  B7 41          sta YHI
        $0540  A6 00          lda #$00
        $0542  B7 5A          sta MOVED_STATUS
        $0544  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_INITMOUSE — disable IRQ; reset tick counter and timer;
;            send $00 ACK; receive one byte; JMP INIT_RAM2
; ------------------------------------------------------------

CMD_INITMOUSE:
        $0547  9B             sei
        $0548  1D 09          bclr 6, TCR
        $054A  B6 57          lda FRAMES_PER_IRQ
        $054C  B7 56          sta FRAME_COUNTER
        $054E  B6 53          lda SEED_HI
        $0550  4C             inca
        $0551  B7 4F          sta TIMER_HI
        $0553  A6 00          lda #$00
        $0555  B7 5B          sta MOUSE_MOVED
        $0557  B7 5C          sta INT_STATUS
        $0559  1C 01          bset 6, PORTB
        $055B  CD 00 8D       jsr SEND_BYTE
        $055E  03 02 FD       brclr 1, PORTC,*
        $0561  A6 FF          lda #$FF
        $0563  B7 08          sta TIMER
        $0565  1F 09          bclr 7, TCR
        $0567  9A             cli
        $0568  B6 52          lda SEED_LO
        $056A  B7 08          sta TIMER
        $056C  CD 00 83       jsr RECV_BYTE_skip
        $056F  A6 00          lda #$00
        $0571  CC 04 FD       jmp INIT_RAM2

; ------------------------------------------------------------
; CMD_CLAMPMOUSE — receive 4 bytes for X or Y clamp (bit 0 of cmd)
; Byte order: XMIN_LO/YMIN_LO, XMAX_LO/YMAX_LO,
;             XMIN_HI/YMIN_HI, XMAX_HI/YMAX_HI
; ------------------------------------------------------------

CMD_CLAMPMOUSE:
        $0574  B6 59          lda CMD_BYTE
        $0576  A4 01          and #$01
        $0578  97             tax
        $0579  CD 00 80       jsr RECV_BYTE
        $057C  E7 49          sta XMIN_LO,X
        $057E  CD 00 80       jsr RECV_BYTE
        $0581  E7 4D          sta XMAX_LO,X
        $0583  CD 00 80       jsr RECV_BYTE
        $0586  E7 47          sta XMIN_HI,X
        $0588  CD 00 80       jsr RECV_BYTE
        $058B  E7 4B          sta XMAX_HI,X
        $058D  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_HOMEMOUSE — set position to clamp-minimum (home = XMIN,YMIN)
; ------------------------------------------------------------

CMD_HOMEMOUSE:
        $0590  B6 49          lda XMIN_LO
        $0592  B7 42          sta XLO
        $0594  B6 47          lda XMIN_HI
        $0596  B7 40          sta XHI
        $0598  B6 4A          lda YMIN_LO
        $059A  B7 43          sta YLO
        $059C  B6 48          lda YMIN_HI
        $059E  B7 41          sta YHI
        $05A0  A6 00          lda #$00
        $05A2  B7 5A          sta MOVED_STATUS
        $05A4  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_TRANSPARENT ($80) — set "transparent" mode (IIc tech ref): turn
; mouse on with interrupts off (MOUSE_MODE = $01), and reinitialize state
; (options, clamp bounds -> default 0..$03FF, position) via INIT_RAM3.
; ------------------------------------------------------------

CMD_TRANSPARENT:
        $05A7  A6 01          lda #$01
        $05A9  B7 58          sta MOUSE_MODE
        $05AB  A6 00          lda #$00
        $05AD  CC 04 FF       jmp INIT_RAM3

; ------------------------------------------------------------
; CMD_TIMEDATA ($90) — set the VBL interrupt rate
;
; cmd bit 0: 0 = 60 Hz, 1 = 50 Hz
; cmd bit 1: if set, add ROM_SEED_ADJ to SEED
; cmd bit 2: if set, receive 2 bytes = 16-bit signed delta added to SEED
; cmd bit 3: if set, receive FRAMES_PER_IRQ (fire IRQ once every N frames);
;            else FRAMES_PER_IRQ = 1 (every frame)
;
; CMD_INITMOUSE initializes TIMER_HI:TIMER with SEED_HI:LO for the first countdown,
; after that the ISR uses TIMER_NEG_DT from then on.
; ------------------------------------------------------------

CMD_TIMEDATA:
        $05B0  1C 09          bset 6, TCR
        $05B2  B6 59          lda CMD_BYTE
        $05B4  A4 01          and #$01
        $05B6  97             tax
        $05B7  D6 06 C5       lda ROM_SEED_LO,X
        $05BA  B7 52          sta SEED_LO
        $05BC  D6 06 C3       lda ROM_SEED_HI,X
        $05BF  B7 53          sta SEED_HI
        $05C1  D6 06 C9       lda ROM_TIMER_NEG_DT_LO,X
        $05C4  B7 50          sta TIMER_NEG_DT_LO
        $05C6  D6 06 C7       lda ROM_TIMER_NEG_DT_HI,X
        $05C9  B7 51          sta TIMER_NEG_DT_HI
        $05CB  B6 59          lda CMD_BYTE
        $05CD  A4 04          and #$04
        $05CF  27 18          beq $05E9
        $05D1  CD 00 80       jsr RECV_BYTE
        $05D4  B7 54          sta SEED_DELTA_LO
        $05D6  CD 00 80       jsr RECV_BYTE
        $05D9  B7 55          sta SEED_DELTA_HI
        $05DB  B6 52          lda SEED_LO
        $05DD  BB 54          add SEED_DELTA_LO
        $05DF  B7 52          sta SEED_LO
        $05E1  B6 53          lda SEED_HI
        $05E3  B9 55          adc SEED_DELTA_HI
        $05E5  B7 53          sta SEED_HI
        $05E7  20 06          bra $05EF
        $05E9  A6 00          lda #$00
        $05EB  B7 54          sta SEED_DELTA_LO
        $05ED  B7 55          sta SEED_DELTA_HI
        $05EF  B6 59          lda CMD_BYTE
        $05F1  A4 02          and #$02
        $05F3  27 0E          beq $0603
        $05F5  B6 52          lda SEED_LO
        $05F7  CB 06 C2       add ROM_SEED_ADJ_LO
        $05FA  B7 52          sta SEED_LO
        $05FC  B6 53          lda SEED_HI
        $05FE  C9 06 C1       adc ROM_SEED_ADJ_HI
        $0601  B7 53          sta SEED_HI
        $0603  B6 59          lda CMD_BYTE
        $0605  A4 08          and #$08
        $0607  27 07          beq $0610
        $0609  CD 00 80       jsr RECV_BYTE
        $060C  B7 57          sta FRAMES_PER_IRQ
        $060E  20 04          bra $0614
        $0610  A6 01          lda #$01
        $0612  B7 57          sta FRAMES_PER_IRQ
        $0614  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_SETVBLCNTS ($A0) — receive 1 byte -> FRAMES_PER_IRQ (fire IRQ every N frames)
; ------------------------------------------------------------

CMD_SETVBLCNTS:
        $0617  CD 00 80       jsr RECV_BYTE
        $061A  B7 57          sta FRAMES_PER_IRQ
        $061C  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_OPTMOUSE — store CMD_BYTE -> MOUSE_OPTIONS ($5D)
;   bit 0 = half resolution (count clock rising edges only, like the IIc)
;   bit 1 = clear-on-read   (zero mouse position after CMD_READMOUSE)
; ------------------------------------------------------------

CMD_OPTMOUSE:
        $061F  B6 59          lda CMD_BYTE
        $0621  B7 5D          sta MOUSE_OPTIONS
        $0623  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_STARTTIMER ($C0) — acknowledge the mouse interrupt: clear pending status
; (MOUSE_MOVED and INT_STATUS), deassert the IRQ (PB6 high), reload FRAME_COUNTER,
; and ought to restart the frame timer, but due to a bug it only
; sets the low 8 bits of TIMER.
; ------------------------------------------------------------

CMD_STARTTIMER:
        $0626  9B             sei
        $0627  1D 09          bclr 6, TCR
        $0629  A6 00          lda #$00
        $062B  B7 5B          sta MOUSE_MOVED
        $062D  B7 5C          sta INT_STATUS
        $062F  1C 01          bset 6, PORTB
        $0631  B6 57          lda FRAMES_PER_IRQ
        $0633  B7 56          sta FRAME_COUNTER
        $0635  B6 55          lda SEED_DELTA_HI
        $0637  4C             inca
        $0638  B7 08          sta TIMER                     ; /!\ bug, should be TIMER_HI
        $063A  A6 FF          lda #$FF
        $063C  B7 08          sta TIMER
        $063E  1F 09          bclr 7, TCR
        $0640  9A             cli
        $0641  B6 54          lda SEED_DELTA_LO
        $0643  B7 08          sta TIMER
        $0645  CC 04 03       jmp STATE_CHECK

; ------------------------------------------------------------
; CMD_DIAGMOUSE ($F0) — generalised MCU memory read/write
; Receives hi,lo address bytes from Apple II;
; bit 0 of cmd = 0: builds LDA in RAM, executes, sends result
; bit 0 of cmd = 1: receives a byte, builds STA in RAM, writes it
; ------------------------------------------------------------

CMD_DIAGMOUSE:
        $0648  CD 00 80       jsr RECV_BYTE                 ; receive address LO byte (Apple II sends little-endian)
        $064B  B7 60          sta DIAG_ADDR_LO              ; save -> DIAG_ADDR_LO ($60 = ext instruction addr_lo field)
        $064D  CD 00 80       jsr RECV_BYTE                 ; receive address HI byte
        $0650  B7 5F          sta DIAG_ADDR_HI              ; save -> DIAG_ADDR_HI ($5F = ext instruction addr_hi field)
        $0652  A6 81          lda #$81                      ; $81 = RTS opcode; terminates the DIAG_amic subroutine
        $0654  B7 61          sta DIAG_ARG                  ; write RTS into DIAG_ARG ($61, after the 3-byte ext instr)
        $0656  B6 59          lda CMD_BYTE                  ; test bit 0: 0=read, 1=write
        $0658  A4 01          and #$01
        $065A  26 12          bne $066E                     ; bit 0 = 1 (write): build STA ext in buffer
        $065C  A6 FF          lda #$FF                      ; bit 0 = 0 (read): set DDRA=$FF (Port A all outputs)
        $065E  B7 04          sta DDRA
        $0660  A6 C6          lda #$C6                      ; LDA ext opcode $C6 -> DIAG_INSTR, then call JSR DIAG_INSTR
        $0662  B7 5E          sta DIAG_INSTR
        $0664  BD 5E          jsr DIAG_INSTR                ; execute: JSR DIAG_INSTR -> LDA (DIAG_ADDR_HI:DIAG_ADDR_LO)
        $0666  CD 00 8D       jsr SEND_BYTE                 ; send loaded byte to Apple II
        $0669  3F 04          clr DDRA                      ; CLR DDRA: Port A back to inputs
        $066B  CC 04 03       jmp STATE_CHECK
        $066E  A6 C7          lda #$C7                      ; STA ext opcode = $C7
        $0670  B7 5E          sta DIAG_INSTR
        $0672  CD 00 80       jsr RECV_BYTE                 ; receive byte to write
        $0675  BD 5E          jsr DIAG_INSTR                ; JSR DIAG_INSTR -> STA (DIAG_ADDR_HI:DIAG_ADDR_LO)
        $0677  CC 04 03       jmp STATE_CHECK

CMD_NOP:
        $067A  CC 04 03       jmp STATE_CHECK

; ════════════════════════════════════════════════════════════
; TIMER_ISR — fires when TIMER (Timer Data Register) decrements to 0, which sets
;             TIR (Timer Interrupt Request, bit 7 of TCR). TIMER then wraps $00->$FF
;             and keeps counting, so consecutive zeros are 256 ticks apart.
; Maintains the frame timer; every FRAMES_PER_IRQ frames:
;   reads button state, builds the interrupt-condition status, asserts the
;   Apple II IRQ if an enabled condition occurred, accumulates INT_STATUS
; ════════════════════════════════════════════════════════════


TIMER_ISR:
        $067D  1F 09          bclr 7, TCR                   ; clear TIR (timer interrupt request, bit 7)
        $067F  3A 4F          dec TIMER_HI                  ; count down one 256-tick chunk

        ; The check for zero happens AFTER the dec above, so the reload fires
        ; when TIMER counts down to $100, not $00. Therefore the very first reload
        ; after the timer is seeded is 256 ticks early. From then on the
        ; reload ADDS to the live counter (see below) instead of restarting
        ; it from a constant, so every period after the first counts the full delta.

        $0681  26 3C          bne TIMER_ISR_rti             ; not end of period yet: just RTI

        ; We want to update the timer so it stays perfectly in sync with the VBL, i.e.
        ; so it fires with a consistent, drift free, delay of exactly the number of
        ; ticks per video frame. Let TIMER_DT be the number to add to the timer.
        ;
        ; Hmm, the code does `inca TIMER_HI`, which could have simply been folded
        ; in to TIMER_DT. Deduct 256 from TIMER_DT to compensate for that.
        ;
        ; There are 10 ticks that elapse between the `lda TIMER` and `sta TIMER`,
        ; those have to be deducted from TIMER_DT.
        ;
        ; Combining the above two factors, we end up with the formula
        ;    TIMER_DT = ticks/frame - 266
        ;
        ; Hmm, the code uses subtraction instead of addition! No problem, add x
        ; by subtracting -x. Let TIMER_NEG_DT be a signed 16 bit value, where
        ;    TIMER_NEG_DT = -TIMER_DT = 266 - ticks/frame

        ; Subtracting from the running counter, not reloading it with a constant,
        ; is what makes the timer drift free no matter what the interrupt latency is.

        $0683  B6 08          lda TIMER                     ; TIMER -= TIMER_NEG_DT_LO (preserve TIMER's phase)
        $0685  B0 50          sub TIMER_NEG_DT_LO
        $0687  B7 08          sta TIMER                     ; 10 cycles between lda and sta
        $0689  B6 4F          lda TIMER_HI
        $068B  B2 51          sbc TIMER_NEG_DT_HI
        $068D  4C             inca                          ; +$100 why ?? could have been folded into TIMER_NEG_DT
        $068E  B7 4F          sta TIMER_HI
        $0690  3A 56          dec FRAME_COUNTER             ; one frame elapsed; count down to next IRQ
        $0692  26 2B          bne TIMER_ISR_rti             ; not the Nth frame yet: RTI
        $0694  B6 57          lda FRAMES_PER_IRQ            ; Nth frame: reload the frame counter
        $0696  B7 56          sta FRAME_COUNTER
        ; build interrupt-condition status (bit1=move, bit2=button, bit3=VBL)
        $0698  B6 01          lda PORTB                     ; read button (PB7: 0 = pressed)
        $069A  2B 04          bmi $06A0                     ; bit 7 set = button up -> $06A0
        $069C  A6 0C          lda #$0C                      ; button down: VBL + button (bits 3,2)
        $069E  20 04          bra $06A4
        $06A0  A6 08          lda #$08                      ; button up: VBL only (bit 3)
        $06A2  20 00          bra $06A4                     ; (branch to next instr, 2-byte NOP)
        $06A4  BA 5B          ora MOUSE_MOVED               ; add movement bit (set in STATE_CHECK on move)
        ; raise Apple II IRQ if an ENABLED interrupt condition is present
        $06A6  00 58 04       brset 0, MOUSE_MODE,$06AD     ; mouse on? -> consider move/btn/VBL
        $06A9  A4 08          and #$08                      ; mouse off: consider VBL only (bit 3)
        $06AB  20 04          bra $06B1
        $06AD  A4 0E          and #$0E                      ; mouse on: consider move/btn/VBL (bits 1-3)
        $06AF  20 00          bra $06B1                     ; (branch to next instr, 2-byte NOP)
        $06B1  B4 58          and MOUSE_MODE                ; mask vs mode IRQ-enable bits (b1 move,b2 btn,b3 VBL)
        $06B3  27 02          beq $06B7                     ; nothing enabled occurred -> no interrupt
        $06B5  1D 01          bclr 6, PORTB                 ; assert Apple II IRQ (PB6 low, active-low)
        $06B7  BA 5C          ora INT_STATUS                ; accumulate status into INT_STATUS (sent by ServeMouse)
        $06B9  B7 5C          sta INT_STATUS
        $06BB  A6 00          lda #$00                      ; clear movement flag (consumed)
        $06BD  B7 5B          sta MOUSE_MOVED

TIMER_ISR_rti:
        $06BF  80             rti

; INT_ISR — external interrupt: ignored (RTI immediately)

INT_ISR:
        $06C0  80             rti

; ------------------------------------------------------------
; ROM constants for the VBL timer.
;
; ROM_SEED_HI/LO and ROM_TIMER_NEG_DT_HI/LO are [60 Hz, 50 Hz] pairs.
; RESET initalizes SEED_HI/LO and TIMER_NEG_DT_HI/LO to the 60 Hz values.
; The 50 Hz values can be set using CMD_TIMEDATA.
;
; As 16-bit HI:LO values:      60 Hz    50 Hz
;   ROM_SEED                 $41A2    $4E4E    (initial timer value loaded in CMD_INITMOUSE)
;   ROM_TIMER_NEG_DT         $DFC7    $D96E    (a negative number, the ISR subtracts it)
;
; Derivation of ROM_TIMER_NEG_DT:
;
;   1. An Apple II video frame is 17030 clock cycles at 60 Hz; and 20280 cycles at 50 Hz.
;   2. The MCU is clocked from Q3, pin 37 on the slot connector. Q3 is the Apple II 2 MHz
;      asymmetric clock. The MCU divides its clock input by 4, so the MCU (and timer) ticks
;      at half the Apple II clock rate.
;   3. So there are 17030/2 = 8515 timer ticks/frame at 60 Hz, and 20280/2 = 10140 at 50 Hz
;   3. TIMER_NEG_DT = 266 - ticks/frame (see TIMER_ISR code)
;   4. ROM_TIMER_NEG_DT = 266 -  8515 = -8249 = $DFC7 at 60 Hz
;                       = 266 - 10140 = -9874 = $D96E at 50 Hz
; ------------------------------------------------------------

ROM_SEED_ADJ_HI:
        $06C1  FC             .byte $FC   ; \ $FC8E = -882, signed SEED offset
ROM_SEED_ADJ_LO:
        $06C2  8E             .byte $8E   ; / (CMD_TIMEDATA bit 1)
ROM_SEED_HI:
        $06C3  41             .byte $41   ; [60 Hz]
        $06C4  4E             .byte $4E   ; [50 Hz]
ROM_SEED_LO:
        $06C5  A2             .byte $A2   ; [60 Hz]
        $06C6  4E             .byte $4E   ; [50 Hz]
ROM_TIMER_NEG_DT_HI:
        $06C7  DF             .byte $DF   ; [60 Hz]
        $06C8  D9             .byte $D9   ; [50 Hz]
ROM_TIMER_NEG_DT_LO:
        $06C9  C7             .byte $C7   ; [60 Hz]
        $06CA  6E             .byte $6E   ; [50 Hz]

; $06CB–$0716: unused EPROM (all $00)
        .res  $0717-$06CB, $00          ; $06CB-$0716  unused, $00

; ------------------------------------------------------------
; Copyright string
; ------------------------------------------------------------

COPYRIGHT:
        $0717  41 50 50 4C 45 4D 4F 55    .byte $41,$50,$50,$4C,$45,$4D,$4F,$55  ; |APPLEMOU|
        $071F  53 45 8D 43 4F 50 59 52    .byte $53,$45,$8D,$43,$4F,$50,$59,$52  ; |SE.COPYR|
        $0727  49 47 48 54 20 31 39 38    .byte $49,$47,$48,$54,$20,$31,$39,$38  ; |IGHT 198|
        $072F  33 20 42 59 20 41 50 50    .byte $33,$20,$42,$59,$20,$41,$50,$50  ; |3 BY APP|
        $0737  4C 45 20 43 4F 4D 50 55    .byte $4C,$45,$20,$43,$4F,$4D,$50,$55  ; |LE COMPU|
        $073F  54 45 52 2C 20 49 4E 43    .byte $54,$45,$52,$2C,$20,$49,$4E,$43  ; |TER, INC|
        $0747  2E 8D 41 4C 4C 20 52 49    .byte $2E,$8D,$41,$4C,$4C,$20,$52,$49  ; |..ALL RI|
        $074F  47 48 54 53 20 52 45 53    .byte $47,$48,$54,$53,$20,$52,$45,$53  ; |GHTS RES|
        $0757  45 52 56 45 44 8D 4D 41    .byte $45,$52,$56,$45,$44,$8D,$4D,$41  ; |ERVED.MA|
        $075F  52 4B 53 2F 4D 41 43 44    .byte $52,$4B,$53,$2F,$4D,$41,$43,$44  ; |RKS/MACD|
        $0767  4F 55 47 41 4C 4C 2F 4D    .byte $4F,$55,$47,$41,$4C,$4C,$2F,$4D  ; |OUGALL/M|
        $076F  41 43 4B 41 59 2F 42 41    .byte $41,$43,$4B,$41,$59,$2F,$42,$41  ; |ACKAY/BA|
        $0777  43 48 4D 41 4E 8D          .byte $43,$48,$4D,$41,$4E,$8D          ; |CHMAN.|

        .res  $0784-$077D, $00          ; $077D-$0783  unused, $00

        $0784  40             .byte $40     ; Mask Option Register $40 = crystal/external clock

        .res  $07F8-$0785, $00          ; $0785-$07F7  bootstrap area, dumped $00

; ════════════════════════════════════════════════════════════
; Interrupt vector table (big-endian .word)
; ════════════════════════════════════════════════════════════

        .org $07F8

VEC_TIMER:
        $07F8  06 7D          .word TIMER_ISR
VEC_INT:
        $07FA  06 C0          .word INT_ISR
VEC_SWI:
        $07FC  06 C0          .word INT_ISR
VEC_RESET:
        $07FE  03 C0          .word RESET
