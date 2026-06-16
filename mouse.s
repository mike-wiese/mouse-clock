; ============================================================
; Apple II Mouse Interface Card ROM  341-0270-c.4b
; Disassembly by Mike Wiese
; 2026-06-16
; ============================================================
;
; How the card works
; -------------------
; Two processors are involved: the Apple II's own 6502 (running this slot
; ROM), and an MC68705 MCU on the card (see mcu.s) that does the actual
; mouse tracking. A 6821 PIA on the card bridges them: Port A is a
; bidirectional data bus to the MCU; Port B selects the active ROM bank
; and carries the REQ/ACK handshakes. The 2KB ROM is 8 banks of 256 bytes,
; paged into $Cn00-$CnFF by Port B bits 1-3.
;
; This firmware exposes the standard mouse calls (SetMouse, ReadMouse,
; ServeMouse, ...) and the PR#n / IN#n hooks. Each call becomes a
; one-byte command (plus any parameters) sent to the MCU over the PIA;
; position, button, and status are read back the same way. The MCU
; decodes the quadrature encoders and button, clamps the X/Y position,
; and raises VBL-synced interrupts.

; ============================================================
; Screen hole usage
; ============================================================
; The firmware uses screen holes to pass parameters to and from the card.

; Scratch area
CLAMP_MIN_LO    = $0478         ; lo byte of clamping minimum
CLAMP_MAX_LO    = $04F8         ; lo byte of clamping maximum
CLAMP_MIN_HI    = $0578         ; hi byte of clamping minimum
CLAMP_MAX_HI    = $05F8         ; hi byte of clamping maximum

; Slot #n screen holes at address,X where X = slot $Cn
MOUSE_XLO       = $0478-$C0     ; + $Cn   X coord lo
MOUSE_YLO       = $04F8-$C0     ; + $Cn   Y coord lo
MOUSE_XHI       = $0578-$C0     ; + $Cn   X coord hi
MOUSE_YHI       = $05F8-$C0     ; + $Cn   Y coord hi
ROM_BANK        = $0678-$C0     ; + $Cn   bank select
MOUSE_CMD       = $06F8-$C0     ; + $Cn   command/temp byte
MOUSE_STATUS    = $0778-$C0     ; + $Cn   status byte
MOUSE_MODE      = $07F8-$C0     ; + $Cn   mode byte

; MOUSE_STATUS byte:
;   bit 7  Button is up (0) or down (1)
;   bit 6  Button was up (0) or down (1) on last READMOUSE
;   bit 5  X/Y moved since last READMOUSE
;   bit 4  Reserved
;   bit 3  VBL interrupt
;   bit 2  Button interrupt
;   bit 1  Movement interrupt
;   bit 0  Reserved
;
; MOUSE_MODE byte:
;   bit 7  Reserved
;   bit 6  Reserved
;   bit 5  Reserved
;   bit 4  Reserved
;   bit 3  Interrupt on VBL
;   bit 2  Interrupt if button is pressed
;   bit 1  Interrupt if mouse is moved
;   bit 0  Mouse is off (0) or on (1)

MOUSE_ENABLED   = 1<<0          ; mouse mode bit 0 mask: mouse is on aka active

; ============================================================
; ROM layout
; ============================================================
;
; The 2KB ROM is divided into 8 banks of 256 bytes each.
; The active bank is mapped to the slot ROM area at $Cn00-$CnFF.
; The active bank is selected by PIA Port B bits 1-3.
;
; Bank switching
; --------------
; Every bank has a bank switch sequence at offset $70.
; The first instruction after switching to a new bank is at offset $7B.
; Landing roughly in the middle of the bank means every location
; in the bank is within reach of a single 6502 branch instruction.
;
; RTS jump
; --------
; Control is threaded between banks (and routines) with the 6502 "RTS jump"
; technique: push a target address hi byte then lo byte as if it were a return
; address, and a later RTS pops it and jumps there. The pushed lo byte is
; (target-1) because RTS increments the popped address. The RTS that does
; the jump is often done just after a bank switch.

; ============================================================
; 6821 Peripheral Interface Adapter
; ============================================================
; The PIA has two 8 bit ports, with three registers each:
;
; PIA Port A
;   Control Register A (CRA)          controls the operation of port A
;   Peripheral Register A (PA)        data I/O on PA pins
;   Data Direction Register A (DDRA)  configures each pin of PA as an input (0) or an output (1)
;
; PIA Port B
;   Control Register B (CRB)          controls the operation of port B
;   Peripheral Register B (PB)        data I/O on PB pins
;   Data Direction Register B (DDRB)  configures each pin of PB as an input (0) or an output (1)
;
; Peripheral Register behavior:
;   writes drive output pins
;   reads return the current pin state (input pins) or the last value written (output pins)
;
; PIA registers are at $C08x,Y where Y = slot * $10
;
; Six registers share only four addresses ($C080-$C083): the select pins RS0/RS1 
; (wired to A0/A1) choose the address, and Control Register bit 2 then selects
; the Data Direction Register (CR2=0) or Peripheral Register (CR2=1).
;
;                Address,Y         RS1  RS0  CRA2  CRB2  Register
;                ---------         ---  ---  ----  ----  --------
PIA_DDRA        = $C080         ;    0    0     0     *   Data Direction Register A
PIA_PA          = $C080         ;    0    0     1     *   Peripheral Register A
PIA_CRA         = $C081         ;    0    1     *     *   Control Register A
PIA_DDRB        = $C082         ;    1    0     *     0   Data Direction Register B
PIA_PB          = $C082         ;    1    0     *     1   Peripheral Register B
PIA_CRB         = $C083         ;    1    1     *     *   Control Register B

; PIA Port A:
; All 8 bits connected to 68705 MCU Port A
;
; PIA Port B connections:
;   bit 7  in   68705 PC3   WRITE_ACK  MCU asserts to ACK data from Apple II
;   bit 6  in   68705 PC2   READ_REQ   MCU asserts when data is ready for Apple II
;   bit 5  out  68705 PC1   WRITE_REQ  Apple II asserts when data is ready for MCU
;   bit 4  out  68705 PC0   READ_ACK   Apple II asserts to ACK data from MCU
;   bit 3  out  ROM A10     bank select bit 2
;   bit 2  out  ROM A9      bank select bit 1
;   bit 1  out  ROM A8      bank select bit 0
;   bit 0  in   sync latch

; ---- PIA Control Register bit 2 manipulation ---------------
SELECT_DDR      = $FB           ; use with AND to clear bit 2, to access DDR
SELECT_PR       = $04           ; use with OR  to set   bit 2, to access Peripheral Register

; ---- PIA Port B MCU handshake bits -------------------------
READ_ACK        = $10           ; PB4  Apple II -> MCU  ack data read from MCU
WRITE_REQ       = $20           ; PB5  Apple II -> MCU  data ready to send to MCU
READ_REQ        = $40           ; PB6  MCU -> Apple II  data ready to send to Apple II
WRITE_ACK       = $80           ; PB7  MCU -> Apple II  ack data written by Apple II

; ---- Writing a byte: Apple II -> MCU -----------------------
; Drive the byte onto Port A, then send it with a REQ/ACK handshake.
;
;  PA        ---<  data byte valid  >---------
;               _____________________
;  WRITE_REQ ___|1                 3|_________
;                      ____________________
;  WRITE_ACK __________|2                4|___
;
;   0) Apple II waits until WRITE_ACK = 0   (MCU ready, prior ack cleared)
;   1) Apple II puts byte on Port A, raises WRITE_REQ
;   2) MCU sees WRITE_REQ, reads Port A, raises WRITE_ACK
;   3) Apple II sees WRITE_ACK, lowers WRITE_REQ
;   4) MCU sees WRITE_REQ low, lowers WRITE_ACK -> byte transferred

; ---- Reading a byte: MCU -> Apple II -----------------------
; The MCU drives the byte onto Port A, then sends it with a REQ/ACK handshake.
;
;  PA        ---<  data byte valid  >---------
;               _____________________
;  READ_REQ  ___|1                 3|_________
;                      ____________________
;  READ_ACK  __________|2                4|___
;
;   0) MCU waits until READ_ACK = 0  (Apple II ready, prior ack cleared)
;   1) MCU puts byte on Port A, raises READ_REQ
;   2) Apple II sees READ_REQ, reads Port A, raises READ_ACK
;   3) MCU sees READ_ACK, lowers READ_REQ
;   4) Apple II sees READ_REQ low, lowers READ_ACK -> byte transferred

