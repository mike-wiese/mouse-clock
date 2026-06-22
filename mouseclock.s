; ============================================================================
; AppleMouse II + ThunderClock Plus combined card ROM
; Mike Wiese
; 2026-06-22
; ============================================================================
;
; A single de-banked ($C800 Thunderclock-style) ROM image that answers to BOTH
; the AppleMouse II identification/protocol AND the ThunderClock Plus clock
; identification/protocol. The two firmwares share one slot-derivation engine
; (COMMON / GETSLOT, taken from mouse2.s): every entry point reaches COMMON by
; a PC-relative branch from the always-mapped slot-ROM window ($Cn00-$CnFF),
; COMMON references $CFFF to claim the expansion ROM, derives the slot from the
; JSR return address, and RTSes into a worker trampoline in page $C9.
;
; Integration decisions:
;
;   1. CSW/KSW SHARING. One slot means one pair of character hooks, so the
;      mouse and clock share them, arbitrated by the MC_MODE screen hole
;      ('C' = clock, 'M' = mouse):
;        * PR#n inits MC_MODE = clock. The clock defaults to Mountain
;          Hardware Clock format, subsequent IN#n returns the time string in INBUF.
;        * Printing CHR$(1) selects mouse mode; subsequent IN#n returns
;          the formatted "+xxxxx,+yyyyy,+st" mouse position string in INBUF.
;        * The clock's WMODE and RMODE can be set using the usual characters,
;          which also selects clock mode.
;        * CR is handled by both without switching modes: the mouse
;          eats CRs, and the clock needs CR to terminate a "!..." time-set.
;
;   2. MOUSE screen holes ($0478..$07F8,X). 6 of the 8 are documented for the
;      AppleMouse and keep their published addresses. ROM_BANK ($0678) is no
;      longer needed on a de-banked card, so it is repurposed as MC_MODE.
;
;   3. CLOCK screen holes. The 4 pure temporaries (DOUT, LCNT1, LCNT2, TENS)
;      are moved to the high end of the INBUF page ($0200,X = $02Cx) so they
;      cannot clobber mouse state -- DOUT in particular had to move to free
;      $0678 for MC_MODE. The other 4 keep their screen-hole addresses for
;      compatibility:
;        * IRQEN1 ($0478) and IRQEN2 ($07F8): documented (rarely used)
;        * RMODE  ($05F8): named in the ThunderClock user manual
;        * WMODE  ($0578): set right before use; kept put for existing code
; ============================================================================

; ============================================================
; Screen hole usage  (NOTE: mouse and clock names alias the same bytes)
; ============================================================
; ---- mouse view (address,X where X = slot $Cn) ----
CLAMP_MIN_LO    = $0478
CLAMP_MAX_LO    = $04F8
CLAMP_MIN_HI    = $0578
CLAMP_MAX_HI    = $05F8

MOUSE_XLO       = $0478-$C0
MOUSE_YLO       = $04F8-$C0
MOUSE_XHI       = $0578-$C0
MOUSE_YHI       = $05F8-$C0
; ROM_BANK         = $0678-$C0
MOUSE_CMD       = $06F8-$C0
MOUSE_STATUS    = $0778-$C0
MOUSE_MODE      = $07F8-$C0

MOUSE_ENABLED   = 1<<0

; ---- clock view (address,X where X = slot $Cn) ----
CLOCK_IRQEN1    = $0478-$C0
; CLOCK_BSRDUR     = $04F8-$C0
CLOCK_WMODE     = $0578-$C0
CLOCK_RMODE     = $05F8-$C0
; CLOCK_DOUT       = $0678-$C0
; CLOCK_LCNT1      = $06F8-$C0
; CLOCK_LCNT2      = $0778-$C0
CLOCK_IRQEN2    = $07F8-$C0
; clock temporaries moved to INBUF so they will not overwrite mouse state
CLOCK_DOUT      = $02C0
CLOCK_LCNT1     = $02C1
CLOCK_LCNT2     = $02C2
CLOCK_TENS      = $02C3

; ---- mouse clock combo view (address,X where X = slot $Cn) ----
MC_MODE         = $0678-$C0     ; 'C' = clock mode, 'M' = mouse mode

; ============================================================
; 6821 PIA registers (AppleMouse, at $C08x,Y where Y = slot * $10)
; ============================================================
PIA_DDRA        = $C084         ; was $C080
PIA_PA          = $C084         ; was $C080
PIA_CRA         = $C085         ; was $C081
PIA_DDRB        = $C086         ; was $C082
PIA_PB          = $C086         ; was $C082
PIA_CRB         = $C087         ; was $C083
SELECT_DDR      = $FB
SELECT_PR       = $04
READ_ACK        = $10
WRITE_REQ       = $20
READ_REQ        = $40
WRITE_ACK       = $80

; ---- MCU command byte values -------------------------------
CMD_SET         = $00
CMD_READ        = $10
CMD_SERVE       = $20
CMD_CLEAR       = $30
CMD_POS         = $40
CMD_INIT        = $50
CMD_CLAMP       = $60
CMD_HOME        = $70
CMD_TRANSPARENT = $80
CMD_VBL_DATA    = $90
CMD_VBL_FRAMES  = $A0
CMD_CONFIG      = $B0
CMD_ACK_IRQ     = $C0
CMD_RW_MEMORY   = $F0

; ============================================================
; uPD1990AC control register (ThunderClock, at $C08x,Y)
; ============================================================
RTC_CONTROL     = $C080
RTC_REGISTER_HOLD = %000 << 3
RTC_SHIFT       = %001 << 3
RTC_TIME_SET    = %010 << 3
RTC_TIME_READ   = %011 << 3
RTC_TP_64HZ     = %100 << 3
RTC_TP_256HZ    = %101 << 3
RTC_TP_2048HZ   = %110 << 3
RTC_CLK         = 1 << 1
RTC_STROBE      = 1 << 2
RTC_TRANSDUCER  = 1 << 5
RTC_IRQ_ENABLE  = 1 << 6

; ---- INBUF string characters -------------------------------
PLUS_SIGN       = $AB
MINUS_SIGN      = $AD
COMMA           = $AC
DIGIT_ZERO      = $B0

; ---- System / monitor addresses ----------------------------
IORTS           = $FF58
HOME            = $FC58
COUT            = $FDED
F8VERSION       = $FBB3

; ---- Soft switches -----------------------------------------
KBD             = $C000
RDVBLBAR        = $C019
GRAPHICS        = $C050
TEXT            = $C051
NOMIX           = $C052
PAGE1           = $C054
LORES           = $C056
HIRES           = $C057
LINE191         = $3FD0

; ---- RAM / zero page ---------------------------------------
ZP_TEMP1        = $06
ZP_TEMP2        = $07
ZP_TEMP3        = $08
CSWL            = $36
CSWH            = $37
KSWL            = $38
KSWH            = $39
INBUF           = $0200
BCD_HI          = $0220
BCD_LO          = $0221
MSLOT           = $07F8

    .setcpu "6502"

