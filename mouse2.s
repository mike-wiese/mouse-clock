; ============================================================
; Apple II Mouse Interface Card ROM  --  non-banked variant
; Mike Wiese
; 2026-07-10
; ============================================================
;
; This is a de-banked re-implementation of the AppleMouse II firmware.
; It assumes a Thunderclock-style ROM mapping instead of the original
; card's PIA-driven bank switching:
;
;   The physical 2KB ROM is mapped in two ways simultaneously:
;     $Cn00-$CnFF  256-byte "slot ROM" for slot n (first $100 bytes of ROM)
;     $C800-$CFFF  2KB "expansion ROM" (the full image, including the
;                  first $100 bytes mirrored at $C800)
;
; Every entry point (MAIN, ServeMouse, the API stubs) funnels through the
; shared COMMON routine, which derives our slot and claims the expansion
; ROM (per the IIe Technical Reference): it references $CFFF to disable all
; $C800 ROMs, then a JSR whose opcode fetch lands in our expansion ROM
; re-enables it; the JSR's return address (still a $Cnxx slot address)
; yields the slot number, which is stored in $07F8. This must run from the
; slot-ROM window ($Cn00-$CnFF, always mapped) -- once $CFFF disables the
; expansion ROM, code running there would vanish -- so entry points reach
; COMMON only by PC-relative branches, then COMMON RTSes into a fixed
; trampoline in the expansion ROM. Because the code now
; lives at fixed addresses, control is threaded with ordinary JMP/JSR/RTS
; instead of the original "select a bank, dispatch on a function code"
; plumbing. The PIA Port B bits 1-3 (which selected the ROM bank on the
; original card) are no longer used for banking.
;
; Differences from the original (besides layout):
;   - No ROM_BANK screen hole, no per-bank BANK_SWITCH blocks, no
;     function-code dispatch, no MOUSE_MODE hi-nibble bank tagging.
;   - Cross-routine control transfers are direct JSPs and JMPs.
;   - The Apple II / II+ VBL-sync path in InitMouse reads $CFFF, which on a
;     $C800-mapped card is the "disable expansion ROM" strobe. To keep it
;     working, the timing loop itself (SYNC_LOOP) lives in the slot-ROM page
;     and runs in the always-mapped $Cn00 window, where reading $CFFF cannot
;     deselect it. IIe and later still sync via RDVBLBAR.
;
; See mouse.s for the full hardware description (PIA, MCU handshake, etc.).

; ============================================================
; Screen hole usage
; ============================================================
; Scratch area
CLAMP_MIN_LO    = $0478         ; lo byte of clamping minimum
CLAMP_MAX_LO    = $04F8         ; lo byte of clamping maximum
CLAMP_MIN_HI    = $0578         ; hi byte of clamping minimum
CLAMP_MAX_HI    = $05F8         ; hi byte of clamping maximum

; Slot #n screen holes at address,X where X = slot $Cn
MOUSE_X_LO      = $0478-$C0     ; + $Cn   X coord lo
MOUSE_Y_LO      = $04F8-$C0     ; + $Cn   Y coord lo
MOUSE_X_HI      = $0578-$C0     ; + $Cn   X coord hi
MOUSE_Y_HI      = $05F8-$C0     ; + $Cn   Y coord hi
; ($0678 + $Cn was ROM_BANK on the banked card -- now unused/free)
MOUSE_CMD       = $06F8-$C0     ; + $Cn   command/temp byte
MOUSE_STATUS    = $0778-$C0     ; + $Cn   status byte
MOUSE_MODE      = $07F8-$C0     ; + $Cn   mode byte

MOUSE_ON        = %00000001     ; mouse mode bit 0 mask: mouse is on, aka active

; ============================================================
; 6821 PIA registers (at $C08x,Y where Y = slot * $10)
; ============================================================
PIA_DDRA        = $C080
PIA_PA          = $C080
PIA_CRA         = $C081
PIA_DDRB        = $C082
PIA_PB          = $C082
PIA_CRB         = $C083

; ---- PIA Control Register bit 2 manipulation ---------------
SELECT_DDR      = %11111011     ; AND to clear bit 2 -> access DDR
SELECT_PR       = %00000100     ; OR  to set   bit 2 -> access Peripheral Register

; ---- PIA Port B MCU handshake bits -------------------------
READ_ACK        = %00010000     ; PB4  Apple II -> MCU  ack data read from MCU
WRITE_REQ       = %00100000     ; PB5  Apple II -> MCU  data ready to send to MCU
READ_REQ        = %01000000     ; PB6  MCU -> Apple II  data ready to send to Apple II
WRITE_ACK       = %10000000     ; PB7  MCU -> Apple II  ack data written by Apple II

; ---- MCU command byte values -------------------------------
CMD_SETMOUSE    = $00           ; SetMouse
CMD_READMOUSE   = $10           ; ReadMouse
CMD_SERVEMOUSE  = $20           ; ServeMouse
CMD_CLEARMOUSE  = $30           ; ClearMouse
CMD_POSMOUSE    = $40           ; PosMouse
CMD_INITMOUSE   = $50           ; InitMouse
CMD_CLAMPMOUSE  = $60           ; ClampMouse
CMD_HOMEMOUSE   = $70           ; HomeMouse
CMD_TRANSPARENT = $80           ; set transparent mode, see IIc Tech Ref *
CMD_TIMEDATA    = $90           ; TimeData
CMD_SETVBLCNTS  = $A0           ; SetVBLCnts
CMD_OPTMOUSE    = $B0           ; OptMouse
CMD_STARTTIMER  = $C0           ; StartTimer
CMD_DIAGMOUSE   = $F0           ; DiagMouse

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
LINE191         = $3FD0         ; HIRES page 1, line 191