; ---- MCU command byte values -------------------------------
; * not documented, + partially documented
CMD_SET         = $00           ; SetMouse
CMD_READ        = $10           ; ReadMouse
CMD_SERVE       = $20           ; ServeMouse
CMD_CLEAR       = $30           ; ClearMouse
CMD_POS         = $40           ; PosMouse
CMD_INIT        = $50           ; InitMouse
CMD_CLAMP       = $60           ; ClampMouse
CMD_HOME        = $70           ; HomeMouse
CMD_TRANSPARENT = $80           ; set transparent mode, see IIc Tech Ref *
CMD_VBL_DATA    = $90           ; MouseSetVBLData +
CMD_VBL_FRAMES  = $A0           ; MouseSetVBLFrames *
CMD_CONFIG      = $B0           ; MouseSetConfig *
CMD_ACK_IRQ     = $C0           ; MouseAckIRQ *
CMD_RW_MEMORY   = $F0           ; MouseRWMemory +

; Bank select values
BANK0           = $00
BANK1           = $02
BANK2           = $04
BANK3           = $06
BANK4           = $08
BANK5           = $0A
BANK6           = $0C
BANK7           = $0E

; ---- INBUF string characters -------------------------------
PLUS_SIGN       = $AB           ; '+'
MINUS_SIGN      = $AD           ; '-'
COMMA           = $AC           ; ','
DIGIT_ZERO      = $B0           ; '0'

; ---- System / monitor addresses ----------------------------
IORTS           = $FF58         ; known RTS
HOME            = $FC58         ; Clear screen
COUT            = $FDED         ; Character output
F8VERSION       = $FBB3         ; Apple II ROM ID byte

; ---- Soft switches -----------------------------------------
KBD             = $C000         ; Read keyboard
RDVBLBAR        = $C019         ; R7 bit 7=0 if vertical blanking
GRAPHICS        = $C050         ; RW display graphics
TEXT            = $C051         ; RW display text
NOMIX           = $C052         ; RW display full screen graphics
PAGE1           = $C054         ; RW display text or graphics page 1
LORES           = $C056         ; RW display lo-res graphics
HIRES           = $C057         ; RW display hi-res graphics

; ---- Other RAM/screen addresses ----------------------------
ZP_TEMP1        = $06
ZP_TEMP2        = $07
ZP_TEMP3        = $08
CSWL            = $36           ; character output switch low
CSWH            = $37           ; character output switch high
KSWL            = $38           ; keyboard input switch low
KSWH            = $39           ; keyboard input switch high
INBUF           = $0200         ; GETLN input buffer
BCD_HI          = $0220         ; BCD conversion: hi byte of coordinate (shift register MSB)
BCD_LO          = $0221         ; BCD conversion: lo byte of coordinate (shift register LSB)
SLOTX16         = $0222         ; slot# * $10 (Y value for $C08x,Y)
MSLOT           = $07F8         ; slot $Cn
LINE191         = $3FD0         ; HIRES page 1, line 191

    .setcpu "6502"

; ==================================================================
; BANK 0: Entry points.
; ==================================================================
    .org $0000