; To be recognized as a mouse need (Mouse Technical Note #5)
;   $Cn05 = $38  Pascal ID byte
;   $Cn07 = $18  Pascal ID byte
;   $Cn0B = $01  Pascal ID byte
;   $Cn0C = $20  X-Y pointing device, type zero
;   $CnFB = $D6  AppleMouse II card id byte

; To be recognized as a clock, need the following bytes:
;   $Cn00 = $08
;   $Cn02 = $28
;   $Cn04 = $58
;   $Cn06 = $70

; ==================================================================
; Slot-ROM page ($C800, mirrored at $Cn00)
; ==================================================================
    .org $C800

    php                         ; $08 = clock
    sei
    plp                         ; $28 = clock
; usually V=0 but either way will end up at MAIN
    bvc TO_MAIN                 ; $xx $58 = clock  ($Cn5D relay -> MAIN)
    sec                         ; $38 = mouse
    bvs MAIN                    ; $70 $18 = clock mouse

; ------------------------------------------------------------------
; $Cn08  PRODOS_READ_ENTRY, aka RDTCP
; ProDOS requires the clock read entry point to be at $Cn08
; ------------------------------------------------------------------
PRODOS_READ_ENTRY:
    clc
    bcc PRODOS_READ
; ------------------------------------------------------------------
; $Cn0B  PRODOS_WRITE_ENTRY, aka WTTCP
; ProDOS requires the clock write entry point to be at $Cn0B
; ------------------------------------------------------------------
PRODOS_WRITE_ENTRY:
    ora ($20,x)                 ; $01 $20 = mouse
    clv                         ; $B8 Pascal init  (not implemented)
    bvc PRODOS_WRITE            ; $50 $50 Pascal read/write (not implemented)
    .byte <PASCAL_ERR_50        ; $50 Pascal status (not implemented)
    .byte $00
    .byte <SetMouse
    .byte <ServeMouse
    .byte <ReadMouse
    .byte <ClearMouse
    .byte <PosMouse
    .byte <ClampMouse
    .byte <HomeMouse
    .byte <InitMouse
    .byte <MouseRWMemory
    .byte <MouseCredits
    .byte <MouseSetVBLData      ; aka TimeData in Mouse TN #2
    .byte <MouseSetVBLFrames
    .byte <MouseSetConfig
    .byte <MouseAckIRQ

; ==================================================================
; MAIN must be at $Cn20, the main entry does "bvs $18" to here
; PR#n / IN#n path
; ==================================================================
MAIN:
    pha                         ; save entry A
    lda #<(T_B4F0-1)

; ==================================================================
; SAVE_STATE -- register save for the I/O-hook / clock firmware entry points
; (MAIN, MC_IN, MC_OUT, PRODOS_READ_ENTRY, PRODOS_WRITE_ENTRY). Those entries
; all save A with PHA, and then LDA the trampoline offset before branching here.
;
; SAVE_STATE pushes P, the trampoline offset, Y and X, then reads the
; offset and entry A back into Y and A via a stack walk, leaving the saved
; frame on the stack. The 5-byte frame is, top->bottom:
;     X_entry, Y_entry, offset, P_entry, A_entry
; Finally it pushes entry A once more as the "char" on top of that frame, like
; the original mouse/clock firmware, so the workers can just PLA it; then falls
; into COMMON.
; ==================================================================
SAVE_STATE:
    php                         ; save processor status
    sei                         ; disable interrupts for the entire call, restored in RESTORE_STATE
    pha                         ; save A (= trampoline offset)
    tya
    pha                         ; save Y
    txa
    pha                         ; save X
    tsx                         ; recover entry A + offset, leaving the frame intact
    pla                         ; skip over saved X
    pla                         ; skip over saved Y
    pla                         ; pop saved trampoline offset
    tay                         ; Y = offset
    pla                         ; skip saved flags
    pla                         ; A = entry A
    txs                         ; restore stack (saved frame stays on it)
    pha                         ; push entry A as the char (workers pop it)
                                ; fall into COMMON

; ==================================================================
; COMMON -- shared entry epilogue. Entered two ways: the dispatch stubs branch
; here with the trampoline offset in Y and A = entry A; SAVE_STATE falls in with
; the same register setup (plus the saved frame on the stack).
; ==================================================================
COMMON:
    php
    sei                         ; disable interrupts while running expansion ROM before setting MSLOT
    tax                         ; stash entry A in X (preserved to the worker)
    lda $CFFF                   ; disable $C800 expansion ROMs
    jsr GETSLOT                 ; this opcode fetch from $Cnxx re-enables our $C800 ROM
GETSLOT:
    pla                         ; discard return-address low byte
    pla                         ; A = return-address high byte = $Cn
    sta MSLOT                   ; MSLOT = $Cn
    plp                         ; restore interrupt state
    lda #>(T_B3)                ; high byte of the trampoline page ($C9)
    pha
    tya                         ; Y = <(trampoline-1) selector
    pha                         ; RTS target now on the stack
    txa                         ; restore entry A from X (SLOTXY preserves it)
    jmp SLOTXY                  ; X = $Cn, Y = $n0, then RTS into the trampoline

PRODOS_READ:
    pha
    lda #<(T_CLOCK_READ-1)
    bne SAVE_STATE              ; always

; ------------------------------------------------------------------
; PASCAL_ERR_50 must be at $Cn50, pascal entries are pointing here
; ------------------------------------------------------------------
    .res  $C850 - *, $FF
PASCAL_ERR_50:
    ldx #$03                    ; "illegal I/O request"
    sec
    rts

MC_IN:                          ; mouse/clock KSW hook
    pha
    lda #<(T_MC_IN-1)
    bne SAVE_STATE              ; always

; ------------------------------------------------------------------
; TO_MAIN must be at $Cn5D, the main entry does "bvc $58" to here
; ------------------------------------------------------------------
    .res  $C85D - *, $FF
TO_MAIN:
    bvc MAIN                    ; always since V=0 got us here

; ------------------------------------------------------------------
; PRODOS_WRITE must be at $Cn60, PRODOS_WRITE_ENTRY does "bvc $50" to here
; ------------------------------------------------------------------
    .res  $C860 - *, $FF
PRODOS_WRITE:                   ; ProDOS passes A = '#', but A is trashed on entry
    lda #$A3                    ; restore A = '#'
MC_OUT:                         ; mouse/clock CSW hook
    pha
    lda #<(T_MC_OUT-1)
    bne SAVE_STATE              ; always

; ==================================================================
; API dispatch stubs (slot page; addressed via the $Cn12-$Cn1F table). These
; do NOT preserve registers (mouse API convention), so they load the trampoline
; offset directly into Y and branch to COMMON.
; ==================================================================
SetMouse:                       ; A = mode ($00-$0F)
    cmp #$10
    bcs Exit                    ; C=1 on illegal mode
    sta MOUSE_MODE,x
SEND_B3:                        ; enter with A = MCU command, X = $Cn -> B3
    sta MOUSE_CMD,x
    ldy #<(T_B3-1)
    bne COMMON                  ; always
ServeMouse:
    lda MSLOT
    pha                         ; preserve caller's MSLOT across the call
    ldy #<(T_SERVE-1)
    bne COMMON                  ; always
ReadMouse:
    ldy #<(T_B6-1)
    bne COMMON                  ; always
InitMouse:
    ldy #<(T_B2-1)
    bne COMMON                  ; always
MouseCredits:                   ; print the credits
    ldy #<(T_B1F0-1)
    bne COMMON                  ; always
MouseRWMemory:                  ; A=0 read, A=1 write
    and #$01
    ora #CMD_RW_MEMORY
    sta MOUSE_CMD,x             ; X = $Cn
    ldy #<(T_B1F1-1)
    bne COMMON                  ; always
ClearMouse:
    lda #CMD_CLEAR
    bne SEND_B3                 ; always
HomeMouse:
    lda #CMD_HOME
    bne SEND_B3                 ; always
MouseAckIRQ:
    lda #CMD_ACK_IRQ
    bne SEND_B3                 ; always
MouseSetConfig:
    and #$0F
    ora #CMD_CONFIG
    bne SEND_B3                 ; always ($Bx != 0)
MouseSetVBLData:
    and #$0F
    ora #CMD_VBL_DATA
SEND_B7:                        ; enter with A = MCU command, X = $Cn -> B7
    sta MOUSE_CMD,x
    ldy #<(T_B7-1)
    bne COMMON                  ; always
ClampMouse:                     ; A=0 X-bounds, A=1 Y-bounds
    and #$01
    ora #CMD_CLAMP
    bne SEND_B7                 ; always

; ------------------------------------------------------------------
; PASCAL_ERR_B8 must be at $CnB8, pascal init offset
; ------------------------------------------------------------------
    .res  $C8B8 - *, $FF
PASCAL_ERR_B8:
    ldx #$03
    sec
Exit:
    rts

PosMouse:
    lda #CMD_POS
    bne SEND_B7                 ; always ($9x != 0)
MouseSetVBLFrames:              ; A = frames per IRQ
    pha                         ; push N (rate) -- left on the stack for B7
    lda #CMD_VBL_FRAMES
    bne SEND_B7                 ; always

; ==================================================================
; SYNC_LOOP -- Apple II / II+ VBL sync polling loop (from mouse2.s).
; Lives in the slot-ROM page so it runs in the always-mapped $Cn00 window:
; B2_HIRES_SYNC enters it by RTS to $Cn:<SYNC_LOOP>, so its $CFFF reads (which
; latch the PAL sync bit and disable the $C800 expansion ROM) cannot deselect
; the code executing here. SYNC_EXIT jmps back to B2_D7 in the expansion ROM
; ==================================================================
SYNC_LOOP:
    inc ZP_TEMP1                ; [5] increment 24-bit timeout counter
    bne SL_B8                   ; [2/3]
    inc ZP_TEMP2                ; [5]
    bne SL_BA                   ; [2/3]
    inc ZP_TEMP3                ; [5]
    lda ZP_TEMP3                ; [3]
    cmp #$01                    ; [2]
    bcc SL_C0                   ; [2/3]
    bcs SYNC_EXIT               ; [2/3] timeout: give up
SL_B8:
    php                         ; [3] match the mid-byte increment path's cycles
    plp                         ; [4]
SL_BA:
    php                         ; [3] match the hi-byte increment path's cycles
    plp                         ; [4]
    lda #$00                    ; [2]
    lda $00                     ; [3]
SL_C0:
    lda $CFFF                   ; [4] trigger PAL latch (also disables C800 ROM)
    lda PIA_PB,y                ; [4] read the sync latch at PB0
    lsr                         ; [2] sync bit /D0 -> carry
    nop                         ; [2] pad to the 16-cycle sentinel spacing
    nop                         ; [2]
    bcs SYNC_LOOP               ; [2/3] missed the first sentinel: keep polling
    lda $CFFF                   ; [4] second trigger, 16 cycles after the first
    lda PIA_PB,y                ; [4] read the sync latch again
    lsr                         ; [2] /D0 -> carry
    lda $00                     ; [3] timing filler
    nop                         ; [2]
    bcs SYNC_LOOP               ; [2/3] missed the second sentinel: keep polling
SYNC_EXIT:                      ; matched both sentinels -> VBL is imminent
    jmp B2_D7                   ; back into the B2 worker

    .res  $C8FB - *, $FF        ; pad to the mouse id byte
MOUSE_ID:
    .byte $D6                   ; $D6 mouse id byte ($CnFB)
    .res  $C900 - *, $FF        ; pad out the slot-ROM page

; ==================================================================
; SLOTXY / SLOTY -- recover X = $Cn and Y = $n0 from MSLOT. Preserves A.
; ==================================================================
SLOTXY:
    ldx MSLOT                   ; X = $Cn
SLOTY:
    pha
    txa
    asl
    asl
    asl
    asl
    tay                         ; Y = $n0
    pla
    rts

; ==================================================================
; Worker trampolines. COMMON's RTS target lands here with
; X = $Cn and Y = $n0 already set.
; ==================================================================
T_B3:
    jmp B3_FN0
T_B7:
    jmp B7_FN1
T_B6:
    jmp B6_FN2
T_B2:
    jmp B2_FN0
T_B1F0:
    jmp B1_FN0
T_B4F0:
    jmp B4_FN0
T_MC_IN:
    jmp B4_FN2
T_MC_OUT:
    jmp B4_FN1
T_CLOCK_READ:
    jmp PATCH_P8_YT
T_B1F1:
    jmp B1_FN1
T_SERVE:                        ; ServeMouse: set the command now X = $Cn is valid
    lda #CMD_SERVE
    sta MOUSE_CMD,x
    jmp B3_FN0

; ##################################################################
; ## MOUSE WORKER BODIES (merged verbatim from mouse2.s)          ##
; ##################################################################

; ==================================================================
; B1: MouseCredits (B1_FN0) and MouseRWMemory (B1_FN1)
; ==================================================================
B1_FN0:                         ; print the credits
    tya                         ; save Y
    pha
    jsr HOME                    ; clear screen
    ldy #<-CRED_LEN             ; index from -length up to 0 (no NUL terminator)
B1_13:
    lda CreditsEnd-256,y        ; read character (negative-indexed off the end)
    jsr COUT                    ; print character
    iny
    bne B1_13                   ; loop until Y wraps to 0
    pla
    tay                         ; Y = $n0
    clc                         ; EXIT_OK
    rts

; ---- MouseRWMemory: read/write one byte of MCU memory ----------------
B1_FN1:
    lda MOUSE_CMD,x             ; send the command byte
    jsr SEND_MCU_CMD            ; first byte: configure Port B + write
    lda CLAMP_MIN_LO            ; send the address low byte
    jsr WRITE_MCU_BYTE
    lda CLAMP_MAX_LO            ; send the address high byte
    jsr WRITE_MCU_BYTE
    ror MOUSE_CMD,x             ; C = command bit 0: 0=read, 1=write
    bcc B1_READ
    lda CLAMP_MIN_HI            ; write: send the data byte
    jsr WRITE_MCU_BYTE
    clc                         ; EXIT_OK
    rts
B1_READ:
    jsr B6_FN1                  ; read: fetch one byte back (into MOUSE_CMD)
    lda MOUSE_CMD,x
    sta CLAMP_MIN_HI
    clc                         ; EXIT_OK
    rts

; ==================================================================
; B2: InitMouse
; ==================================================================
B2_FN0:
    lda #CMD_INIT               ; call #1: CMD_INIT resets the MCU
    jsr SEND_MCU_CMD
    jsr B6_FN1                  ; call #2: read a byte back (version probe)
    lda F8VERSION
    cmp #$06                    ; IIe or later ($FBB3 = 6)?
    bne B2_HIRES_SYNC           ; no (II / II+): use the HIRES/PAL sync method
B2_26:
    lda RDVBLBAR
    bmi B2_26                   ; wait for VBL low (blanking)
B2_2B:
    lda RDVBLBAR
    bpl B2_2B                   ; wait for VBL high (end of blanking)
B2_30:
    lda RDVBLBAR
    bmi B2_30                   ; wait for VBL low again (start of blanking)
    lda #CMD_INIT               ; call #3: restart the (now phase-locked) timer
    jsr SEND_MCU_CMD
    clc                         ; EXIT_OK
    rts
B2_HIRES_SYNC:
    lda ZP_TEMP1                ; save zp temps + Y on the stack
    pha
    lda ZP_TEMP2
    pha
    tya
    pha
    lda #$20                    ; ZP_TEMP1/2 -> HIRES page 1 ($2000)
    sta ZP_TEMP2
    ldy #$00
    sty ZP_TEMP1
B2_57:
    lda #$00                    ; clear HIRES page 1: only the sentinels keep D0=1
B2_59:
    sta (ZP_TEMP1),y
    iny
    bne B2_59
    inc ZP_TEMP2
    lda ZP_TEMP2
    cmp #$40
    bne B2_57
    pla
    tay                         ; restore Y = $n0
    lda ZP_TEMP3
    pha                         ; save ZP_TEMP3
    lda #$01                    ; two sentinels on the last video line, 16 bytes apart
    sta LINE191
    sta LINE191+16
    lda HIRES                   ; switch to HIRES graphics, page 1, full screen
    lda PAGE1
    lda NOMIX
    lda GRAPHICS                ; A = floating bus (~0) just after the video read
    sta ZP_TEMP1                ; zero the 24-bit timeout counter
    sta ZP_TEMP2
    sta ZP_TEMP3
    lda MSLOT                   ; enter the slot-ROM mirror of SYNC_LOOP (RTS to
    pha                         ; $Cn:SYNC_LOOP) so the loop's $CFFF reads cannot
    lda #<(SYNC_LOOP-1)         ; pull our $C800 ROM out from under it -- SYNC_LOOP
    pha                         ; lives in the slot page, so $Cn:<SYNC_LOOP> is right
    rts
B2_D7:
    pla                         ; restore zp temps
    sta ZP_TEMP3
    pla
    sta ZP_TEMP2
    pla
    sta ZP_TEMP1
    lda #CMD_INIT               ; call #3: restart the (now phase-locked) timer
    jsr SEND_MCU_CMD
    lda TEXT                    ; restore the text + lo-res display
    lda LORES
    clc                         ; EXIT_OK
    rts

; ==================================================================
; B3: SetMouse, ServeMouse, ClearMouse, HomeMouse, AckMouseIRQ
; ==================================================================
B3_FN0:
    lda MOUSE_CMD,x             ; ServeMouse needs a response read after the write
    cmp #CMD_SERVE
    bne B3_0D
    lda #$7F
    adc #$01                    ; V=1 ($7F+1 overflows): response read needed
    bvs B3_SEND                 ; always
B3_0D:
    clv                         ; V=0: no response read needed
B3_SEND:
    lda MOUSE_CMD,x
    jsr SEND_MCU_CMD            ; configure Port B + send the command (V preserved)
    bvs READ_MCU_RESPONSE       ; ServeMouse: read the interrupt-status byte
    lda MOUSE_CMD,x
    cmp #CMD_CLEAR              ; ClearMouse: also zero the position screen holes
    bne B3_SUCCESS
    lda #$00
    sta MOUSE_XHI,x
    sta MOUSE_XLO,x
    sta MOUSE_YHI,x
    sta MOUSE_YLO,x
B3_SUCCESS:
    clc                         ; EXIT_OK
    rts
READ_MCU_RESPONSE:
    jsr READ_MCU_BYTE           ; read the interrupt-status byte
    sta MOUSE_CMD,x
    lda MOUSE_STATUS,x
    and #$F1                    ; clear old interrupt bits
    ora MOUSE_CMD,x             ; merge in interrupt bits from MCU
    sta MOUSE_STATUS,x
    and #$0E                    ; any interrupt source bits set?
    tax                         ; keep the result across the MSLOT restore (X is free)
    pla                         ; restore the caller's MSLOT (saved in ServeMouse)
    sta MSLOT
    txa                         ; Z = 0 if any interrupt bits were set
    bne B3_SUCCESS              ; yes -> C=0 (mouse interrupt)
    sec                         ; no  -> C=1 (not a mouse interrupt)
    rts

; ==================================================================
; B4: I/O hooks
;   B4_FN0: PR#n / IN#n -- install CSW / KSW hook then run hook code
;   B4_FN1: MC_OUT      -- handle one output character
;   B4_FN2: MC_IN       -- format mouse X-Y position + status into INBUF
; ==================================================================
; These reach RESTORE_STATE with the canonical SAVE_STATE frame intact on the
; stack (X_entry, Y_entry, offset, P_entry, A_entry). The entry character is
; A_entry (frame slot 5); B4_FN2/B5_FN0 (MC_IN) overwrite the frame's
; X/Y/A slots in place so RESTORE_STATE returns the formatted line's CR and
; length to KEYIN instead of the entry registers.
B4_FN0:
    cpx CSWH                    ; is CSWH pointing to our slot?
    bne B4_31
    lda #<MC_OUT
    cmp CSWL                    ; CSWL already MC_OUT?
    beq B4_31                   ; yes: assume IN#n, check KSW
    sta CSWL                    ; no: install MC_OUT hook and handle char
    lda #'C'                    ; default MC_MODE = clock mode
    sta MC_MODE,x
    lda #$5E                    ; default CLOCK_WMODE = '^'
    sta CLOCK_WMODE,x
    lda #$00                    ; default read mode = 0 (Mountain Clock format)
    sta CLOCK_RMODE,x
B4_FN1:                         ; X is still $Cn from COMMON's SLOTXY
    pla                         ; A = character to output (char SAVE_STATE pushed)
    and #$7F                    ; strip the high bit
    cmp #2                      ; 0 or 1 ?
    bcc MOUSE_OUT01             ; yes: always send to mouse
    cmp #$0D                    ; CR ?
    bne @TO_CLOCK               ; no: always send to clock
    lda MC_MODE,x               ; yes: check MC_MODE
    cmp #'M'                    ; in mouse mode ?
    beq B4_85                   ; yes: exit, mouse eats CRs
    lda #$0D                    ; no: restore CR
@TO_CLOCK:
    jmp CLK_W_CHAR_SKIP         ; send char to clock
MOUSE_OUT01:
    and #MOUSE_ENABLED          ; only keep "mouse is on" bit
    sta MOUSE_MODE,x
    beq B4_26                   ; turn mouse off using CMD_SET with A = 0
    lda #'M'
    sta MC_MODE,x               ; set MC_MODE to mouse mode only when turning mouse ON
    lda #CMD_TRANSPARENT        ; turn mouse on using CMD_TRANSPARENT
B4_26:
    jsr SEND_MCU_CMD            ; A = command byte: send it to the MCU
B4_85:
    jmp RESTORE_STATE
B4_31:
    cpx KSWH                    ; is KSWH pointing to our slot?
    bne B4_FN1                  ; no: (should not happen) handle output char
    lda #<MC_IN
    sta KSWL                    ; install MC_IN hook, fall thru
B4_FN2:
    pla                         ; discard the char SAVE_STATE pushed
    lda MC_MODE,x
    cmp #'M'                    ; are we in mouse mode ?
    beq MOUSE_IN2
    jmp READ_TIME_SKIP
MOUSE_IN2:
    lda MOUSE_MODE,x
    and #MOUSE_ENABLED          ; is mouse on (mode bit 0)?
    bne B4_54
; bne not taken: A = 0 so we can comment out next line
;    lda #$00                   ; off: zero the position screen holes (frame kept)
    sta MOUSE_XLO,x
    sta MOUSE_XHI,x
    sta MOUSE_YLO,x
    sta MOUSE_YHI,x
    lda #$C0                    ; button down / was down (mouse off case)
    sta MOUSE_STATUS,x
    bne B5_FN0                  ; always
B4_54:
    lda #CMD_READ               ; send CMD_READ to the MCU
    jsr SEND_MCU_CMD
    jsr READ_MCU_BYTE           ; read the 5-byte response into the screen holes (frame kept)
    sta MOUSE_XLO,x
    jsr READ_MCU_BYTE
    sta MOUSE_XHI,x
    jsr READ_MCU_BYTE
    sta MOUSE_YLO,x
    jsr READ_MCU_BYTE
    sta MOUSE_YHI,x
    jsr READ_MCU_BYTE
    sta MOUSE_STATUS,x

; ==================================================================
; B5: MC_IN -- format "+xxxxx,+yyyyy,+st" into INBUF
; ==================================================================
B5_FN0:
    ldy MOUSE_XLO,x             ; format X coordinate
    lda MOUSE_XHI,x
    tax
    tya
    ldy #$05                    ; digit position in INBUF for X
    jsr B5_FN1
    ldx MSLOT                   ; X = $Cn
    ldy MOUSE_YLO,x             ; format Y coordinate
    lda MOUSE_YHI,x
    tax
    tya
    ldy #$0C                    ; digit position for Y
    jsr B5_FN1
    ldx MSLOT                   ; X = $Cn
    lda KBD                     ; encode the status field
    asl                         ; key-down flag -> carry
    php                         ; save carry
    lda MOUSE_STATUS,x
    rol A
    rol A
    rol A                       ; move + button flags into A[1:0]
    and #$03
    eor #$03                    ; invert
    sec
    adc #$00                    ; range 1-4
    plp                         ; restore key-down flag (C=1 formats with '-')
    ldx #$00                    ; hi byte for status = 0
    ldy #$10                    ; digit position for status
    jsr B5_91
    ldx #$11                    ; offset for CR just past the status field
    jsr RETCR

; ==================================================================
; RESTORE_STATE -- restore the registers saved by SAVE_STATE and return to the
; I/O-hook caller. Reached by B5_FN0 (fall-through), B4_85 (jmp) and the clock
; FINALIZE (jmp).
;
; Consumes the canonical 5-byte SAVE_STATE frame, top->bottom:
;     X_entry, Y_entry, offset, P_entry, A_entry
; Pop X and Y, discard the offset, restore the flags (plp -- needed mainly to
; restore the I flag that SAVE_STATE's sei cleared), then load A. The final pla
; loads A after the plp, so N/Z reflect A rather than P_entry; that's fine here
; (this is not an interrupt handler, and the original firmware did not guarantee
; the caller's flags either). C/V/I/D are restored from P_entry.
;
; All workers present this frame correctly: the mouse B4_FN1/B4_FN2/B5_FN0 and
; the clock CLK_W_CHAR/READ_TIME/FMTFINAL paths.
; ==================================================================
RESTORE_STATE:
    pla
    tax                         ; restore X
    pla
    tay                         ; restore Y
    pla                         ; discard offset
    plp                         ; restore flags from P_entry (incl I)
    pla                         ; restore A (clobbers N/Z; C/V/I/D kept)
    rts

; ==================================================================
; RETCR -- shared MC_IN / clock-read line return. Stores the CR terminator at
; INBUF,x and overwrites the saved frame so RESTORE_STATE hands the caller
; X = length and A = CR; Y is left = Y_entry.
; Entry: X = offset of the CR in INBUF (= the line length).
; NOTE: RETCR is JSR'd, so its own 2-byte return address sits on TOP of the
; canonical frame -- the frame slots are therefore at $0103,x (X_entry) and
; $0107,x (A_entry), not $0101,x / $0105,x.
; ==================================================================
RETCR:
    lda #$8D                    ; CR
    sta INBUF,x                 ; terminator at INBUF[length]
    txa                         ; A = length
    tsx                         ; X = SP (RETCR return addr is at $0101,x/$0102,x)
    sta $0103,x                 ; X_entry slot := length
    lda #$8D
    sta $0107,x                 ; A_entry slot := CR
    rts
B5_FN1:                         ; format signed 16-bit value (A=lo, X=hi, Y=pos)
    cpx #$80                    ; negative?
    bcc B5_91                   ; no
    eor #$FF                    ; two's-complement negate lo
    adc #$00
    pha
    txa                         ; negate hi
    eor #$FF
    adc #$00
    tax
    pla
    sec                         ; C=1: value is negative
B5_91:
    sta BCD_LO                  ; abs(value) lo
    stx BCD_HI                  ; abs(value) hi
    lda #PLUS_SIGN
    bcc B5_9D                   ; positive -> '+'
    lda #MINUS_SIGN             ; negative -> '-'
B5_9D:
    pha                         ; save sign char (stored after digits)
    lda #COMMA
    sta INBUF+1,y               ; comma separator after this field
B5_A3:
    ldx #$11                    ; 17-step binary -> decimal
    lda #$00
    clc
B5_A8:
    rol
    cmp #$0A
    bcc B5_AF
    sbc #$0A
B5_AF:
    rol BCD_LO
    rol BCD_HI
    dex
    bne B5_A8
    ora #DIGIT_ZERO             ; digit -> ASCII
    sta INBUF,y                 ; store digit (right to left)
    dey
    beq B5_C8                   ; finished X coord -> store sign
    cpy #$07
    beq B5_C8                   ; finished Y coord -> store sign
    cpy #$0E                    ; finished status -> store sign
    bne B5_A3
B5_C8:
    pla                         ; sign/separator
    sta INBUF,y
    rts

; ==================================================================
; B6: ReadMouse and single-byte MCU read
; ==================================================================
B6_FN2:                         ; ReadMouse
    lda MOUSE_MODE,x
    and #MOUSE_ENABLED          ; is mouse on (mode bit 0)?
    beq B6_INACTIVE
    lda #CMD_READ
    jsr SEND_MCU_CMD            ; configure Port B + send CMD_READ
    jsr READ_MCU_BYTE           ; read the 5-byte response into the screen holes
    sta MOUSE_XLO,x
    jsr READ_MCU_BYTE
    sta MOUSE_XHI,x
    jsr READ_MCU_BYTE
    sta MOUSE_YLO,x
    jsr READ_MCU_BYTE
    sta MOUSE_YHI,x
    jsr READ_MCU_BYTE
    sta MOUSE_STATUS,x
B6_INACTIVE:
    clc                         ; EXIT_OK
    rts
B6_FN1:                         ; read a single byte into MOUSE_CMD
    jsr READ_MCU_BYTE
    sta MOUSE_CMD,x
    rts

; ==================================================================
; B7: multi-byte MCU write (ClampMouse, PosMouse, and friends)
; ==================================================================
B7_FN1:
    lda MOUSE_CMD,x
    cmp #CMD_POS                ; PosMouse?
    beq B7_29
    cmp #CMD_CLAMP              ; ClampMouse X?
    beq B7_18
    cmp #CMD_CLAMP+1            ; ClampMouse Y?
    beq B7_18
    cmp #CMD_VBL_FRAMES         ; MouseSetVBLFrames?
    bne B7_41
    pha                         ; push command; rate byte already on stack
    lda #$02                    ; send 2 bytes
    bne B7_5D                   ; always
B7_18:
    lda CLAMP_MAX_HI            ; push clamping bounds
    pha
    lda CLAMP_MIN_HI
    pha
    lda CLAMP_MAX_LO
    pha
    lda CLAMP_MIN_LO
    bcs B7_38                   ; always (carry set from the cmp above)
B7_29:
    lda MOUSE_YHI,x             ; push mouse coords
    pha
    lda MOUSE_YLO,x
    pha
    lda MOUSE_XHI,x
    pha
    lda MOUSE_XLO,x
B7_38:
    pha                         ; last data byte
    lda MOUSE_CMD,x
    pha                         ; command byte
    lda #$05                    ; send 5 bytes
    bne B7_5D                   ; always
B7_41:
    and #$0C                    ; command bits 3:2 = how many bytes to send
    lsr
    lsr
    lsr                         ; bit 2 -> carry
    bcs B7_86
    lsr                         ; bit 3 -> carry
    bcc B7_57                   ; neither: command only
    lda CLAMP_MIN_HI
    pha
    lda MOUSE_CMD,x
    pha
    lda #$02
    bne B7_5D                   ; always
B7_57:
    lda MOUSE_CMD,x
    pha
    lda #$01                    ; command byte only
B7_5D:
    sta MOUSE_CMD,x             ; byte count (WRITE_LOOP decrements to 0)
    bne WRITE_LOOP              ; always
B7_86:
    lsr
    bcs B7_9C
    lda CLAMP_MAX_LO
    pha
    lda CLAMP_MIN_LO
    pha
    lda MOUSE_CMD,x
    pha
    lda #$03                    ; send 3 bytes
    sta MOUSE_CMD,x
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
    sta MOUSE_CMD,x
WRITE_LOOP:                     ; bytes on the stack (command on top), count in MOUSE_CMD,x
    pla                         ; first byte = the command
    jsr SEND_MCU_CMD            ; configure Port B + write it
    dec MOUSE_CMD,x
    beq B7_DONE                 ; command-only write
B7_NEXT:
    pla                         ; next data byte
    jsr WRITE_MCU_BYTE          ; Port B already configured
    dec MOUSE_CMD,x
    bne B7_NEXT
B7_DONE:
    clc                         ; EXIT_OK
    rts

; ==================================================================
; SEND_MCU_CMD / WRITE_MCU_BYTE -- write one byte to the MCU.
; ==================================================================
SEND_MCU_CMD:
    pha                         ; save the byte
    lda PIA_CRB,y               ; configure Port B handshake outputs
    and #SELECT_DDR
    sta PIA_CRB,y
    lda #$3E
    sta PIA_DDRB,y              ; DDRB = 0011 1110: PB1-PB5 outputs
    lda PIA_CRB,y
    ora #SELECT_PR
    sta PIA_CRB,y
    pla                         ; restore the byte
WRITE_MCU_BYTE:
    pha                         ; save the byte
WB_WAIT_ACK_CLR:
    lda PIA_PB,y                ; wait for MCU to clear WRITE_ACK (PB7=0)
    bmi WB_WAIT_ACK_CLR
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$FF
    sta PIA_DDRA,y              ; config PA for write (all outputs)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
    pla                         ; byte to write
    sta PIA_PA,y                ; write byte to MCU
    lda PIA_PB,y
    ora #WRITE_REQ
    sta PIA_PB,y                ; assert WRITE_REQ
WB_WAIT_ACK:
    lda PIA_PB,y
    bpl WB_WAIT_ACK             ; wait for WRITE_ACK (PB7=1)
    and #<(~WRITE_REQ)
    sta PIA_PB,y                ; clear WRITE_REQ
    rts

; ==================================================================
; READ_MCU_BYTE -- read one byte from the MCU and return it in A.
; ==================================================================
READ_MCU_BYTE:
    lda PIA_CRA,y
    and #SELECT_DDR
    sta PIA_CRA,y               ; access DDRA
    lda #$00
    sta PIA_DDRA,y              ; config PA for read (all inputs)
    lda PIA_CRA,y
    ora #SELECT_PR
    sta PIA_CRA,y               ; access PA
RB_WAIT_REQ:
    lda PIA_PB,y                ; wait for READ_REQ (PB6=1)
    asl
    bpl RB_WAIT_REQ
    lda PIA_PA,y                ; read the byte from the MCU
    pha                         ; save it
    lda PIA_PB,y
    ora #READ_ACK
    sta PIA_PB,y                ; assert READ_ACK
RB_WAIT_REQ_CLR:
    lda PIA_PB,y                ; wait for READ_REQ clear (PB6=0)
    asl
    bmi RB_WAIT_REQ_CLR
    lda PIA_PB,y
    and #<(~READ_ACK)
    sta PIA_PB,y                ; clear READ_ACK
    pla                         ; return the byte in A
    rts

; ##################################################################
; ## CLOCK WORKER BODIES (merged from thunderclock2.s)            ##
; ##################################################################
; Reconciled to the canonical SAVE_STATE frame: CLK_W_CHAR (output) takes the
; char from A_entry and leaves the frame intact; READ_TIME (read) formats the
; time and FMTFINAL overwrites the frame's X/Y/A slots so RESTORE_STATE returns
; CR + length, exactly like the mouse MC_IN path.

; ============================================================================
; CLK_W_CHAR -- CHARACTER DISPATCH (clock CSW handler)
; ============================================================================
CLK_W_CHAR:                     ; clock CSW (output) handler; leaves the frame intact
    pla                         ; pop the char SAVE_STATE pushed
    and #$7F                    ; strip the high bit
CLK_W_CHAR_SKIP:
; --- READ MODE selectors ---
    cmp #$23                    ; '#' Numeric?
    beq SETRMODE
    cmp #$25                    ; '%' Applesoft AM/PM?
    beq SETRMODE
    cmp #$26                    ; '&' Applesoft 24-hour?
    beq SETRMODE
    cmp #$3C                    ; '<' Integer 24-hour?
    beq SETRMODE
    cmp #$3E                    ; '>' Integer AM/PM?
    beq SETRMODE
; --- WRITE MODE selectors ---
    cmp #$5E                    ; '^' BSR command mode?
    beq SETWMODE
    cmp #$21                    ; '!' set time mode?
    beq SETTIMEMD
    cmp #$2A                    ; '*' BSR duration mode?
    beq SETWMODE
; --- Interrupt rate selectors ---
    ldx #RTC_TP_64HZ
    cmp #$2C                    ; ',' 64 Hz?
    beq SETRATE
    ldx #RTC_TP_256HZ
    cmp #$2E                    ; '.' 256 Hz?
    beq SETRATE
    ldx #RTC_TP_2048HZ
    cmp #$2F                    ; '/' 2048 Hz?
    beq SETRATE
; --- not a mode control character: handle based on the current write mode ---
    ldx MSLOT
    pha                         ; save character across the WMODE read
    lda CLOCK_WMODE,x
    cmp #$21                    ; '!' set time mode?
    beq SETTIMDIG               ; yes -> SETTIMDIG pulls the char back
    pla                         ; balance stack
    
; --- else, any other character ends up here ---

; ... original BSR/X-10 code deleted ...

    lda #$5E                    ; back to BSR command mode
    sta CLOCK_WMODE,x
                                ; but leave MC_MODE alone
    bne FINALIZE                ; always

; --- SETRMODE: store character as format selector ---
SETRMODE:
    sta CLOCK_RMODE,x           ; read mode = '%','&','<','>','#', etc.
SMCOMMON:
    lda #'C'
    sta MC_MODE,x               ; set MC clock mode
                                ; fall thru

; ----------------------------------------------------------------------------
; FINALIZE -- INTERRUPT RE-ENABLE CHECK, then restore state via the SHARED
; RESTORE_STATE in the mouse body.
; ----------------------------------------------------------------------------
FINALIZE:
    ldx MSLOT
    lda #RTC_IRQ_ENABLE
    cmp CLOCK_IRQEN1,x
    bne CLK_FIN_DONE
    cmp CLOCK_IRQEN2,x          ; do both interrupt enable bytes match?
    bne CLK_FIN_DONE
    jsr SLOTY                   ; Y = $n0
    sta RTC_CONTROL,y           ; write RTC_IRQ_ENABLE to control register
CLK_FIN_DONE:
    jmp RESTORE_STATE

; --- SETTIMEMD: enter set-time mode ---
SETTIMEMD:
    lda #RTC_TP_64HZ
    jsr RTC_CMD                 ; set 64 Hz mode (bug?)
    lda #RTC_SHIFT
    jsr RTC_CMD                 ; enter shift mode
    lda #$21                    ; write mode = '!'

; --- SETWMODE: store new write mode ---
SETWMODE:
    sta CLOCK_WMODE,x           ; CLOCK_WMODE = new mode
    bne SMCOMMON

; --- SETRATE: set interrupt rate ---
SETRATE:
    txa
    jsr RTC_CMD
    bne FINALIZE                ; always

; ---- SET-TIME DIGIT HANDLER ----
SETTIMDIG:
    pla
    cmp #$0D                    ; CR?
    beq COMMITTIME
    cmp #$20
    beq FINALIZE                ; ignore spaces
    and #$0F                    ; extract BCD digit
    jsr CLK_SHIFT
    beq LC8F4
    lda #10
LC8F4:
    sta CLOCK_TENS              ; CLOCK_TENS = 0 if data-out was 0, else 10
    clc
    bcc FINALIZE                ; always
COMMITTIME:
    jsr CLK_SHIFT               ; read out 1st nibble: month ones digit
    adc CLOCK_TENS              ; add month tens value
    pha                         ; push hexadecimal month nibble
    lda #$09
    sta CLOCK_LCNT1             ; CLOCK_LCNT1 = 9
LC906:
    jsr CLK_SHIFT               ; read out remaining 9 nibbles
    pha
    dec CLOCK_LCNT1  
    bne LC906
    lda #$0A
    sta CLOCK_LCNT1             ; CLOCK_LCNT1 = 10
LC914:
    pla
    jsr CLK_SHIFT
    dec CLOCK_LCNT1  
    bne LC914
    lda #RTC_TIME_SET
    jsr RTC_CMD                 ; copy shift register data to the time counter
    bne SETWMODE                ; always -> update CLOCK_WMODE

; ============================================================================
; READ_TIME -- READ uPD1990AC AND FORMAT OUTPUT STRING (clock KSW handler)
; ============================================================================
READ_TIME:                      ; clock CSW-read handler; returns the formatted string
    pla                         ; discard the char SAVE_STATE pushed
READ_TIME_SKIP:
    lda #RTC_TIME_READ
    jsr RTC_CMD                 ; copy time counter data to the shift register
    lda #RTC_SHIFT
    jsr RTC_CMD                 ; enter shift mode
    lda #$09
    sta CLOCK_LCNT1             ; CLOCK_LCNT1 = 9
RDNIBBLE:
    jsr CLK_SHIFT
    cmp #$0A                    ; valid BCD?
    bmi LC969
    lda #$00                    ; clamp invalid nibble to 0
LC969:
    pha                         ; push nibble
    dec CLOCK_LCNT1  
    bne RDNIBBLE
    jsr CLK_SHIFT
    cmp #$0D
    bmi LC978
    lda #$00
LC978:
    pha                         ; push month
    lda CLOCK_RMODE,x           ; read mode
    beq FMT_NUMERIC             ; 0 -> Mountain Clock format
    cmp #$23                    ; '#' Numeric?
    bne FMT_DAYNAME             ; no -> day-name format
FMT_NUMERIC:
    ldy #$00                    ; Y = month tens digit (0 for Jan-Sep)
    pla                         ; pop month
    cmp #$0A
    bmi LC98D
    iny                         ; Y=1 for Oct-Dec
    sec
    sbc #$0A
LC98D:
    pha                         ; save month ones
    tya                         ; A = month tens
    ldx #$00                    ; X = text buffer index
    jsr EMIT_DIGIT              ; emit month tens
    pla
    jsr EMIT_DIGIT              ; emit month ones
    ldy MSLOT                   ; Y = $Cn
    lda CLOCK_RMODE,y           ; read mode
    bne FMT_NUM24               ; non-zero -> numeric path
    lda #$AF                    ; '/' | $80
    jsr EMIT_CHAR
    pla                         ; pop day-of-week (not used in Mountain format)
    ldy #$04                    ; 4 pairs: DATE, HR, MIN, SEC
MTNPAIR:
    pla                         ; pop tens nibble
    jsr EMIT_DIGIT
    pla                         ; pop ones nibble
    jsr EMIT_DIGIT
    dey
    beq LC9BA
    lda #$3B                    ; ';' (first one will be patched to space below)
    jsr EMIT_CHAR
    bne MTNPAIR
LC9BA:
    lda #$A0                    ; ' '
    sta $0205                   ; fix buf[5]: "MM/DD;HH..." -> "MM/DD HH..."
LC9BF:
    lda MTN_SUFFIX,y            ; emit ".000"
    beq FMTDONE
    jsr EMIT_CHAR
    iny
    bne LC9BF
FMT_NUM24:
    lda #$00
    pha                         ; leading zero pad
    ldy #$05
NUMPAIR:
    jsr EMIT_COMMA
    pla
    jsr EMIT_DIGIT
    pla
    jsr EMIT_DIGIT
    dey
    bne NUMPAIR
FMTDONE:
    jmp FMTFINAL
FMT_DAYNAME:
    pla                         ; pop month
    tax                         ; X = month
    pla                         ; pop day-of-week
    asl
    asl                         ; A = day-of-week * 4
    tay                         ; Y = day-of-week * 4 (index into DAY_TABLE)
    txa
    asl
    asl                         ; A = month * 4
    pha                         ; save month * 4 (index into MONTH_TABLE)
    ldx MSLOT
    lda CLOCK_RMODE,x           ; A = read mode
    ldx #$A0                    ; default leading char = space | $80
    cmp #$3C                    ; '<' or '>'?
    bcs LC9F8
    ldx #$A2                    ; Applesoft: '"' | $80 as leading char
LC9F8:
    txa
    ldx #$00                    ; reset text buffer index
    jsr EMIT_CHAR
EMITDAY:
    lda DAY_TABLE,y             ; e.g. day-of-week=2: = "TUE "
    iny
    jsr EMIT_CHAR
    cmp #$A0                    ; space (terminator)?
    bne EMITDAY
    pla                         ; pop month * 4
    tay                         ; Y = month * 4 (index into MONTH_TABLE)
EMITMON:
    lda MONTH_TABLE-4,y         ; month is 1 based so index into MONTH_TABLE-4
    iny
    jsr EMIT_CHAR
    cmp #$A0
    bne EMITMON
    pla                         ; date tens
    jsr EMIT_NOZERO
    pla                         ; date ones
    jsr EMIT_DIGIT
    jsr EMIT_SPACE
    ldy #$03                    ; 3 pairs: HR, MIN, SEC
EMITTIME:
    pla                         ; hours tens
    jsr EMIT_NOZERO             ; suppress leading zero on hours
    bne LCA2C                   ; (always non-zero after emit)
EMITLO:
    jsr EMIT_DIGIT              ; emit low nibble of current field
LCA2C:
    pla                         ; hours ones, then minutes ones, seconds ones
    jsr EMIT_DIGIT
    dey
    beq CHKAMPM
    lda #$BA                    ; ':'
    jsr EMIT_CHAR
    pla                         ; minutes tens (second pass), seconds tens (third)
    jmp EMITLO
CHKAMPM:
    ldy MSLOT
    lda CLOCK_RMODE,y           ; read mode
    cmp #$25                    ; '%'?
    beq CONV_12H
    cmp #$3E                    ; '>'?
    bne FMTFINAL                ; 24-hour -> no AM/PM
CONV_12H:
    ldy #$41                    ; Y = 'A' (AM)
    lda $020C                   ; hours tens digit from text buffer
    cmp #$A0                    ; was it suppressed?
    bne LCA55
    lda #$30                    ; treat as '0'
LCA55:
    asl
    asl
    asl
    asl                         ; shift tens into upper nibble
    sta $0220
    lda $020D                   ; hours ones digit
    and #$0F
    ora $0220                   ; combine -> BCD $00-$23
    cmp #$12
    bmi LCA6A
    ldy #$50                    ; Y = 'P' (PM)
LCA6A:
    cmp #$00                    ; midnight?
    bne LCA72
    lda #$12                    ; -> display as 12
    bne LCA7B
LCA72:
    cmp #$13                    ; >= 1 PM?
    bmi LCA8C                   ; 1-12 -> already correct
    sed                         ; BCD mode
    sec
    sbc #$12                    ; subtract 12: 13->1, ..., 23->11
    cld
LCA7B:
    ldx #$0C                    ; re-emit at buffer offset $0C
    pha
    jsr ROR4
    and #$0F
    jsr EMIT_NOZERO
    pla
    and #$0F
    jsr EMIT_DIGIT
LCA8C:
    ldx #$14
    jsr EMIT_SPACE
    tya                         ; A = 'A' or 'P'
    jsr EMIT_CHAR
    lda #$4D                    ; 'M'
    jsr EMIT_CHAR               ; -> " AM" or " PM"
FMTFINAL:
; The format routines have consumed all 10 nibbles, so the canonical SAVE_STATE
; frame is back on top. Append the CR, compute the string length, then overwrite
; the frame's X/Y/A slots in place so RESTORE_STATE returns CR + length to the
; caller (the buffer at $0200 holds the formatted time).
    jsr RETCR                   ; emit CR and overwrite frame A = CR, X = length
    jmp FINALIZE                ; IRQ-enable check, then RESTORE_STATE

; ---- GETLN TEXT BUFFER HELPERS ----
EMIT_NOZERO:                    ; emit digit, space if value == 0
    beq EMIT_SPACE
EMIT_DIGIT:                     ; nibble -> ASCII '0'-'9'
    ora #$30
EMIT_CHAR:                      ; store char with high bit set in $0200,x
    ora #$80
    sta $0200,x
    inx
    rts
EMIT_COMMA:
    lda #$AC
    bne EMIT_CHAR
EMIT_SPACE:
    lda #$A0
    bne EMIT_CHAR

; ---- RTC_CMD -- STROBE COMMAND INTO uPD1990AC ----
RTC_CMD:
    sta RTC_CONTROL,y           ; write command w/o strobe
    ora #RTC_STROBE
    sta RTC_CONTROL,y           ; raise strobe
    jsr STBDLY                  ; delay
    eor #RTC_STROBE             ; clear strobe bit
    sta RTC_CONTROL,y           ; drop strobe
STBDLY:
    jsr STBDL1
STBDL1:
    pha
    pha
    pla
    pla
    rts

; ---- CLK_SHIFT -- clock one nibble in/out of the uPD1990AC shift register ----
CLK_SHIFT:
    pha                         ; save data-in
    lda #4
    sta CLOCK_LCNT2             ; 4 bits
    lda #0
    sta CLOCK_DOUT              ; CLOCK_DOUT = 0
SHLOOP:
    lda RTC_CONTROL,y           ; get DATA OUT bit in bit 7
    asl                         ; DATA OUT bit -> carry
    ror CLOCK_DOUT              ; rotate into CLOCK_DOUT
    pla
    pha                         ; get & resave data-in
    and #1                      ; bit 0 only
    sta RTC_CONTROL,y           ; write one bit of data to DATA IN
    ora #RTC_CLK
    sta RTC_CONTROL,y           ; raise CLK: clock the shift register
    eor #RTC_CLK
    sta RTC_CONTROL,y           ; lower CLK
    pla
    ror                         ; shift data-in for next bit
    pha
    dec CLOCK_LCNT2             ; done 4 bits?
    bne SHLOOP
    pla                         ; adjust stack
    lda CLOCK_DOUT  
    clc
ROR4:
    ror
    ror
    ror
    ror
    rts

; ---- DAY_TABLE / MONTH_TABLE / MTN_SUFFIX ----
DAY_TABLE:
    .byte "SUN ","MON ","TUE ","WED ","THU ","FRI ","SAT ","ERR "
MONTH_TABLE:
    .byte "JAN ","FEB ","MAR ","APR ","MAY ","JUN "
    .byte "JUL ","AUG ","SEP ","OCT ","NOV ","DEC "
MTN_SUFFIX:
    .byte $AE,$B0,$B0,$B0       ; ".000"
    .byte $00                   ; null terminator

; ============================================================================
; PATCH_P8_YT -- ProDOS clock-driver year-table patch.
; ============================================================================
PATCH_P8_YT:
    tsx
    lda $BF07                   ; lo byte of driver address
    clc
    adc #14                     ; lo byte of return addr = base + 14
    tay                         ; save lo result; carry still valid for hi byte
    lda $BF08                   ; hi byte of driver address
    adc #0                      ; propagate carry from lo addition
    cmp $0108,x                 ; matches actual hi byte on stack?
    bne SKIP                    ; no -> skip update
    tya                         ; restore lo result
    cmp $0107,x                 ; matches actual lo byte on stack?
    bne SKIP                    ; no -> skip update
    lda $BF07                   ; lo byte of driver address
    clc
    adc #$76                    ; + offset to YEAR_TABLE within driver
    sta $3A                     ; lo byte of YEAR_TABLE pointer
    lda $BF08                   ; hi byte of driver address
    adc #0                      ; propagate carry
    sta $3B                     ; hi byte of YEAR_TABLE pointer
    ldy #6                      ; index 6 down to 0
LOOP:
    lda LATEST_YEAR_TABLE,y
    sta ($3A),y                 ; -> driver's YEAR_TABLE[Y]
    dey
    bpl LOOP
SKIP:
    jsr SLOTXY                  ; restore X = $Cn, Y = $n0
    jmp READ_TIME               ; -> read clock, format output string

LATEST_YEAR_TABLE:
    .byte $1D                   ; Jan 1 = Monday    -> 2029
    .byte $1C                   ; Jan 1 = Sunday    -> 2028 (Feb 29 - Dec 31)
    .byte $1C                   ; Jan 1 = Saturday  -> 2028 (Jan 1 - Feb 28)
    .byte $1B                   ; Jan 1 = Friday    -> 2027
    .byte $1A                   ; Jan 1 = Thursday  -> 2026
    .byte $1F                   ; Jan 1 = Wednesday -> 2031
    .byte $1E                   ; Jan 1 = Tuesday   -> 2030

Credits:
    .byte $CD,$EF,$F5,$F3,$E5,$C3,$EC,$EF,$E3,$EB,$8D               ; "MouseClock",CR
    .byte $B2,$B0,$B2,$B6,$AD,$B0,$B6,$AD,$B2,$B2,$8D               ; "2026-06-22",CR
CreditsEnd:
CRED_LEN = CreditsEnd - Credits
    .res  $CFFF - *, $FF
    .byte $FF                   ; last byte not usable, accessing $CFFF disables expansion ROMs