; ---- Other RAM/screen addresses ----------------------------
ZP_TEMP1        = $06
ZP_TEMP2        = $07
ZP_TEMP3        = $08
CSWL            = $36
CSWH            = $37
KSWL            = $38
KSWH            = $39
INBUF           = $0200         ; GETLN input buffer
BCD_HI          = $0220         ; BCD conversion: hi byte
BCD_LO          = $0221         ; BCD conversion: lo byte
MSLOT           = $07F8         ; slot $Cn

        .setcpu "6502"

; ==================================================================
; Page 0 ($C800-$C8FF, also mapped at $Cn00):
;   slot-ROM entry points, ID/dispatch bytes, MAIN, the API entry
;   stubs, and the common exit handlers.
; ==================================================================
        .org $C800

; mouse id bytes (Mouse Technical Note #5)
;   $Cn05 = $38  Pascal ID byte
;   $Cn07 = $18  Pascal ID byte
;   $Cn0B = $01  Pascal ID byte
;   $Cn0C = $20  X-Y pointing device, type zero
;   $CnFB = $D6  AppleMouse II card id byte

ENTRY:                          ; PR#n and IN#n entry point        ($Cn00)
        bit IORTS               ; known RTS, will set V
        bvs MAIN                ; always

MOUSE_IN:                       ; our KSW entry point              ($Cn05)
        sec                     ; $38 mouse id byte
        .byte $90               ; BCC: C=1 not taken, skips the CLC, lands on CLV

MOUSE_OUT:                      ; our CSW entry point              ($Cn07)
        clc                     ; $18 mouse id byte
        clv
        bvc MAIN                ; always

        .byte $01               ; $01 mouse id byte                ($Cn0B)
        .byte $20               ; $20 mouse id byte                ($Cn0C)

        .byte <ERR_STUB         ; Pascal init   (not implemented)
        .byte <ERR_STUB         ; Pascal read   (not implemented)
        .byte <ERR_STUB         ; Pascal write  (not implemented)
        .byte <ERR_STUB         ; Pascal status (not implemented)
        .byte $00               ; $00 = more routines follow
        .byte <SetMouse
        .byte <ServeMouse
        .byte <ReadMouse
        .byte <ClearMouse
        .byte <PosMouse
        .byte <ClampMouse
        .byte <HomeMouse
        .byte <InitMouse
        .byte <DiagMouse
        .byte <Copyright
        .byte <TimeData
        .byte <SetVBLCnts
        .byte <OptMouse
        .byte <StartTimer

MAIN:
; Save processor state (restored by RESTORE_STATE), choose the B4 hook handler
; from the entry V/C flags, then hand off to COMMON -- which derives the
; slot and claims the expansion ROM for us, just as it does for the API
; stubs. V and C survive the saves below (none of them touch V/C).
        php                     ; save entry flags
        sei                     ; disable interrupts
        sta MSLOT               ; stash A (= entry character) briefly
        pha                     ; save A
        tya
        pha                     ; save Y
        txa
        pha                     ; save X
        lda MSLOT               ; A = entry character
        pha                     ; save character
        bvs MAIN_PR             ; V=1: PR#n / IN#n            -> B4_FN0
        bcc MAIN_OUT            ; V=0,C=0: MOUSE_OUT, CSW out -> B4_FN1
        ldx #<(T_B4F2-1)        ; V=0,C=1: MOUSE_IN, KSW in   -> B4_FN2
        bne COMMON              ; always
MAIN_OUT:
        ldx #<(T_B4F1-1)
        bne COMMON              ; always
MAIN_PR:
        ldx #<(T_B4F0-1)
        bne COMMON              ; always

; ==================================================================
; API entry stubs. Each sets up its MCU command / parameters, loads the
; lo byte of its worker trampoline into X, then BRANCHES to COMMON. The
; branch is essential: we run from the slot-ROM window at $Cn (n unknown),
; and only a PC-relative branch keeps us there -- a JMP/JSR to an absolute
; $C8xx address would run COMMON's $CFFF reference from the expansion-ROM
; window, disabling the very ROM it is running from.
;
; The API stubs are entered with X = $Cn (the standard mouse calling
; convention), so they index their command screen-hole directly before
; overwriting X with the trampoline selector. COMMON re-derives the slot.
; The B3 (single command) and B7 (multi-byte write) routines share the
; SEND_B3 / SEND_B7 tails: enter with the MCU command in A, X = $Cn.
; ==================================================================

; ---- SetMouse: A = mode ($00-$0F); C=1 on illegal mode -----------
SetMouse:
        cmp #$10                ; mode must be $00-$0F
        bcs SetMouseBad         ; invalid: return C=1 (error)
        sta MOUSE_MODE,x        ; save valid mode (X = $Cn)
                                ; A = mode = MCU SetMouse command; fall into SEND_B3
SEND_B3:                        ; enter with A = MCU command, X = $Cn -> B3
        sta MOUSE_CMD,x
        ldx #<(T_B3-1)          ; trampoline selector (overwrites $Cn)
        bne COMMON              ; always
SetMouseBad:
        rts                     ; C=1 (error), set by the cmp above

; ---- ClearMouse / HomeMouse / StartTimer / OptMouse --------------
ClearMouse:
        lda #CMD_CLEARMOUSE
        bne SEND_B3             ; always
HomeMouse:
        lda #CMD_HOMEMOUSE
        bne SEND_B3             ; always
StartTimer:
        lda #CMD_STARTTIMER
        bne SEND_B3             ; always
OptMouse:
        and #$0F
        ora #CMD_OPTMOUSE
        bne SEND_B3             ; always ($Bx != 0)

; ---- ServeMouse: slot derived by COMMON; T_SERVE sends CMD_SERVEMOUSE -
; (No X = $Cn on entry, so the command is set in the T_SERVE trampoline
;  after COMMON has recovered the slot.)  ServeMouse is called during an
; interrupt and -- unlike the original firmware -- COMMON would overwrite
; $07F8 (MSLOT); save it here and restore it at the exit (see B3).
ServeMouse:
        lda MSLOT
        pha                     ; preserve the caller's MSLOT across the call
        ldx #<(T_SERVE-1)
        bne COMMON              ; always

; ---- ReadMouse / InitMouse / Copyright / DiagMouse ---------
ReadMouse:
        ldx #<(T_B6-1)
        bne COMMON              ; always
InitMouse:
        ldx #<(T_B2-1)
        bne COMMON              ; always
Copyright:
        ldx #<(T_B1F0-1)
        bne COMMON              ; always
DiagMouse:                      ; A=0 read, A=1 write
        and #$01
        ora #CMD_DIAGMOUSE
        sta MOUSE_CMD,x         ; X = $Cn
        ldx #<(T_B1F1-1)
        bne COMMON              ; always

; ==================================================================
; COMMON -- unified entry epilogue for MAIN, ServeMouse, and every API
; stub. Reached only by relative branches, so it runs in the slot-ROM
; window ($Cn00-$CnFF, which is always mapped). On entry X holds the
; routine's trampoline selector = <(trampoline-1); any stack argument was
; pushed below.
;
;   PHP/SEI/TAY   save flags; disable IRQs for the GETSLOT stack walk;
;                 stash entry A in Y so it survives to the worker
;   LDA $CFFF     disable all $C800 expansion ROMs (we are in slot ROM,
;                 which stays mapped, so execution continues)
;   JSR GETSLOT   the opcode fetch at GETSLOT ($C8xx, since we .org'd to
;                 $C800) transfers into and re-enables OUR expansion ROM;
;                 the return address it pushes is still a $Cnxx address,
;                 so its high byte is our slot number $Cn
; GETSLOT pops that return address (recovering $Cn -> MSLOT), restores the
; saved flags, and falls through. Build the trampoline RTS target (fixed
; page, lo byte from X), restore entry A from Y, set X=$Cn / Y=$n0 via
; SLOTXY (which preserves A), and RTS into the trampoline -- so the worker
; sees A/flags as on entry, with X=$Cn and Y=$n0.
; ==================================================================
COMMON: php                     ; save entry flags
        sei                     ; disable interrupts for the stack walk
        tay                     ; stash entry A in Y (preserved to the worker)
        lda $CFFF               ; disable $C800 expansion ROMs
        jsr GETSLOT             ; opcode fetch from $Cnxx re-enables OUR $C800 ROM
GETSLOT:
        pla                     ; discard return-address low byte
        pla                     ; A = return-address high byte = $Cn
        sta MSLOT               ; MSLOT = $Cn
        plp                     ; restore entry flags (and interrupt state)
        lda #>(T_B3)            ; high byte of the trampoline page ($C9)
        pha
        txa                     ; X = <(trampoline-1) selector
        pha                     ; RTS target now on the stack
        tya                     ; restore entry A (SLOTXY preserves it)
        jsr SLOTXY              ; X = $Cn, Y = $n0
        rts                     ; jump into the expansion-ROM trampoline

; ---- PosMouse / ClampMouse / TimeData / SetVBLCnts -------------
SEND_B7:                        ; enter with A = MCU command, X = $Cn -> B7
        sta MOUSE_CMD,x
        ldx #<(T_B7-1)
        bne COMMON              ; always
PosMouse:
        lda #CMD_POSMOUSE
        bne SEND_B7             ; always
ClampMouse:                     ; A=0 X-bounds, A=1 Y-bounds
        and #$01
        ora #CMD_CLAMPMOUSE
        bne SEND_B7             ; always
TimeData:
        and #$0F
        ora #CMD_TIMEDATA
        bne SEND_B7             ; always ($9x != 0)
SetVBLCnts:                     ; A = VBLs per IRQ
        pha                     ; push N (rate) -- left on the stack for B7
        lda #CMD_SETVBLCNTS
        bne SEND_B7             ; always

; ==================================================================
; ERR_STUB -- Pascal "illegal I/O request" stub. Must stay in the
; slot-ROM page: Pascal calls it via $Cn,offset. (Success is returned
; inline with CLC/RTS at each worker; RESTORE_STATE lives with B5.)
; ==================================================================
ERR_STUB:
        ldx #$03                ; Pascal Illegal I/O request
EXIT_ERR:
        sec
        rts

; ==================================================================
; SLOTXY / SLOTY -- recover the slot registers from MSLOT.
;   SLOTXY: exit X = $Cn, Y = $n0.
;   SLOTY : entry X = $Cn; exit X = $Cn, Y = $n0.
; Preserves A; clobbers flags. Placed in the slot-ROM page, in the space
; before the trampolines.
; ==================================================================
SLOTXY: ldx MSLOT               ; X = $Cn
SLOTY:  pha                     ; preserve A
        txa
        asl
        asl
        asl
        asl
        tay                     ; Y = $n0
        pla
        rts

; ==================================================================
; SYNC_LOOP -- Apple II / II+ VBL sync polling loop (44-cycle period).
; Lives in the slot-ROM page and is entered via RTS to $Cn:SYNC_LOOP from
; B2_HIRES_SYNC, so it runs in the always-mapped $Cn00 window: its $CFFF
; reads latch the PAL sync bit (and disables the $C800 expansion ROM)
; without deselecting the code executing here. Each pass samples PIA PB0
; at the two sentinel pixels; exits (synced, or 24-bit counter timeout) by
; jumping back to B2_D7 in the expansion ROM (that fetch re-enables it).
; ==================================================================
SYNC_LOOP:
        inc ZP_TEMP1            ; [5] increment 24-bit timeout counter
        bne SL_B8               ; [2/3]
        inc ZP_TEMP2            ; [5]
        bne SL_BA               ; [2/3]
        inc ZP_TEMP3            ; [5]
        lda ZP_TEMP3            ; [3]
        cmp #$01                ; [2]
        bcc SL_C0               ; [2/3]
        bcs SYNC_EXIT           ; [2/3] timeout: give up
SL_B8:  php                     ; [3] match the mid-byte increment path's cycles
        plp                     ; [4]
SL_BA:  php                     ; [3] match the hi-byte increment path's cycles
        plp                     ; [4]
        lda #$00                ; [2]
        lda $00                 ; [3]
SL_C0:  lda $CFFF               ; [4] trigger PAL latch (also disables C800 ROM)
        lda PIA_PB,y            ; [4] read the sync latch at PB0
        lsr                     ; [2] sync bit -> carry
        nop                     ; [2] pad to the 16-cycle sentinel spacing
        nop                     ; [2]
        bcs SYNC_LOOP           ; [2/3] missed the first sentinel: keep polling
        lda $CFFF               ; [4] second trigger, 16 cycles after the first
        lda PIA_PB,y            ; [4] read the sync latch again
        lsr                     ; [2]
        lda $00                 ; [3] timing filler
        nop                     ; [2]
        bcs SYNC_LOOP           ; [2/3] missed the second sentinel: keep polling
SYNC_EXIT:                      ; matched both sentinels -> VBL is imminent
        jmp B2_D7               ; back into the expansion ROM

        .res  $C8FB - *, $FF    ; pad to the card id byte
MOUSE_ID:
        .byte $D6               ; $D6 mouse id byte                ($CnFB)
        .res  $C900 - *, $FF    ; pad out the slot-ROM page

; ==================================================================
; Worker trampolines (expansion ROM, page $C9). COMMON's RTS lands here
; with X = $Cn and Y = $n0 already set by SLOTXY, so each entry is just a
; jump to its worker. The 3-byte filler keeps the first entry off $C900,
; so (entry-1) stays in page $C9 (COMMON pushes a fixed high byte for all
; of them).
; ==================================================================
        .res  3, $FF
T_B3:   jmp B3_FN0
T_B7:   jmp B7_FN1
T_B6:   jmp B6_FN2
T_B1F1: jmp B1_FN1
T_B1F0: jmp B1_FN0
T_B2:   jmp B2_FN0
T_B4F0: jmp B4_FN0
T_B4F1: jmp B4_FN1
T_B4F2: jmp B4_FN2
T_SERVE:                        ; ServeMouse: set the command now X = $Cn is valid
        lda #CMD_SERVEMOUSE
        sta MOUSE_CMD,x
        jmp B3_FN0

; ==================================================================
; B1: Copyright (B1_FN0) and DiagMouse (B1_FN1)
; ==================================================================
B1_FN0:                         ; print the credits
        tya                     ; save Y
        pha
        jsr HOME                ; clear screen
        ldy #$00
B1_13:  lda Credits,y           ; read character from string
        beq B1_1D               ; NUL: done
        jsr COUT                ; print character
        iny
        bne B1_13               ; loop
B1_1D:  pla
        tay                     ; Y = $n0
        clc                     ; EXIT_OK
        rts
Credits:
; "AppleMouse", $8D
; "Copyright 1983 by Apple Computer, Inc.", $8D, $8D
; "Bachman/Marks/MacKay", $8D, $00
        .byte $C1,$F0,$F0,$EC,$E5,$CD,$EF,$F5,$F3,$E5,$8D,$C3,$EF,$F0,$F9,$F2
        .byte $E9,$E7,$E8,$F4,$A0,$B1,$B9,$B8,$B3,$A0,$E2,$F9,$A0,$C1,$F0,$F0
        .byte $EC,$E5,$A0,$C3,$EF,$ED,$F0,$F5,$F4,$E5,$F2,$AC,$A0,$C9,$EE,$E3
        .byte $AE,$8D,$8D,$C2,$E1,$E3,$E8,$ED,$E1,$EE,$AF,$CD,$E1,$F2,$EB,$F3
        .byte $AF,$CD,$E1,$E3,$CB,$E1,$F9,$8D,$00

; ---- DiagMouse: read/write one byte of MCU memory ----------------
;   CLAMP_MIN_LO -> MCU address low byte
;   CLAMP_MAX_LO -> MCU address high byte
;   CLAMP_MIN_HI -> write: byte to store;  read: byte returned
B1_FN1: lda MOUSE_CMD,x         ; send the command byte
        jsr WRITE_FIRST_BYTE    ; first byte: configure Port B + write
        lda CLAMP_MIN_LO        ; send the address low byte
        jsr WRITE_MCU_BYTE
        lda CLAMP_MAX_LO        ; send the address high byte
        jsr WRITE_MCU_BYTE
        ror MOUSE_CMD,x         ; C = command bit 0: 0=read, 1=write
        bcc B1_READ
        lda CLAMP_MIN_HI        ; write: send the data byte
        jsr WRITE_MCU_BYTE
        clc                     ; EXIT_OK
        rts
B1_READ:
        jsr B6_FN1              ; read: fetch one byte back (into MOUSE_CMD)
        lda MOUSE_CMD,x
        sta CLAMP_MIN_HI
        clc                     ; EXIT_OK
        rts

; ==================================================================
; B2: InitMouse
; Reset the MCU and phase-lock its VBL timer to video. IIe and later sync
; via RDVBLBAR; Apple II / II+ sync with the mouse-card PAL sync latch.
; ==================================================================
B2_FN0: lda #CMD_INITMOUSE      ; call #1: CMD_INITMOUSE resets the MCU
        jsr WRITE_FIRST_BYTE
        jsr B6_FN1              ; call #2: read a byte back (version?)
        lda F8VERSION
        cmp #$06                ; IIe or later ($FBB3 = 6)?
        bne B2_HIRES_SYNC       ; no (II / II+): use the HIRES/PAL sync method
B2_26:  lda RDVBLBAR
        bmi B2_26               ; wait for VBL low (blanking)
B2_2B:  lda RDVBLBAR
        bpl B2_2B               ; wait for VBL high (end of blanking)
B2_30:  lda RDVBLBAR
        bmi B2_30               ; wait for VBL low again (start of blanking)
        lda #CMD_INITMOUSE      ; call #3: restart the (now phase-locked) timer
        jsr WRITE_FIRST_BYTE
        clc                     ; EXIT_OK
        rts

; ------------------------------------------------------------------
; Apple II / II+ VBL sync (no RDVBLBAR). The PAL latches D0 of the video
; floating bus when the 6502 reads $CFFF; the firmware reads it back at PIA
; Port B bit 0. Two $01 sentinel bytes on the last video line, 16 bytes
; apart, are the only pixels with D0=1 on an otherwise cleared HIRES page.
; This setup does not touch $CFFF, so it runs here in the expansion ROM;
; the actual polling loop (which reads $CFFF, and so would disable this
; $C800 ROM) runs from the slot-ROM page -- see SYNC_LOOP in page 0.
; ------------------------------------------------------------------
B2_HIRES_SYNC:
        lda ZP_TEMP1            ; save zp temps + Y on the stack
        pha
        lda ZP_TEMP2
        pha
        tya
        pha
        lda #$20                ; ZP_TEMP1/2 -> HIRES page 1 ($2000)
        sta ZP_TEMP2
        ldy #$00
        sty ZP_TEMP1
B2_57:  lda #$00                ; clear HIRES page 1: only the sentinels keep D0=1
B2_59:  sta (ZP_TEMP1),y
        iny
        bne B2_59
        inc ZP_TEMP2
        lda ZP_TEMP2
        cmp #$40
        bne B2_57
        pla
        tay                     ; restore Y = $n0
        lda ZP_TEMP3
        pha                     ; save ZP_TEMP3
        lda #$01                ; two sentinels on the last video line, 16 bytes apart
        sta LINE191
        sta LINE191+16
        lda HIRES               ; switch to HIRES graphics, page 1, full screen
        lda PAGE1
        lda NOMIX
        lda GRAPHICS            ; A = floating bus (~0) just after the video read
        nop
        sta ZP_TEMP1            ; zero the 24-bit timeout counter
        sta ZP_TEMP2
        sta ZP_TEMP3
        lda MSLOT               ; enter the slot-ROM mirror of SYNC_LOOP (RTS to
        pha                     ; $Cn:SYNC_LOOP) so the loop's $CFFF reads cannot
        lda #<(SYNC_LOOP-1)     ; pull our $C800 ROM out from under it
        pha
        rts
; SYNC_EXIT (page 0) jumps back here once synced or timed out:
B2_D7:  pla                     ; restore zp temps
        sta ZP_TEMP3
        pla
        sta ZP_TEMP2
        pla
        sta ZP_TEMP1
        lda #CMD_INITMOUSE      ; call #3: restart the (now phase-locked) timer
        jsr WRITE_FIRST_BYTE
        lda TEXT                ; restore the text + lo-res display
        lda LORES
        clc                     ; EXIT_OK
        rts

; ==================================================================
; B3: SetMouse, ServeMouse, ClearMouse, HomeMouse, OptMouse, StartTimer
; Send MOUSE_CMD to the MCU; ServeMouse also reads a status byte back.
; ==================================================================
B3_FN0: lda MOUSE_CMD,x         ; ServeMouse needs a response read after the write
        cmp #CMD_SERVEMOUSE
        bne B3_0D
        lda #$7F
        adc #$01                ; V=1 ($7F+1 overflows): response read needed
        bvs B3_SEND             ; always
B3_0D:  clv                     ; V=0: no response read needed
B3_SEND:
        lda MOUSE_CMD,x
        jsr WRITE_FIRST_BYTE    ; configure Port B + send the command (V preserved)
        bvs READ_MCU_RESPONSE   ; ServeMouse: read the interrupt-status byte
        lda MOUSE_CMD,x
        cmp #CMD_CLEARMOUSE     ; ClearMouse: also zero the position screen holes
        bne B3_SUCCESS
        lda #$00
        sta MOUSE_X_HI,x
        sta MOUSE_X_LO,x
        sta MOUSE_Y_HI,x
        sta MOUSE_Y_LO,x
B3_SUCCESS:
        clc                     ; EXIT_OK
        rts
READ_MCU_RESPONSE:
        jsr READ_MCU_BYTE       ; read the interrupt-status byte
        sta MOUSE_CMD,x
        lda MOUSE_STATUS,x
        and #$F1                ; clear old interrupt bits
        ora MOUSE_CMD,x         ; merge in interrupt bits from MCU
        sta MOUSE_STATUS,x
        and #$0E                ; any interrupt source bits set?
        tax                     ; keep the result across the MSLOT restore (X is free)
        pla                     ; restore the caller's MSLOT (saved in ServeMouse so
        sta MSLOT               ; the interrupt-time call leaves $07F8 untouched)
        txa                     ; Z = 0 if any interrupt bits were set
        bne B3_SUCCESS          ; yes -> C=0 (mouse interrupt)
        sec                     ; no  -> C=1 (not a mouse interrupt)
        rts