; mouse id bytes (Mouse Technical Note #5)
;   $Cn05 = $38  Pascal ID byte
;   $Cn07 = $18  Pascal ID byte
;   $Cn0B = $01  Pascal ID byte
;   $Cn0C = $20  X-Y pointing device, type zero
;   $CnFB = $D6  AppleMouse II card id byte

ENTRY:                          ; PR#n and IN#n entry point
    bit IORTS                   ; known RTS, will set V
    bvs MAIN                    ; always

MOUSE_IN:                       ; our KSW entry point
    sec                         ; $38 mouse id byte
                                ; from this entry point the next instruction is BCC $18
    .byte $90                   ; C=1 => not taken, the CLC is skipped over, and
                                ; the next instruction is the CLV at $Cn08

MOUSE_OUT:                      ; our CSW entry point
    clc                         ; $18 mouse id byte
    clv
    bvc MAIN                    ; always

    .byte $01                   ; $01 mouse id byte
    .byte $20                   ; $20 mouse id byte

    .byte <ERR_STUB             ; Pascal init   (not implemented)
    .byte <ERR_STUB             ; Pascal read   (not implemented)
    .byte <ERR_STUB             ; Pascal write  (not implemented)
    .byte <ERR_STUB             ; Pascal status (not implemented)
    .byte $00                   ; $00 = interrupts supported
    .byte <SetMouse
    .byte <ServeMouse
    .byte <ReadMouse
    .byte <ClearMouse
    .byte <PosMouse
    .byte <ClampMouse
    .byte <HomeMouse
    .byte <InitMouse
    .byte <MouseRWMemory        ; + GetClamp in Mouse TN #7
    .byte <MouseCredits         ; * not documented
    .byte <MouseSetVBLData      ; + TimeData in Mouse TN #2
    .byte <MouseSetVBLFrames    ; * not documented
    .byte <MouseSetConfig       ; * not documented
    .byte <MouseAckIRQ          ; * not documented

MAIN:
; save processor state, will be restored in RESTORE_STATE
    php                         ; save flags
    sei                         ; disable interrupts
    sta MSLOT                   ; use MSLOT to save A temporarily
    pha                         ; save A
    tya
    pha                         ; save Y
    txa
    pha                         ; save X
    jsr IORTS                   ; IORTS is a bare RTS: JSR writes our $Cn return-address hi byte
                                ; into stack RAM, then RTS pops it; but it's still there at $0100,SP
    tsx
    lda $0100,x                 ; A = $Cn
    tax                         ; X = $Cn -- used throughout for screen-hole indexing
    php                         ; snapshot flags
    asl                         ; shift $Cn left to extract slot*16
    asl
    asl
    asl                         ; A = $n0
    plp                         ; restore V and C from before the shifts
    tay                         ; Y = $n0
    lda MSLOT                   ; restore A
    stx MSLOT                   ; MSLOT = $Cn
    pha                         ; save character
    lda #BANK4
    bvs B0_AB                   ; V=1: via $Cn00, PR#n / In#n -> B4_FN0
    bcc B0_93                   ; V=0, C=0: via MOUSE_OUT hook, CSW character output -> B4_FN1
    bcs B0_9D                   ; V=0, C=1: via MOUSE_IN  hook, KSW character input  -> B4_FN2
; ==================================================================
; MouseRWMemory +
; Read or write MCU memory:
;   A=0: read  — send 16-bit address, MCU returns the byte there
;   A=1: write — send 16-bit address + byte, MCU stores it
;
; Documented as GetClamp in Mouse TN #7, which uses the read path to
; fetch the clamping bounds out of MCU RAM.
;
; The routine passes its parameters through these scratchpad locations:
;   CLAMP_MIN_LO ($0478) -> MCU address low byte   (sent to MCU)
;   CLAMP_MAX_LO ($04F8) -> MCU address high byte  (sent to MCU)
;   CLAMP_MIN_HI ($0578) -> write: byte to store;  read: byte returned by MCU
;
; Entry: A=0 read; A=1 write
;        X = $Cn, Y = $n0
;        CLAMP_MIN_LO/CLAMP_MAX_LO = target MCU address (lo, hi)
;        CLAMP_MIN_HI = byte to write (write only)
; Exit:  C=0; on read, CLAMP_MIN_HI holds the byte read from the MCU
; ==================================================================
MouseRWMemory:
    and #$01                    ; bit 0 selects access: 0=read, 1=write
    ora #CMD_RW_MEMORY
    sta MOUSE_CMD,x
    lda #BANK1
    bne B0_93                   ; always
; ==================================================================
; MouseSetVBLData +
; Bits 0-3 of A are used to set VBL timer options.
;
; Bits 2 and 3 pass parameters from the specified scratchpad locations.
;
;   bit  effect                                +bytes  parameter locations
;   ---  -------------------------------------  -----  -----------------------------
;    0   VBL rate select: 0 = 60 Hz, 1 = 50 Hz    0
;    1   add $FC8E to MCU timer SEED              0
;    2   add signed 16-bit delta to SEED          2    CLAMP_MIN_LO (lo), CLAMP_MAX_LO (hi)
;    3   set FRAMES_PER_IRQ (fire IRQ every N)    1    CLAMP_MIN_HI
;
; Bit 0 is documented in Mouse TN #2 "Set VBL Interrupt Rate"), the
; rest are not documented.
;
; Entry: A = option bits (low nibble)
;        X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
MouseSetVBLData:
    and #$0F
    ora #CMD_VBL_DATA
    bne B0_8E                   ; always
    .res 2, $FF
B0_5B:
    lda PIA_CRB,y
    and #SELECT_DDR
    sta PIA_CRB,y               ; access DDRB
    lda #$3E
    sta PIA_DDRB,y              ; DDRB = 0011 1110: PB1-PB5 outputs, PB0/PB6/PB7 inputs
    lda PIA_CRB,y
    ora #SELECT_PR
    sta PIA_CRB,y               ; access PB
B0_BANK_SWITCH:
    lda PIA_PB,y
    and #$C1                    ; 1100 0001: clear bits 1–5
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    beq EXIT_OK                 ; function code 0: return success
    ror                         ; rotate function code: even -> C=0, odd -> C=1
    bcc EXIT_ERR                ; C=0: error exit
                                ; C=1: restore saved registers and return
RESTORE_STATE:
    pla
    tax                         ; restore X
    pla
    tay                         ; restore Y
    pla
    plp                         ; restore flags
    rts
EXIT_OK:
    clc
B0_89:
    rts
; ==================================================================
; ClampMouse
; Sets new clamping boundaries. Does not affect mouse position or
; update mouse position screen holes; use ReadMouse to do that.
;
; Entry: A=0 set new X boundaries; A=1 set new Y boundaries.
;        CLAMP_MIN_LO = min bound, low byte
;        CLAMP_MAX_LO = max bound, low byte
;        CLAMP_MIN_HI = min bound, high byte
;        CLAMP_MAX_HI = max bound, high byte
;        X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
ClampMouse:
    and #$01                    ; bit 0 selects axis: 0=X, 1=Y
    ora #CMD_CLAMP
B0_8E:
    sta MOUSE_CMD,x
    lda #BANK7
B0_93:
    sta ROM_BANK,x
    lda #$01                    ; function code 1
B0_98:
    pha
    bne B0_5B                   ; always
; ==================================================================
; ReadMouse
; Reads the current mouse X-Y position and status into
; MOUSE_XLO, MOUSE_XHI, MOUSE_YLO, MOUSE_YHI, and MOUSE_STATUS.
; Clears VBL, button, and movement interrupt bits 1-3 in MOUSE_STATUS.
;
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
ReadMouse:
    lda #BANK6
B0_9D:
    sta ROM_BANK,x
    lda #$02                    ; function code 2
    bne B0_98                   ; always
; ==================================================================
; ClearMouse
; Sets the mouse position to (0,0) even when not within
; clamping boundaries. Clears mouse status byte bits 5-7.
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
ClearMouse:
    lda #CMD_CLEAR
B0_A6:
    sta MOUSE_CMD,x
    lda #BANK3
B0_AB:
    sta ROM_BANK,x
    lda #$00                    ; function code 0
    pha
    beq B0_5B                   ; always
; ==================================================================
; SetMouse
; Sets the mouse mode to the value in the accumulator.
; Entry: A = mode byte (see MOUSE_MODE)
;        X = $Cn, Y = $n0
; Exit:  C=0 mode was legal; C=1 mode was not legal
; ==================================================================
SetMouse:
    cmp #$10                    ; mode must be $00-$0F; $10+ is invalid
    bcs B0_89                   ; invalid mode: return with carry set (error)
    sta MOUSE_MODE,x            ; save valid mode to screen hole
    bcc B0_A6                   ; always
; ==================================================================
; InitMouse
; Initializes mouse position to 0,0. Sets X and Y clamping bounds to 0-1023.
; Syncs the mouse VBL timer to the Apple II VBL.
; Sets MCU internal values; does not update screen holes.
;
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
InitMouse:
    lda #BANK2
    bne B0_AB                   ; always
; ==================================================================
; PosMouse
; Sets the mouse coordinates to new values.
; Entry: MOUSE_XLO/XHI and MOUSE_YLO/YHI contain new X and Y positions
;        X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
PosMouse:
    lda #CMD_POS
    bne B0_8E                   ; always
; ==================================================================
; ServeMouse
; Services mouse interrupt if needed. Updates MOUSE_STATUS to show
; which event caused the interrupt.
; Entry: X, Y, A -- don't matter
; Exit:  C=0 mouse caused the interrupt; C=1 something else caused it
; ==================================================================
ServeMouse:
    ldy ZP_TEMP1                ; save zp value (clobbered below)
    lda #$60                    ; $60 = RTS opcode
    sta ZP_TEMP1                ; build a one-byte RTS routine in zero page
    jsr ZP_TEMP1                ; call it to discover our slot: JSR pushes our return
                                ; address $Cnxx; the RTS returns at once, but the return
                                ; address is still on the stack
    sty ZP_TEMP1                ; restore zp value
    tsx
    lda $0100,x                 ; read the return address hi byte back from the stack
    tax                         ; X = slot $Cn
    asl
    asl
    asl
    asl
    tay                         ; Y = $n0
    lda #CMD_SERVE
    bne B0_A6                   ; always
; ==================================================================
; HomeMouse
; Sets the internal mouse position to the upper-left corner of the
; clamping window. Does not update mouse position screen holes; use
; ReadMouse to do that.
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
HomeMouse:
    lda #CMD_HOME
    bne B0_A6                   ; always
; ==================================================================
; MouseSetVBLFrames *
; Set the mouse interrupt to fire once every N frames.
; Entry: A = frames per IRQ (N)
;        X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
MouseSetVBLFrames:
    pha                         ; save N
    lda #CMD_VBL_FRAMES
    bne B0_8E                   ; always
; ==================================================================
; MouseSetConfig *
; Set the MCU's MOUSE_CONFIG byte (MCU memory location $5D):
;   bit 0 = half resolution (count clock rising edges only)
;   bit 1 = clear-on-read   (zero mouse position after ReadMouse)
; Entry: A = config bits
;        X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
MouseSetConfig:
    and #$0F
    ora #CMD_CONFIG
    bne B0_A6                   ; always
; ==================================================================
; MouseAckIRQ *
; Acknowledges a mouse interrupt.
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
MouseAckIRQ:
    lda #CMD_ACK_IRQ
    bne B0_A6                   ; always
; ==================================================================
; MouseCredits
; Print Credits
; Entry: X = $Cn, Y = $n0
; Exit:  C=0
; ==================================================================
MouseCredits:
    lda #BANK1
    bne B0_AB                   ; always
ERR_STUB:
    ldx #$03                    ; Pascal Illegal I/O request
EXIT_ERR:
    sec
    rts
    .res  3, $FF
MOUSE_ID:
    .byte $D6                   ; $D6 mouse id byte
    .res  3, $FF
    .byte $01

; ==================================================================
; BANK 1: MouseCredits, MouseRWMemory
; Two dispatch paths via function code:
;   code=0 (B1_FN0): print the credits
;   code=1 (B1_FN1): MCU memory read/write
; ==================================================================
    .org $0100

B1_FN0:
    tya                         ; save Y
    pha
    lda ZP_TEMP1                ; save ZP_TEMP1
    pha
    lda ZP_TEMP2                ; save ZP_TEMP2
    pha
    stx ZP_TEMP2                ; hi byte of Credits pointer ($Cn)
    lda #<Credits               ; lo byte of Credits pointer
    sta ZP_TEMP1
    jsr HOME                    ; clear screen
    ldy #$00
B1_13:
    lda (ZP_TEMP1),y            ; read character from string
    beq B1_1D                   ; NUL terminator: done
    jsr COUT                    ; print character to screen
B1_1A:
    iny                         ; advance to next character
    bne B1_13                   ; loop
B1_1D:
    pla                         ; pop saved zp bytes
    sta ZP_TEMP2
    pla
    sta ZP_TEMP1
    pla
    tay                         ; Y = $n0
    bne B1_TO_B0                ; always
Credits:
; "AppleMouse", $8D
; "Copyright 1983 by Apple Computer, Inc.", $8D, $8D
; "Bachman/Marks/MacKay", $8D, $00
    .byte $C1,$F0,$F0,$EC,$E5,$CD,$EF,$F5,$F3,$E5,$8D,$C3,$EF,$F0,$F9,$F2
    .byte $E9,$E7,$E8,$F4,$A0,$B1,$B9,$B8,$B3,$A0,$E2,$F9,$A0,$C1,$F0,$F0
    .byte $EC,$E5,$A0,$C3,$EF,$ED,$F0,$F5,$F4,$E5,$F2,$AC,$A0,$C9,$EE,$E3
    .byte $AE,$8D,$8D,$C2,$E1,$E3,$E8,$ED,$E1,$EE,$AF,$CD,$E1,$F2,$EB,$F3
    .byte $AF,$CD,$E1,$E3,$CB,$E1,$F9,$8D,$00
B1_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    bmi B1_8A                   ; negative function code ? -> rts
    beq B1_FN0
    bne B1_FN1
B1_TO_B0:
    lda #BANK0
    sta ROM_BANK,x
    pha                         ; function code 0: return success
    beq B1_BANK_SWITCH          ; always; switch back to bank 0
B1_8A:
    rts
B1_FN1:
    lda MOUSE_MODE,x
    and #$0F
    ora #BANK1<<4               ; upper nibble = BANK1: B6_51 will route back here
    sta MOUSE_MODE,x
    txa                         ; A = $Cn
    pha                         ; hi byte for the RTS jump: push $Cn four times
    pha                         ; (each time through B1_A0 will consume one $Cn as the hi byte)
    pha
    pha
    lda #<B1_AB-1               ; lo byte for the RTS jump
    pha
    lda MOUSE_CMD,x
B1_A0:
    pha
    lda #BANK6
    sta ROM_BANK,x
    lda #$00                    ; function code 0
    pha
    beq B1_BANK_SWITCH          ; always
; ==================================================================
; B1_AB: RTS jump target
; Reached after B1_A0 call #1 (sent the MouseRWMemory MOUSE_CMD byte).
; Now send the MCU address low byte (held in CLAMP_MIN_LO) via call #2.
; ==================================================================
B1_AB:
    lda #<B1_B4-1               ; lo byte for the RTS jump
    pha
    lda CLAMP_MIN_LO            ; lo byte of MCU address
    clc
    bcc B1_A0                   ; send byte; returns to B1_B4
; ==================================================================
; B1_B4: RTS jump target
; Reached after B1_A0 call #2: MCU now has the address low byte.
; Send the address high byte (CLAMP_MAX_LO) via call #3.
; ==================================================================
B1_B4:
    lda #<B1_BD-1               ; lo byte for the RTS jump
    pha
    lda CLAMP_MAX_LO            ; hi byte of MCU address
    clc
    bcc B1_A0                   ; send byte; returns to B1_BD
; ==================================================================
; B1_BD: RTS jump target
; Reached after B1_A0 call #3: MCU has the full 16-bit address.
; Command bit 0 selects read vs write: read just reads the byte back;
; write sends a data byte (CLAMP_MIN_HI).
; ==================================================================
B1_BD:
    lda #<B1_TO_B0-1            ; lo byte for the RTS jump
    pha
    ror MOUSE_CMD,x             ; C = bit 0 of MOUSE_CMD: 0=read, 1=write
    bcc B1_CA                   ; read: no data byte, go read the result
    lda CLAMP_MIN_HI            ; write: load the data byte
    bcs B1_A0                   ; always; send data byte; returns to B1_TO_B0
B1_CA:
    txa                         ; A = $Cn
    pha                         ; push $Cn: hi byte for the RTS jump
    lda #<B1_D9-1               ; lo byte for the RTS jump
    pha
    lda #BANK6
    sta ROM_BANK,x
    lda #$01                    ; function code 1
    pha
    bne B1_BANK_SWITCH          ; always
; ==================================================================
; B1_D9: RTS jump target
; Read path: B6_FN1 read one byte from the MCU into MOUSE_CMD.
; Store the returned byte as CLAMP_MIN_HI, then RTS jump to B1_TO_B0.
; ==================================================================
B1_D9:
    lda MOUSE_CMD,x
    sta CLAMP_MIN_HI
    rts
    .res  31, $FF
    .byte $C2

; ==================================================================
; BANK 2: InitMouse
; Reset the MCU and sync the mouse VBL interrupt to video VBL
; ==================================================================
    .org $0200

B2_FN0:
    lda MOUSE_MODE,x
    and #$0F
    ora #BANK2<<4               ; upper nibble = BANK2: B6_51 will route back here
    sta MOUSE_MODE,x
    txa                         ; A = $Cn
    pha                         ; hi byte for the RTS jump: push $Cn three times
    pha
    pha
    lda #<B2_12-1               ; lo byte for the RTS jump
    bne B2_39                   ; always
; ==================================================================
; B2_12: RTS jump target
; Reached after B2_39 call #1 (sends CMD_INIT $50 to reset MCU state).
; Sends a second BANK6 command with different params ($1E, function code 1),
; then checks ROM version and synchronises to VBL.
; ==================================================================
B2_12:
    lda #<B2_1F-1               ; lo byte for the RTS jump
    pha
    lda #BANK6
    sta ROM_BANK,x
    lda #$01                    ; function code 1: B6_FN1 (read without sending command)
    pha
    bne B2_BANK_SWITCH          ; always; dispatch to BANK6; returns to B2_1F
; ==================================================================
; B2_1F: RTS jump target
; VBL sync, then reset the MCU timer to phase-lock to it.
; The MCU's periodic VBL interrupt is driven by its own free-running
; frame timer. To keep the timer aligned with the real video VBL,
; InitMouse synchronizes to a VBL edge and then sends CMD_INIT,
; which restarts the MCU timer.
; Two sync methods, by machine:
;   IIe or later : poll RDVBLBAR ($C019) for the VBL edge directly.
;   Apple II/II+ : no RDVBLBAR soft switch, use the mouse card sync latch to detect
;   when the Apple II is scanning the last line of video.
; ==================================================================
B2_1F:
    lda F8VERSION
    cmp #$06                    ; IIe or later ($FBB3 = 6)?
    bne B2_47                   ; no: Apple II/II+
B2_26:
    lda RDVBLBAR
    bmi B2_26                   ; wait for VBL to go low (blanking)
B2_2B:
    lda RDVBLBAR
    bpl B2_2B                   ; wait for VBL to go high (end of blanking)
B2_30:
    lda RDVBLBAR
    bmi B2_30                   ; wait for VBL to go low again (start of blanking)
    lda #<B2_80-1               ; lo byte for the RTS jump
    bne B2_39                   ; always; branch to B2_39; returns to B2_80
B2_39:
    pha                         ; push A (= RTS jump lo byte: $11, $7F, or $E3)
    lda #CMD_INIT               ; reset MCU state + restart its frame timer; after a
                                ; VBL sync this phase-locks the mouse VBL to the Apple II VBL
    pha
    lda #BANK6
    sta ROM_BANK,x
    lda #$00                    ; function code 0: dispatch to B6_FN0
    pha
    beq B2_BANK_SWITCH          ; always; switch to BANK6
B2_47:
    lda ZP_TEMP1                ; save zp temps on stack
    pha
    lda ZP_TEMP2
    pha
    tya                         ; save Y
    pha
    lda #$20                    ; make ZP_TEMP1 point to HIRES page 1
    sta ZP_TEMP2
    ldy #$00
    sty ZP_TEMP1
B2_57:
    lda #$00                    ; A = 0: fill byte
B2_59:
    sta (ZP_TEMP1),y            ; zero one byte
    iny
    bne B2_59
    inc ZP_TEMP2
    lda ZP_TEMP2
    cmp #$40                    ; done yet ?
    bne B2_57                   ; no, continue clearing
    pla
    tay
    lda ZP_TEMP3                ; save zp temp
    pha
    lda #$00
    beq B2_8B                   ; always
    .byte $FF
B2_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    bmi B2_88                   ; negative function code ? -> rts
    beq B2_FN0
B2_80:
    lda #BANK0
    sta ROM_BANK,x
    pha
    beq B2_BANK_SWITCH          ; always
B2_88:
    rts
B2_89:
    bne B2_39                   ; always (entered with A=$E3 from B2_D7)
; ------------------------------------------------------------------
; B2_8B: VBL sync with help from mouse card PAL hardware.
;
; - Two sentinel $01 bytes are set up on the last line of video, 16 bytes apart,
;   the only bytes with D0=1 on an otherwise cleared HIRES page.
;
; - PAL equations
;   pin 19 = I/O STROBE* + Q3    ; wired to PAL pin 1 CLK
;   pin 17 := /D0                ; D flip-flop clocked by pin 1 = SYNC LATCH
;
; - When the 6502 reads anywhere in $C800–$CFFF (firmware uses $CFFF),
;   I/O STROBE* goes low, then PAL pin 19 = Q3; when Q3 pulses within that cycle -> 
;   rising edge on pin 1 -> the D flip-flop captures /D0 into SYNC LATCH. On an Apple II,
;   $CFFF doesn't drive the bus, so D0 is bit 0 of the floating-bus byte the video
;   scanner just read. The 6502 then reads SYNC LATCH at PIA Port B bit 0.
;
; - The loop checks sync latch twice, 16 cycles apart, matching the video
;   scanner's one byte per cycle rate and the 16 byte sentinel spacing. Two
;   consecutive hits confirm the video scanner has reached the last line and a VBL
;   is about to start.
;
; Caveat: the sync loop is guaranteed to get in sync if the loop cycle count
; is relatively prime to the frame length (17030 cycles @ 60 Hz, 20280 @ 50 Hz).
; But the loop cycle count is 44, which IS NOT relatively prime
; (gcd = 2 and 4 respectively), so I suspect this sync method does not always work!
; ------------------------------------------------------------------
B2_8B:
    lda #$01
    sta LINE191                 ; first sentinel byte at the start of the last line ...
    sta LINE191+16              ; ... and another 16 bytes/cycles later
    lda HIRES
    lda PAGE1
    lda NOMIX
    lda GRAPHICS                ; graphics mode -> HIRES active.
                                ; A = 0: reading the "write only" GRAPHICS soft switch
                                ; returns whatever is floating on the bus from the most
                                ; recent video scanner read, most likely zero since we just
                                ; cleared video memory.
    nop
    sta ZP_TEMP1                ; zero timeout counter
    sta ZP_TEMP2
    sta ZP_TEMP3
B2_A6:                          ; this loop takes 44 cycles when the first sync latch misses:
                                ; 27 from B2_A6..B2_C0, plus 17 from B2_C0..bcs B2_A6
    inc ZP_TEMP1                ; [5]   increment 24-bit counter
    bne B2_B8                   ; [2/3] lo byte did not wrap: skip mid-byte increment
    inc ZP_TEMP2                ; [5]   increment mid byte
    bne B2_BA                   ; [2/3] mid byte did not wrap: skip hi-byte increment
    inc ZP_TEMP3                ; [5]   increment hi byte
    lda ZP_TEMP3                ; [3]   test hi byte
    cmp #$01                    ; [2]   reached $01 yet ?
    bcc B2_C0                   ; [2/3] not yet: continue polling
    bcs B2_D7                   ; [2/3] timeout: exit loop w/o syncing VBL
B2_B8:
    php                         ; [3]   waste 7 cycles, to match mid byte increment path
    plp                         ; [4]
B2_BA:
    php                         ; [3]   waste 12 cycles, to match hi byte increment path
    plp                         ; [4]
    lda #$00                    ; [2]
    lda $00                     ; [3]
B2_C0:
    lda $CFFF                   ; [4]   access $CFFF, which triggers the PAL to update sync latch
    lda PIA_PB,y                ; [4]   read sync latch: PIA Port B bit 0
    lsr                         ; [2]   shift sync latch bit into carry
    nop                         ; [2]   pad to a 16-cycle gap before the next $CFFF read, matching
    nop                         ; [2]   the 16 byte offset between the two sentinel bytes
    bcs B2_A6                   ; [2/3] C=1: missed the sentinel, keep polling
    lda $CFFF                   ; [4]   second trigger, timed to sync with the second sentinel pixel
    lda PIA_PB,y                ; [4]   read sync latch again
    lsr                         ; [2]   shift into carry
    lda $00                     ; [3]   timing filler
    nop                         ; [2]   timing filler
    bcs B2_A6                   ; [2/3] C=1: missed the sentinel, keep polling
                                ;       C=0: matched both sentinels => VBL will start soon
B2_D7:
    pla                         ; restore zp temps
    sta ZP_TEMP3
    pla
    sta ZP_TEMP2
    pla
    sta ZP_TEMP1
    lda #<B2_E4-1               ; lo byte for the RTS jump
    bne B2_89                   ; always; branch to B2_89 -> B2_39 (call #3, returns to B2_E4)
; ==================================================================
; B2_E4: RTS jump target
; Reached after B2_39 call #3. Restore display to text+lo-res mode
; after the HIRES initialisation in B2_8B, then return to BANK0.
; ==================================================================
B2_E4:
    lda TEXT                    ; switch display back to text mode
    lda LORES
    clc
    bcc B2_80                   ; always; switch to BANK0 and return
    .res  18, $FF
    .byte $C1

; ==================================================================
; BANK 3: SetMouse, ServeMouse, ClearMouse, HomeMouse, MouseSetConfig, MouseAckIRQ
; Send command byte to the MCU; ServeMouse also reads a status byte back
; ==================================================================
    .org $0300

B3_FN0:
    lda MOUSE_CMD,x             ; check command: ServeMouse needs a response read after write
    cmp #CMD_SERVE              ; is it ServeMouse ($20)?
    bne B3_0D                   ; no: no response needed
    lda #$7F
    adc #$01                    ; V=1 ($7F + 1 = $80, overflow guaranteed)
    bvs B3_SEND_CMD             ; always
B3_0D:
    clv                         ; V=0: no response read needed
B3_SEND_CMD:
B3_WAIT_WRITE_ACK_CLR:
    lda PIA_PB,y                ; wait for MCU to clear WRITE_ACK (PB7=0)
    bmi B3_WAIT_WRITE_ACK_CLR
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$FF
    sta PIA_DDRA,y              ; DDRA = $FF: all PA pins are outputs (Apple II -> MCU)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
    lda MOUSE_CMD,x
    sta PIA_PA,y                ; write command to MCU
    lda PIA_PB,y
    ora #WRITE_REQ
    sta PIA_PB,y                ; assert WRITE_REQ
B3_WAIT_WRITE_ACK:
    lda PIA_PB,y                ; wait for WRITE_ACK (PB7=1)
    bpl B3_WAIT_WRITE_ACK
    and #<(~WRITE_REQ)
    sta PIA_PB,y                ; clear WRITE_REQ
    bvs READ_MCU_RESPONSE       ; V=1 (ServeMouse)? -> go read the MCU's interrupt-status response
    lda MOUSE_CMD,x             ; not ServeMouse: check if we need to zero screen holes
    cmp #CMD_CLEAR              ; is it ClearMouse ?
    bne B3_SUCCESS              ; no: return to bank 0
    lda #$00                    ; yes: set screen hole mouse coords to (0,0)
    sta MOUSE_XHI,x
    sta MOUSE_XLO,x
    sta MOUSE_YHI,x
    sta MOUSE_YLO,x
    beq B3_SUCCESS              ; always
    .res  23, $FF
B3_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    beq B3_FN0
B3_SUCCESS:
    lda #BANK0
    sta ROM_BANK,x
    pha                         ; function code 0: return success
    beq B3_BANK_SWITCH          ; always; switch to bank 0
READ_MCU_RESPONSE:
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$00
    sta PIA_DDRA,y              ; DDRA = $00: all PA pins are inputs (MCU -> Apple II)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
B3_WAIT_READ_REQ:
    lda PIA_PB,y                ; wait for READ_REQ from MCU (PB6=1)
    asl
    bpl B3_WAIT_READ_REQ
    lda PIA_PA,y                ; read the interrupt status byte from MCU
    sta MOUSE_CMD,x             ; stash in MOUSE_CMD temporarily
    lda PIA_PB,y
    ora #READ_ACK
    sta PIA_PB,y                ; assert READ_ACK
B3_WAIT_READ_REQ_CLR:
    lda PIA_PB,y                ; wait for MCU to clear READ_REQ (PB6=0)
    asl
    bmi B3_WAIT_READ_REQ_CLR
    lda PIA_PB,y
    and #<(~READ_ACK)
    sta PIA_PB,y                ; clear READ_ACK
    lda MOUSE_STATUS,x
    and #$F1                    ; clear old interrupt bits
    ora MOUSE_CMD,x             ; merge in interrupt bits from MCU response (D3=VBL, D2=button, D1=movement)
    sta MOUSE_STATUS,x
    and #$0E                    ; extract just the interrupt source bits
    bne B3_SUCCESS              ; any bits set? -> return C=0
    lda #BANK0                  ; no interrupt bits -> return C=1 ("not mouse interrupt")
    sta ROM_BANK,x
    lda #$02                    ; function code 2: EXIT_ERR
    pha
    bne B3_BANK_SWITCH          ; always
    .res  41, $FF
    .byte $C3

; ==================================================================
; BANK 4: I/O hooks
;
; Three dispatch paths via function code:
;   code=0 (B4_FN0): PR#n / IN#n: install CSW / KSW hook and then run the hook code
;   code=1 (B4_FN1): MOUSE_OUT: handle one output character
;   code=2 (B4_FN2): MOUSE_IN: format mouse X-Y position and status in INBUF
; ==================================================================
    .org $0400

B4_FN0:
    cpx CSWH                    ; is CSWH pointing to our slot?
    bne B4_31                   ; no: check KSW
    lda #<MOUSE_OUT
    cmp CSWL                    ; is CSWL pointing to MOUSE_OUT ?
    beq B4_31                   ; yes: assume we entered via IN#n, check KSW
    sta CSWL                    ; no: install MOUSE_OUT hook, fall thru to hook code
B4_FN1:
    pla                         ; pop character
    cmp #$8D                    ; CR ?
    beq B4_85                   ; yes -> exit
    and #MOUSE_ENABLED          ; only keep "mouse is on" bit 0
    ora #BANK4<<4               ; upper nibble = BANK4
    sta MOUSE_MODE,x
    txa                         ; A = $Cn
    pha                         ; push $Cn: hi byte for the RTS jump
    lda #<B4_85-1               ; lo byte for the RTS jump
    pha
    lda MOUSE_MODE,x
    lsr                         ; bit 0 (mouse is on) -> carry
    lda #CMD_TRANSPARENT        ; A = $80
    bcs B4_26                   ; mouse on = 1 -> keep CMD_TRANSPARENT ($80)
    asl                         ; mouse on = 0 -> A = CMD_SET mouse off ($00)
B4_26:
    pha                         ; push command byte to send to MCU
    lda #BANK6
    sta ROM_BANK,x
    lda #$00                    ; function code 0
    pha
    beq B4_BANK_SWITCH          ; always; dispatch to BANK6; BANK6->BANK4 B4_8F->RTS
                                ; -> pops $84/$Cn -> RTS jump to B4_85
B4_31:
    cpx KSWH                    ; is KSWH pointing to our slot?
    bne B4_FN1                  ; no: (should not happen) -> go handle an output character
    lda #<MOUSE_IN
    sta KSWL                    ; install MOUSE_IN hook, fall thru to handle character
B4_FN2:
    lda MOUSE_MODE,x
    and #MOUSE_ENABLED          ; is mouse on (mode bit 0) ?
    bne B4_54                   ; yes: continue to read and format mouse info
    pla                         ; no: discard 4 of 5 registers saved in MAIN, leaving the flags
    pla
    pla
    pla
    lda #$00                    ; set screen hole mouse coords to (0,0)
    sta MOUSE_XLO,x
    sta MOUSE_XHI,x
    sta MOUSE_YLO,x
    sta MOUSE_YHI,x
    beq B4_90                   ; always
B4_54:
    lda MOUSE_MODE,x
    and #MOUSE_ENABLED          ; only keep "mouse is on" bit 0
    ora #BANK4<<4               ; upper nibble = BANK4: B6_51 will route back here
    sta MOUSE_MODE,x
    txa                         ; A = $Cn
    pha                         ; push $Cn: hi byte for the RTS jump
    lda #<B4_A2-1               ; lo byte for the RTS jump
    pha
    lda #CMD_READ               ; MCU command: read mouse position + status
    pha
    lda #BANK6
    bne B4_9A                   ; always
    .res  6, $FF
B4_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    bmi B4_8F                   ; negative function code ? -> rts
    beq B4_FN0
    ror
    bcs B4_FN1
    bcc B4_FN2
; ==================================================================
; B4_85: RTS jump target
; Reached from B4_FN1 after BANK6 sends the mode byte to the MCU.
; Switch to BANK0 with function code 1: RESTORE_STATE restores saved
; registers and returns to the CSW caller.
; ==================================================================
B4_85:
    lda #BANK0
    sta ROM_BANK,x
    lda #$01                    ; function code 1 -> RESTORE_STATE
    pha
    bne B4_BANK_SWITCH          ; always
B4_8F:
    rts
B4_90:
    lda #$C0                    ; $C0 = button is down, button was down
    sta MOUSE_STATUS,x          ; set status for mouse off case
B4_TO_B5:
    sty SLOTX16                 ; save Y = slot*$10
    lda #BANK5
B4_9A:
    sta ROM_BANK,x
    lda #$00                    ; function code 0
    pha
    beq B4_BANK_SWITCH          ; always
; ==================================================================
; B4_A2: RTS jump target
; Reached from B4_54 after BANK6 sends CMD_READ to MCU.
; Discard the 4 saved caller registers, then read 5 bytes back
; from the MCU and store in position screen holes, then format.
; ==================================================================
B4_A2:
    pla                         ; discard 4 of 5 registers saved in MAIN, leaving the flags
    pla
    pla
    pla
    lda #$05
    sta MOUSE_CMD,x             ; use MOUSE_CMD for the byte counter
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$00
    sta PIA_DDRA,y              ; DDRA = $00: all PA pins are inputs (MCU -> Apple II)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
B4_WAIT_READ_REQ:
    lda PIA_PB,y                ; wait for READ_REQ from MCU (PB6=1)
    asl
    bpl B4_WAIT_READ_REQ
    lda PIA_PA,y
    pha                         ; save data on stack, will copy to screen holes later
    lda PIA_PB,y
    ora #READ_ACK
    sta PIA_PB,y                ; assert READ_ACK
B4_WAIT_READ_REQ_CLR:
    lda PIA_PB,y                ; wait for MCU to clear READ_REQ (PB6=0)
    asl
    bmi B4_WAIT_READ_REQ_CLR
    lda PIA_PB,y
    and #<(~READ_ACK)
    sta PIA_PB,y                ; clear READ_ACK
    dec MOUSE_CMD,x             ; decrement byte counter
    bne B4_WAIT_READ_REQ        ; counter not zero: read next byte from MCU
    pla
    sta MOUSE_STATUS,x
    pla
    sta MOUSE_YHI,x
    pla
    sta MOUSE_YLO,x
    pla
    sta MOUSE_XHI,x
    pla
    sta MOUSE_XLO,x
    clc
    bcc B4_TO_B5                ; always
    .res  3, $FF
    .byte $C8                   ; bank-tail filler (unreached)

; ==================================================================
; BANK 5: MOUSE_IN
; Format mouse coords and status "+xxxxx,+yyyyy,+st" into INBUF
; ==================================================================
    .org $0500

B5_FN0:
    txa                         ; A = $Cn
    pha                         ; hi byte for the RTS jump: push $Cn three times
    pha
    pha
    lda #<B5_13-1               ; lo byte for the RTS jump
    pha
    ldy MOUSE_XLO,x             ; Y = X coord lo byte
    lda MOUSE_XHI,x             ; A = X coord hi byte
    tax                         ; X = X coord hi byte (sign check in B5_FN1)
    tya                         ; A = X coord lo byte
    ldy #$05                    ; Y = 5: starting digit position in INBUF for X coord
    bne B5_FN1                  ; always; branch to B5_FN1; returns to B5_13
; ==================================================================
; B5_13: RTS jump target
; Reached after B5_FN1 formats X coordinate. Now set up Y coordinate.
; ==================================================================
B5_13:
    ldx MSLOT                   ; X = $Cn
    lda #<B5_25-1               ; lo byte for the RTS jump
    pha
    ldy MOUSE_YLO,x             ; Y = Y coord lo byte
    lda MOUSE_YHI,x             ; A = Y coord hi byte
    tax
    tya                         ; A = Y coord lo byte
    ldy #$0C                    ; Y = 12: digit position for Y coord in INBUF
    bne B5_FN1                  ; always; branch to B5_FN1; returns to B5_25
; ==================================================================
; B5_25: RTS jump target
; Reached after B5_FN1 formats Y coordinate. Now encode status field.
; Encodes bits 6 and 7 into a 2-digit decimal status value.
; ==================================================================
B5_25:
    ldx MSLOT                   ; X = $Cn
    lda #<B5_44-1               ; lo byte for the RTS jump
    pha
    lda KBD                     ; read keyboard: bit 7 = key-down flag
    asl                         ; shift bit 7 into carry
    php                         ; save carry (key-down) onto stack
    lda MOUSE_STATUS,x
    rol A                       ; rotate MOUSE_STATUS bits into carry chain
    rol A
    rol A                       ; A bits [1:0] now contain move + button flags
    and #$03
    eor #$03                    ; invert: 0=active, 3=inactive -> 3=active, 0=inactive
    sec
    adc #$00                    ; add 1 (with guaranteed C=1) -> range 1-4 as status digit
    plp                         ; restore carry (key-down flag), C=1 will format with '-'
    ldx #$00                    ; X = hi byte for status (always 0)
    ldy #$10                    ; Y = 16: digit position for status in INBUF
    bne B5_91                   ; always; branch to B5_91; returns to B5_44
; ==================================================================
; B5_44: RTS jump target
; Reached after B5_91 formats status digits. Store CR terminator,
; set up fake X/Y/A for RESTORE_STATE, then switch to BANK0 to return.
; RESTORE_STATE will restore: X=$11 (cursor pos), Y=$11, A=$8D (CR char).
; ==================================================================
B5_44:
    lda #$8D                    ; A = CR character ($8D)
    sta INBUF+$11               ; CR terminator just past the status field
    pha                         ; push $8D: RESTORE_STATE will pop this as A (char to return to KEYIN)
    lda #$11                    ; $11 = 17: output cursor position / string length
    pha                         ; push $11: RESTORE_STATE pops as Y
    pha                         ; push $11: RESTORE_STATE pops as X
    lda #BANK0
    beq B5_BANK_SWITCH          ; always; dispatch to BANK0 -> RESTORE_STATE
    .res  18, $FF
B5_BANK_SWITCH:
    ldx MSLOT                   ; X = $Cn
    ldy SLOTX16                 ; restore Y = slot*$10
    sta ROM_BANK,x              ; always BANK0
    lda #$01                    ; function code 1
    pha
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    bmi B5_CC                   ; negative function code ? -> rts
    beq B5_FN0
B5_FN1:
    cpx #$80                    ; hi byte negative?
    bcc B5_91                   ; no: positive value, skip negation
    eor #$FF                    ; negate lo byte: 255-A
    adc #$00                    ; + carry for two's complement: -value lo byte
    pha                         ; save negated lo
    txa                         ; negate hi byte
    eor #$FF                    ; + carry: -value hi byte (two's complement complete)
    adc #$00                    ; X = -hi byte (unsigned magnitude)
    tax                         ; restore negated lo
    pla
    sec                         ; set carry to indicate negative value
B5_91:
    sta BCD_LO                  ; BCD_LO = lo byte of abs(value)
    stx BCD_HI                  ; BCD_HI = hi byte of abs(value)
    lda #PLUS_SIGN
    bcc B5_9D                   ; C=0 (positive): keep '+'
    lda #MINUS_SIGN             ; C=1 (negative): use  '-'
B5_9D:
    pha                         ; push sign character (+ or -) onto stack; stored at end after digits
    lda #COMMA                  ; comma separator between coordinate fields
    sta INBUF+1,y               ; store comma at INBUF+1+Y (just after current digit position)
B5_A3:
    ldx #$11                    ; 17-bit conversion loop: enough for 5 decimal digits of a 16-bit number
    lda #$00                    ; start accumulator at 0
    clc
B5_A8:
    rol                         ; roll binary fraction bit into BCD accumulator
    cmp #$0A                    ; if >= 10, subtract and carry into next digit
    bcc B5_AF                   ; less than 10: no borrow needed this step
    sbc #$0A
B5_AF:
    rol BCD_LO                  ; shift left; carry out of BCD_HI feeds next rol A
    rol BCD_HI
    dex                         ; count down 17 steps
    bne B5_A8                   ; keep going until all 17 bits processed
    ora #DIGIT_ZERO             ; A = 0-9; add '0' to make char '0'-'9'
    sta INBUF,y                 ; store digit character at INBUF+Y, working right to left
    dey                         ; advance output position leftward
    beq B5_C8                   ; if Y=0: wrote last digit of X coord, now store sign
    cpy #$07
    beq B5_C8                   ; if Y=7: wrote last digit of Y coord, now store sign
    cpy #$0E                    ; if Y=14: wrote last digit of status, now store sign
    bne B5_A3                   ; else format another digit
B5_C8:
    pla                         ; pop sign or separator character (pushed in B5_9D / B5_A3)
    sta INBUF,y                 ; store sign/separator at current INBUF position
B5_CC:
    rts
    .res  50, $FF
    .byte $CD

; ==================================================================
; BANK 6: ReadMouse, MouseRWMemory, InitMouse, MOUSE_OUT, MOUSE_IN
;
; Three entry points via function code:
;   code=0 (B6_FN0): send command byte (already on the stack) to the MCU;
;   code=1 (B6_FN1): read a single byte from the MCU
;   code=2 (B6_FN2): ReadMouse: if mouse is on, send CMD_READ and read 5
;                    bytes (XLO,XHI,YLO,YHI,STATUS) into the screen holes
; ==================================================================
    .org $0600

B6_FN0:
    clv                         ; clear V: send command, no response
    bvc B6_SEND_CMD             ; always
B6_FN2:
    lda MOUSE_MODE,x            ; is mouse on (mode bit 0)?
    and #MOUSE_ENABLED
    beq B6_51                   ; no: switch to bank 0 and return
    lda #CMD_READ
    pha                         ; push MCU command
    lda #$05                    ; read 5 bytes
    sta MOUSE_CMD,x             ; using MOUSE_CMD for the byte counter
    lda #$7F
    adc #$01                    ; set V=1: read the 5 byte response
B6_SEND_CMD:
B6_WAIT_WRITE_ACK_CLR:
    lda PIA_PB,y                ; wait for MCU to clear WRITE_ACK (PB7=0)
    bmi B6_WAIT_WRITE_ACK_CLR
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$FF
    sta PIA_DDRA,y              ; configure PA for output (Apple II -> MCU)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
    pla                         ; pop command byte (pushed by B6_FN2 or caller)
    sta PIA_PA,y                ; drive command onto PA: MCU sees it
    lda PIA_PB,y
    ora #WRITE_REQ
    sta PIA_PB,y                ; assert WRITE_REQ
B6_WAIT_WRITE_ACK:
    lda PIA_PB,y                ; wait for WRITE_ACK (PB7=1)
    bpl B6_WAIT_WRITE_ACK
    and #<(~WRITE_REQ)
    sta PIA_PB,y                ; clear WRITE_REQ
    bvs CFG_PA_FOR_READ         ; V=1 (came via B6_FN2, command sent): go read MCU response
B6_48:
    bvs B6_51
    lda MOUSE_MODE,x            ; A = target bank in hi nibble
    lsr                         ; shift bank into lo nibble
    lsr
    lsr
    lsr
B6_51:
    clv                         ; clear V so bvc below is always taken
    sta ROM_BANK,x
    beq B6_59
    lda #$80                    ; negative function code -> do RTS jump after bank switch
B6_59:
    pha                         ; push function code ($80 or $00)
    bvc B6_BANK_SWITCH          ; always
    .res  20, $FF
B6_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    beq B6_FN0
    cmp #$02
    beq B6_FN2
    bne B6_FN1
TO_B6_48:
    beq B6_48                   ; always
B6_FN1:
    clv                         ; clear V: read 1 byte
CFG_PA_FOR_READ:
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$00
    sta PIA_DDRA,y              ; DDRA = $00: all PA pins are inputs (MCU -> Apple II)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
B6_WAIT_READ_REQ:
    lda PIA_PB,y                ; wait for READ_REQ from MCU (PB6=1)
    asl
    bpl B6_WAIT_READ_REQ
    lda PIA_PA,y                ; MCU has driven PA: read one byte of data
    bvs PUSH_MCU_BYTE           ; V=1 (ReadMouse, 5 bytes): push each byte read onto the stack
    sta MOUSE_CMD,x             ; V=0: store byte read in MOUSE_CMD
    bvc B6_AD                   ; always
PUSH_MCU_BYTE:
    pha
B6_AD:
    lda PIA_PB,y
    ora #READ_ACK
    sta PIA_PB,y                ; assert READ_ACK
B6_WAIT_READ_REQ_CLR:
    lda PIA_PB,y                ; wait for MCU to clear READ_REQ (PB6=0)
    asl
    bmi B6_WAIT_READ_REQ_CLR
    lda PIA_PB,y
    and #<(~READ_ACK)
    sta PIA_PB,y                ; clear READ_ACK
    bvc DONE_READING            ; V=0: only one byte; all done
    dec MOUSE_CMD,x             ; V=1: decrement byte counter
    bne B6_WAIT_READ_REQ        ; counter not zero: read next byte from MCU
    pla                         ; all bytes received: pop them from stack into screen holes
    sta MOUSE_STATUS,x
    pla
    sta MOUSE_YHI,x
    pla
    sta MOUSE_YLO,x
    pla
    sta MOUSE_XHI,x
    pla
    sta MOUSE_XLO,x
DONE_READING:
    lda #BANK0
    beq TO_B6_48                ; always
    .res  29, $FF
    .byte $C1

; ==================================================================
; BANK 7: ClampMouse, PosMouse, MouseSetVBLFrames, MouseSetVBLData
;
; MCU multi-byte write
;
; Pushes 1-5 data bytes onto the stack then calls WRITE_LOOP, which
; sends them one at a time to the MCU.
; ==================================================================
    .org $0700

B7_FN1:
    lda MOUSE_CMD,x             ; what command are we sending to the MCU?
    cmp #CMD_POS                ; is it PosMouse ($40)?
    beq B7_29                   ; yes: send mouse X/Y coords
    cmp #CMD_CLAMP              ; is it ClampMouse X ($60)?
    beq B7_18                   ; yes: send clamp bytes
    cmp #CMD_CLAMP+1            ; is it ClampMouse Y ($61)?
    beq B7_18                   ; yes: send clamp bytes
    cmp #CMD_VBL_FRAMES         ; is it MouseSetVBLFrames ($A0)?
    bne B7_41                   ; no: check other commands in B7_41
    pha                         ; yes: push command ($A0); rate byte already on stack
    lda #$02                    ; send 2 bytes (command + rate byte)
    bne B7_5D                   ; always
B7_18:
    lda CLAMP_MAX_HI            ; push clamping bounds
    pha
    lda CLAMP_MIN_HI
    pha
    lda CLAMP_MAX_LO
    pha
    lda CLAMP_MIN_LO
    bcs B7_38                   ; always; carry set from cmp above
B7_29:
    lda MOUSE_YHI,x             ; push mouse coords
    pha
    lda MOUSE_YLO,x
    pha
    lda MOUSE_XHI,x
    pha
    lda MOUSE_XLO,x
B7_38:
    pha                         ; push last data byte (CLAMP_MIN_LO or MOUSE_XLO)
    lda MOUSE_CMD,x
    pha
    lda #$05                    ; send 5 bytes: command + 4 data bytes
    bne B7_5D                   ; always
B7_41:
    and #$0C                    ; isolate command bits 3:2 (how many bytes to send)
    lsr
    lsr
    lsr                         ; bit 2 -> carry
    bcs B7_86                   ; bit 2 set: send the lo data bytes -> B7_86
    lsr                         ; one more shift: bit 3 -> carry
    bcc B7_57                   ; bit 3 clear: send command only -> B7_57
    lda CLAMP_MIN_HI            ; bit 3 set: push CLAMP_MIN_HI (+ cmd = 2 bytes)
    pha
    lda MOUSE_CMD,x             ; push command byte
    pha
    lda #$02                    ; send 2 bytes
    bne B7_5D                   ; always
B7_57:
    lda MOUSE_CMD,x             ; push command byte as only data byte
    pha
    lda #$01                    ; send 1 byte: command byte only
B7_5D:
    sta MOUSE_CMD,x             ; save byte count -- WRITE_LOOP decrements this to 0
    bne WRITE_LOOP              ; always; begin sending bytes to MCU
    .res  14, $FF
B7_BANK_SWITCH:
    lda PIA_PB,y
    and #$F1                    ; 1111 0001: clear bank select bits 1-3
    ora ROM_BANK,x              ; merge in target bank
    sta PIA_PB,y                ; * ROM BANK SWITCH *
; ==================================================================
    pla                         ; <- first instruction after switching TO THIS BANK
    bne B7_FN1
B7_DONE:
    lda #BANK0
    sta ROM_BANK,x
    pha                         ; function code 0: return success
    beq B7_BANK_SWITCH          ; always
B7_86:
    lsr                         ; shift carry to distinguish sub-cases
    bcs B7_9C                   ; carry set: send 4 bytes (min_hi, max_lo, min_lo, cmd)
    lda CLAMP_MAX_LO
    pha
    lda CLAMP_MIN_LO
    pha
    lda MOUSE_CMD,x
    pha
    lda #$03                    ; send 3 bytes (max_lo, min_lo, cmd)
    sta MOUSE_CMD,x             ; save count
    bne WRITE_LOOP              ; always
B7_9C:
    lda CLAMP_MIN_HI
    pha
    lda CLAMP_MAX_LO
    pha
    lda CLAMP_MIN_LO
    pha
    lda MOUSE_CMD,x
    pha
    lda #$04                    ; send 4 bytes
    sta MOUSE_CMD,x             ; save count
WRITE_LOOP:
B7_WAIT_WRITE_ACK_CLR:
    lda PIA_PB,y                ; wait for MCU to clear WRITE_ACK (PB7=0)
    bmi B7_WAIT_WRITE_ACK_CLR
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$FF
    sta PIA_DDRA,y              ; configure PA for output (Apple II -> MCU)
WRITE_NEXT_BYTE:
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
    pla                         ; pop next data byte from stack
    sta PIA_PA,y                ; drive byte onto PA: MCU sees it on its Port A
    lda PIA_PB,y
    ora #WRITE_REQ
    sta PIA_PB,y                ; assert WRITE_REQ
B7_WAIT_WRITE_ACK:
    lda PIA_PB,y                ; wait for WRITE_ACK (PB7=1)
    bpl B7_WAIT_WRITE_ACK
    and #<(~WRITE_REQ)
    sta PIA_PB,y                ; clear WRITE_REQ
    dec MOUSE_CMD,x             ; decrement byte counter
    beq B7_DONE                 ; all bytes sent -> return to bank 0
WAIT_BETWEEN_BYTES:
    lda PIA_PB,y                ; wait while MCU is still busy processing the previous byte (PB7 set)
    bmi WAIT_BETWEEN_BYTES
    bpl WRITE_NEXT_BYTE         ; MCU ready for next byte: loop back to send it
    .res  18, $FF
    .byte $CE