; ==================================================================
; B4: I/O hooks
;   B4_FN0: PR#n / IN#n -- install CSW / KSW hook then run hook code
;   B4_FN1: MOUSE_OUT   -- handle one output character
;   B4_FN2: MOUSE_IN    -- format mouse X-Y position + status into INBUF
; ==================================================================
B4_FN0: cpx CSWH                ; is CSWH pointing to our slot?
        bne B4_31
        lda #<MOUSE_OUT
        cmp CSWL                ; CSWL already MOUSE_OUT?
        beq B4_31               ; yes: assume IN#n, check KSW
        sta CSWL                ; install MOUSE_OUT hook, fall thru
B4_FN1: pla                     ; pop character
        cmp #$8D                ; CR ?
        beq B4_85               ; yes -> exit
        and #MOUSE_ON           ; only keep "mouse is on" bit
        sta MOUSE_MODE,x
        lsr                     ; bit 0 (mouse is on) -> carry
        lda #CMD_TRANSPARENT    ; A = $80
        bcs B4_26               ; mouse on = 1 -> keep CMD_TRANSPARENT ($80)
        asl                     ; mouse on = 0 -> A = CMD_SETMOUSE mouse off ($00)
B4_26:  jsr WRITE_FIRST_BYTE        ; A = command byte: send it to the MCU
B4_85:  jmp RESTORE_STATE
B4_31:  cpx KSWH                ; is KSWH pointing to our slot?
        bne B4_FN1              ; no: (should not happen) handle output char
        lda #<MOUSE_IN
        sta KSWL                ; install MOUSE_IN hook, fall thru
B4_FN2: lda MOUSE_MODE,x
        and #MOUSE_ON           ; is mouse on (mode bit 0)?
        bne B4_54
        pla                     ; off: discard 4 saved regs, leave flags
        pla
        pla
        pla
        lda #$00                ; zero the position screen holes
        sta MOUSE_X_LO,x
        sta MOUSE_X_HI,x
        sta MOUSE_Y_LO,x
        sta MOUSE_Y_HI,x
        lda #$C0                ; button down / was down (mouse off case)
        sta MOUSE_STATUS,x
        bne B5_FN0              ; always
B4_54:                          ; entered from B4_FN2 with A = MOUSE_MODE & $01
;   sta MOUSE_MODE,x            ; unneeded: MOUSE_MODE is always read masked (AND #$01),
                                ;   so its upper bits never matter
        lda #CMD_READMOUSE      ; send CMD_READMOUSE to the MCU
        jsr WRITE_FIRST_BYTE
        pla                     ; discard 4 saved regs, leave flags
        pla
        pla
        pla
        jsr READ_MCU_BYTE       ; read the 5-byte response into the screen holes
        sta MOUSE_X_LO,x
        jsr READ_MCU_BYTE
        sta MOUSE_X_HI,x
        jsr READ_MCU_BYTE
        sta MOUSE_Y_LO,x
        jsr READ_MCU_BYTE
        sta MOUSE_Y_HI,x
        jsr READ_MCU_BYTE
        sta MOUSE_STATUS,x

; ==================================================================
; B5: MOUSE_IN -- format "+xxxxx,+yyyyy,+st" into INBUF
; B5_FN1 / B5_91 take their arguments in registers and RTS, so they are
; called with ordinary JSRs here.
; ==================================================================
B5_FN0: ldy MOUSE_X_LO,x        ; format X coordinate
        lda MOUSE_X_HI,x
        tax
        tya
        ldy #$05                ; digit position in INBUF for X
        jsr B5_FN1
        ldx MSLOT               ; X = $Cn
        ldy MOUSE_Y_LO,x        ; format Y coordinate
        lda MOUSE_Y_HI,x
        tax
        tya
        ldy #$0C                ; digit position for Y
        jsr B5_FN1
        ldx MSLOT               ; X = $Cn
        lda KBD                 ; encode the status field
        asl                     ; key-down flag -> carry
        php                     ; save carry
        lda MOUSE_STATUS,x
        rol A
        rol A
        rol A                   ; move + button flags into A[1:0]
        and #$03
        eor #$03                ; invert
        sec
        adc #$00                ; range 1-4
        plp                     ; restore key-down flag (C=1 formats with '-')
        ldx #$00                ; hi byte for status = 0
        ldy #$10                ; digit position for status
        jsr B5_91
        lda #$8D                ; CR terminator just past the status field
        sta INBUF+$11
        pha                     ; RESTORE_STATE pops this as A (char returned to KEYIN)
        lda #$11                ; output cursor position / length
        pha                     ; RESTORE_STATE pops as Y
        pha                     ; RESTORE_STATE pops as X
; ==================================================================
; RESTORE_STATE -- restore the registers saved by MAIN and return to the I/O
; hook caller. B5_FN0 falls through into it; B4 (B4_85) jumps here.
; ==================================================================
RESTORE_STATE:
        pla
        tax                     ; restore X
        pla
        tay                     ; restore Y
        pla
        plp                     ; restore A then flags
        rts
B5_FN1:                         ; format signed 16-bit value (A=lo, X=hi, Y=pos)
        cpx #$80                ; negative?
        bcc B5_91               ; no
        eor #$FF                ; two's-complement negate lo
        adc #$00
        pha
        txa                     ; negate hi
        eor #$FF
        adc #$00
        tax
        pla
        sec                     ; C=1: value is negative
B5_91:  sta BCD_LO              ; abs(value) lo
        stx BCD_HI              ; abs(value) hi
        lda #PLUS_SIGN
        bcc B5_9D               ; positive -> '+'
        lda #MINUS_SIGN         ; negative -> '-'
B5_9D:  pha                     ; save sign char (stored after digits)
        lda #COMMA
        sta INBUF+1,y           ; comma separator after this field
B5_A3:  ldx #$11                ; 17-step binary -> decimal
        lda #$00
        clc
B5_A8:  rol
        cmp #$0A
        bcc B5_AF
        sbc #$0A
B5_AF:  rol BCD_LO
        rol BCD_HI
        dex
        bne B5_A8
        ora #DIGIT_ZERO         ; digit -> ASCII
        sta INBUF,y             ; store digit (right to left)
        dey
        beq B5_C8               ; finished X coord -> store sign
        cpy #$07
        beq B5_C8               ; finished Y coord -> store sign
        cpy #$0E                ; finished status -> store sign
        bne B5_A3
B5_C8:  pla                     ; sign/separator
        sta INBUF,y
        rts

; ==================================================================
; B6: ReadMouse and single-byte MCU read
;   B6_FN2: ReadMouse -- send CMD_READMOUSE, read 5 bytes into the screen holes
;   B6_FN1: read one byte from the MCU into MOUSE_CMD. Port B is already
;           configured by the WRITE_FIRST_BYTE that began this command sequence.
; ==================================================================
B6_FN2: lda MOUSE_MODE,x        ; ReadMouse
        and #MOUSE_ON           ; is mouse on (mode bit 0)?
        beq B6_INACTIVE
        lda #CMD_READMOUSE
        jsr WRITE_FIRST_BYTE    ; configure Port B + send CMD_READMOUSE
        jsr READ_MCU_BYTE       ; read the 5-byte response into the screen holes
        sta MOUSE_X_LO,x
        jsr READ_MCU_BYTE
        sta MOUSE_X_HI,x
        jsr READ_MCU_BYTE
        sta MOUSE_Y_LO,x
        jsr READ_MCU_BYTE
        sta MOUSE_Y_HI,x
        jsr READ_MCU_BYTE
        sta MOUSE_STATUS,x
B6_INACTIVE:
        clc                     ; EXIT_OK
        rts
B6_FN1: jsr READ_MCU_BYTE       ; read a single byte into MOUSE_CMD
        sta MOUSE_CMD,x
        rts

; ==================================================================
; B7: multi-byte MCU write (ClampMouse, PosMouse, SetVBLCnts, TimeData)
; Push 1-5 data bytes onto the stack then send them via WRITE_LOOP.
; ==================================================================
B7_FN1: lda MOUSE_CMD,x
        cmp #CMD_POSMOUSE       ; PosMouse?
        beq B7_29
        cmp #CMD_CLAMPMOUSE     ; ClampMouse X?
        beq B7_18
        cmp #CMD_CLAMPMOUSE+1   ; ClampMouse Y?
        beq B7_18
        cmp #CMD_SETVBLCNTS     ; SetVBLCnts?
        bne B7_41
        pha                     ; push command; rate byte already on stack
        lda #$02                ; send 2 bytes
        bne B7_5D               ; always
B7_18:  lda CLAMP_MAX_HI        ; push clamping bounds
        pha
        lda CLAMP_MIN_HI
        pha
        lda CLAMP_MAX_LO
        pha
        lda CLAMP_MIN_LO
        bcs B7_38               ; always (carry set from the cmp above)
B7_29:  lda MOUSE_Y_HI,x        ; push mouse coords
        pha
        lda MOUSE_Y_LO,x
        pha
        lda MOUSE_X_HI,x
        pha
        lda MOUSE_X_LO,x
B7_38:  pha                     ; last data byte
        lda MOUSE_CMD,x
        pha                     ; command byte
        lda #$05                ; send 5 bytes
        bne B7_5D               ; always
B7_41:  and #$0C                ; command bits 3:2 = how many bytes to send
        lsr
        lsr
        lsr                     ; bit 2 -> carry
        bcs B7_86
        lsr                     ; bit 3 -> carry
        bcc B7_57               ; neither: command only
        lda CLAMP_MIN_HI
        pha
        lda MOUSE_CMD,x
        pha
        lda #$02
        bne B7_5D               ; always
B7_57:  lda MOUSE_CMD,x
        pha
        lda #$01                ; command byte only
B7_5D:  sta MOUSE_CMD,x         ; byte count (WRITE_LOOP decrements to 0)
        bne WRITE_LOOP          ; always
B7_86:  lsr
        bcs B7_9C
        lda CLAMP_MAX_LO
        pha
        lda CLAMP_MIN_LO
        pha
        lda MOUSE_CMD,x
        pha
        lda #$03                ; send 3 bytes
        sta MOUSE_CMD,x
        bne WRITE_LOOP          ; always
B7_9C:  lda CLAMP_MIN_HI
        pha
        lda CLAMP_MAX_LO
        pha
        lda CLAMP_MIN_LO
        pha
        lda MOUSE_CMD,x
        pha
        lda #$04                ; send 4 bytes
        sta MOUSE_CMD,x
WRITE_LOOP:                     ; bytes on the stack (command on top), count in MOUSE_CMD,x
        pla                     ; first byte = the command
        jsr WRITE_FIRST_BYTE    ; configure Port B + write it
        dec MOUSE_CMD,x
        beq B7_DONE             ; command-only write
B7_NEXT:
        pla                     ; next data byte
        jsr WRITE_MCU_BYTE      ; Port B already configured
        dec MOUSE_CMD,x
        bne B7_NEXT
B7_DONE:
        clc                     ; EXIT_OK
        rts

; ==================================================================
; WRITE_FIRST_BYTE / WRITE_MCU_BYTE -- write one byte to the MCU.
; Port B's DDRB must be configured after a reset before any read or write to
; the MCU. The protocol always starts with the Apple II sending a command byte,
; so WRITE_FIRST_BYTE sets up DDRB, then falls into WRITE_MCU_BYTE. Because
; it runs at the start of every write sequence, DDRB gets reconfigured more
; often than strictly necessary, but this keeps the code simple.
; WRITE_MCU_BYTE is used for the 2nd..Nth bytes of a multi-byte write. Both
; take the byte in A and return via RTS, and neither disturbs the overflow flag,
; so a caller may set V beforehand to remember whether a response read should follow.
; ==================================================================
WRITE_FIRST_BYTE:
        pha                     ; save the byte
        lda PIA_CRB,y           ; configure Port B handshake outputs
        and #SELECT_DDR
        sta PIA_CRB,y
        lda #$3E
        sta PIA_DDRB,y          ; DDRB = 0011 1110: PB1-PB5 outputs
        lda PIA_CRB,y
        ora #SELECT_PR
        sta PIA_CRB,y
        pla                     ; restore the byte
WRITE_MCU_BYTE:
        pha                     ; save the byte
WB_WAIT_ACK_CLR:
        lda PIA_PB,y            ; wait for MCU to clear WRITE_ACK (PB7=0)
        bmi WB_WAIT_ACK_CLR
        lda PIA_CRA,y
        and #SELECT_DDR
        sta PIA_CRA,y           ; access DDRA
        lda #$FF
        sta PIA_DDRA,y          ; config PA for write (all outputs)
        lda PIA_CRA,y
        ora #SELECT_PR
        sta PIA_CRA,y           ; access PA
        pla                     ; byte to write
        sta PIA_PA,y            ; write byte to MCU
        lda PIA_PB,y
        ora #WRITE_REQ
        sta PIA_PB,y            ; assert WRITE_REQ
WB_WAIT_ACK:
        lda PIA_PB,y
        bpl WB_WAIT_ACK         ; wait for WRITE_ACK (PB7=1)
        and #<(~WRITE_REQ)
        sta PIA_PB,y            ; clear WRITE_REQ
        rts

; ==================================================================
; READ_MCU_BYTE -- read one byte from the MCU and return it in A. Port B is
; already configured (by the WRITE_FIRST_BYTE that began the command sequence).
; Does not disturb the overflow flag.
; ==================================================================
READ_MCU_BYTE:
        lda PIA_CRA,y
        and #SELECT_DDR
        sta PIA_CRA,y           ; access DDRA
        lda #$00
        sta PIA_DDRA,y          ; config PA for read )all inputs)
        lda PIA_CRA,y
        ora #SELECT_PR
        sta PIA_CRA,y           ; access PA
RB_WAIT_REQ:
        lda PIA_PB,y            ; wait for READ_REQ (PB6=1)
        asl
        bpl RB_WAIT_REQ
        lda PIA_PA,y            ; read the byte from the MCU
        pha                     ; save it
        lda PIA_PB,y
        ora #READ_ACK
        sta PIA_PB,y            ; assert READ_ACK
RB_WAIT_REQ_CLR:
        lda PIA_PB,y            ; wait for READ_REQ clear (PB6=0)
        asl
        bmi RB_WAIT_REQ_CLR
        lda PIA_PB,y
        and #<(~READ_ACK)
        sta PIA_PB,y            ; clear READ_ACK
        pla                     ; return the byte in A
        rts

        .res  $D000 - *, $FF    ; pad image out to a full 2KB ($C800-$CFFF)
