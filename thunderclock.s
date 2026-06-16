; ============================================================================
; ThunderClock Plus REV 1.3 - Apple II Peripheral Card ROM
; Disassembly by Mike Wiese
; 2026-06-16
; ============================================================================
;
; ROM MEMORY MAP:
;   The physical 2KB ROM is mapped in two ways simultaneously:
;     $Cn00-$CnFF  256-byte "slot ROM" for slot n (first $100 bytes of ROM)
;     $C800-$CFFF  2KB "expanded ROM" (same first $100 bytes + more)
;
;   Because the first $100 bytes appear at both locations, code
;   in the range $C800-$C8FF is also executable from $Cn00-$CnFF.
;   Addresses shown in this listing use the $C8xx form, but on a card in
;   (e.g.) slot 1, those same bytes appear at $C1xx.
;
; HARDWARE:
;   NEC uPD1990AC real-time clock/calendar chip.
;   Optional BSR/X-10 ultrasonic RTC_TRANSDUCER.
;
; CONTROL REGISTER  ($C08x,Y where Y = slot# * $10)
;
;   Write:
;      bit  6   = interrupt enable
;      bits 5:3 = uPD1990AC command bits C2 C1 C0 (see RTC_* equates below)
;      bit  2   = uPD1990AC STB
;      bit  1   = uPD1990AC CLK
;      bit  0   = uPD1990AC DATA IN
;      bit  5   = (also) BSR/X-10 ultrasonic RTC_TRANSDUCER
;
;   Read:
;      bit  7   = uPD1990AC DATA OUT
;      bit  5   = interrupt asserted

; ============================================================
; Screen hole usage
; ============================================================
; Scratch area
SLOT16          = $0778         ; slot# * $10  (Y value for $C08x,Y)
MSLOT           = $07F8         ; slot page number $Cn

; Slot #n screen holes at address,X where X = slot $Cn
CLOCK_IRQEN1    = $0478-$C0     ; + $Cn   interrupt enable byte 1
CLOCK_BSRDUR    = $04F8-$C0     ; + $Cn   BSR command duration
CLOCK_WMODE     = $0578-$C0     ; + $Cn   write mode ('!', '*', '^')
CLOCK_RMODE     = $05F8-$C0     ; + $Cn   read mode  ('%','&','<','>','#', 0=Mountain)
CLOCK_DOUT      = $0678-$C0     ; + $Cn   DATA OUT nibble temp storage
CLOCK_LCNT1     = $06F8-$C0     ; + $Cn   loop counter 1
CLOCK_LCNT2     = $0778-$C0     ; + $Cn   loop counter 2
CLOCK_IRQEN2    = $07F8-$C0     ; + $Cn   interrupt enable byte 2, also used as a temp in SETTIMDIG

; ============================================================
; uPD1990AC control register (at $C08x,Y where Y = slot * $10)
; ============================================================
RTC_CONTROL     = $C080

; ---- RTC commands in bits 5:3 ------------------------------
RTC_REG_HOLD    = %000 << 3     ; $00
RTC_SHIFT       = %001 << 3     ; $08
RTC_TIME_SET    = %010 << 3     ; $10
RTC_TIME_READ   = %011 << 3     ; $18
RTC_TP_64HZ     = %100 << 3     ; $20
RTC_TP_256HZ    = %101 << 3     ; $28
RTC_TP_2048HZ   = %110 << 3     ; $30

; ---- RTC bit masks -----------------------------------------
RTC_CLK         = 1 << 1        ; $02
RTC_STROBE      = 1 << 2        ; $04
RTC_TRANSDUCER  = 1 << 5        ; $20
RTC_IRQ_ENABLE  = 1 << 6        ; $40

; APPLE II SYSTEM ADDRESSES
CSWL            = $36           ; character output switch low
CSWH            = $37           ; character output switch high
KSWL            = $38           ; keyboard input switch low
;
; ============================================================================

   .org $C800

; ============================================================================
; $Cn00  Called by PR#n / IN#n to install the CSW / KSW hooks.
; ============================================================================

   php
   sei
   plp
   bit $FF58                    ; $FF58 = $60, so V=1
   bvs SAVE_STATE               ; always

; ============================================================================
; $Cn08  CLOCK_READ
;
;   IN#n installs $Cn08 into KSW.
; ============================================================================

CLOCK_READ:
   sec                          ; C=1 -> CLK_DISPATCH -> READ_TIME
   bcs LC80C                    ; always

; ============================================================================
; $Cn0B  CLOCK_WRITE
;
;   PR#n installs $Cn0B into CSW.
; ============================================================================

CLOCK_WRITE:
   clc                          ; C=0 -> CLK_DISPATCH -> CLK_W_CHAR

; CLOCK_READ and CLOCK_WRITE converge here
LC80C:
   clv                          ; clear V -- marks this as a warm (non-init) call

SAVE_STATE:
   php                          ; save processor status
   sei                          ; disable interrupts
   pha                          ; save A
   txa
   pha                          ; save X
   tya
   pha                          ; save Y
   lda $CFFF                    ; disable all $C800 expansion ROMs
   jsr GETSLOT                  ; opcode fetch from $Cnxx re-enables OUR $C800 ROM
                                ; execution transfers from $Cnxx slot ROM to $C800 ROM

; ============================================================================
; $C81A  GETSLOT -- DERIVE SLOT NUMBER FROM JSR RETURN ADDRESS
;
;   The JSR above is executed from mirrored slot ROM at memory address $Cnxx,
;   which pushes the return address $Cnxx+2 on the stack.
;   PLA twice yields high byte $Cn. Four ASL shifts move the lower
;   nibble n into bits 7-4, giving SLOT16 = n*$10 for $C080,Y I/O addressing.
; ============================================================================

GETSLOT:
   pla                          ; discard low byte of return address
   pla                          ; A = high byte = slot page number $Cn
   tsx                          ; get stack pointer
   sta MSLOT                    ; MSLOT = $Cn
   asl                          ; shift slot# n into upper nibble:
   asl                          ; $Cn << 4: e.g. $C1->$10
   asl
   asl
   sta SLOT16                   ; SLOT16 = n*$10
   pla                          ; pop saved Y
   pla                          ; pop saved X
   pla                          ; pop saved A (the original character)
   tay                          ; Y = original character
   pla                          ; pop saved flags
   txs                          ; restore stack pointer (stack is clean again)
   ora #$04                     ; set I flag
   pha
   plp                          ; restore flags with interrupts disabled
   tya                          ; A = original character
   ldy SLOT16                   ; Y = slot# * $10
   ldx MSLOT                    ; X = $Cn
   and #$7F                     ; strip high bit from character
   pha                          ; push stripped character for CLK_DISPATCH
   bvc CLK_DISPATCH             ; V=0 (CLOCK_READ/CLOCK_WRITE path) -> CLK_DISPATCH
                                ; V=1 ($Cn00 init path) -> install check

; ============================================================================
; $C83D  Install CSW / KSW
;
;   Reached when V=1 (the $Cn00 init path).
;   Checks which routine needs installing by examining CSWL:
;     CSWL = 0:    PR#n just ran; CSWH=$Cn, CSWL=0 -> install CLOCK_WRITE into CSW
;     CSWL != 0:   IN#n just ran -> install CLOCK_READ into KSW
; ============================================================================

   clv                          ; clear V (mark as warm from here on)
   lda CSWL                     ; is CSWL already set?
   bne CLK_INSTALL_KSW          ; yes -> skip to install KSW
   cpx CSWH                     ; is CSWH pointing to our slot?
   beq CLK_INSTALL_CSW          ; yes -> install CLOCK_WRITE into CSW

; --- IN#n path: install CLOCK_READ ($Cn08) into KSW ---
CLK_INSTALL_KSW:
   lda #<CLOCK_READ             ; $08
   sta KSWL                     ; patch KSWL (KSWH=$Cn already set by IN#n)
   sec                          ; C=1 -> CLK_DISPATCH -> READ_TIME (initial read)

CLK_DISPATCH:
   bcc CLK_W_CHAR               ; C=0 (CLOCK_WRITE path) -> character CLK_DISPATCH
   jmp READ_TIME                ; C=1 (CLOCK_READ path) -> read clock, format string

; --- PR#n path: install CLOCK_WRITE ($Cn0B) into CSW ---
CLK_INSTALL_CSW:
   lda #<CLOCK_WRITE            ; $0B
   sta CSWL                     ; patch CSWL (CSWH=$Cn already set by PR#n)
   lda #$5E                     ; '^' = BSR command mode
   sta CLOCK_WMODE,x            ; CLOCK_WMODE = '^'
   lda #$0A
   sta CLOCK_BSRDUR,x           ; CLOCK_BSRDUR = 10
   lda #$00
   sta CLOCK_RMODE,x            ; read mode = 0 (Mountain Clock format)
                                ; fall thru, handle character

; ============================================================================
; CLK_W_CHAR -- CHARACTER DISPATCH
;
;   Interprets the character written via CLOCK_WRITE.
;   Recognised mode control characters are consumed here; all others are
;   handled based on the current write mode (CLOCK_WMODE).
;
;   READ MODE CONTROL characters:
;     '%' ($25)  Applesoft AM/PM format    -> "TUE MAY 12 4:32:55 PM"
;     '&' ($26)  Applesoft 24-hour format  -> "TUE MAY 12 16:32:55"
;     '>' ($3E)  Integer   AM/PM format    -> same as '%'
;     '<' ($3C)  Integer   24-hour format  -> same as '&'
;     '#' ($23)  Numeric format            -> "05,02,12,16,32,55"
;
;   WRITE MODE CONTROL characters:
;     '!' ($21)  set time mode: "!MM W DD HH MM SS" + CR to set the clock
;     '*' ($2A)  BSR duration mode: next char is a BSR duration code A-Z
;     '^' ($5E)  BSR command mode: send BSR command letter A-V

;   INTERRUPT RATE MODE CONTROL characters:
;     ',' ($2C)  Set interrupt rate to 64 Hz
;     '.' ($2E)  Set interrupt rate to 256 Hz
;     '/' ($2F)  Set interrupt rate to 2048 Hz
; ============================================================================

CLK_W_CHAR:
   pla                          ; pull the stripped character
; --- READ MODE selectors ---
   cmp #$25                     ; '%' Applesoft AM/PM?
   beq SETRMODE
   cmp #$26                     ; '&' Applesoft 24-hour?
   beq SETRMODE
   cmp #$3C                     ; '<' Integer 24-hour?
   beq SETRMODE
   cmp #$3E                     ; '>' Integer AM/PM?
   beq SETRMODE
   cmp #$23                     ; '#' Numeric?
   beq SETRMODE
; --- WRITE MODE selectors ---
   cmp #$5E                     ; '^' BSR command mode?
   beq SETWMODE
   cmp #$21                     ; '!' set time mode?
   beq SETTIMEMD
   cmp #$2A                     ; '*' BSR duration mode?
   beq SETWMODE
; --- Interrupt rate selectors ---
   ldx #RTC_TP_64HZ
   cmp #$2C                     ; ',' 64 Hz?
   beq SETRATE
   ldx #RTC_TP_256HZ
   cmp #$2E                     ; '.' 256 Hz?
   beq SETRATE
   ldx #RTC_TP_2048HZ
   cmp #$2F                     ; '/' 2048 Hz?
   beq SETRATE

; --- not a mode control character: handle based on the current write mode ---
   ldx MSLOT
   pha                          ; save character
   lda CLOCK_WMODE,x
   cmp #$21                     ; '!' set time mode?
   beq SETTIMDIG
   cmp #$5E                     ; '^' BSR command mode?
   beq BSRCHAR

; --- else assume '*' BSR duration mode: update CLOCK_BSRDUR and enter BSR command mode ---
   pla                          ; restore duration code character
   and #$1F                     ; isolate low 5 bits
   asl                          ; x2
   sec
   sbc #$01                     ; -> duration value
   sta CLOCK_BSRDUR,x           ; store duration
   lda #$5E                     ; -> BSR command mode
    bne SETWMODE                ; always

; --- BSR command mode: send BSR/X-10 command ---
BSRCHAR:
   pla                          ; restore BSR command character
   sec
   sbc #$41                     ; A-='A': 0=A, 1=B, ..., 21=V
   bmi HOOKEXIT                 ; < 'A' -> invalid
   cmp #$16
   bpl HOOKEXIT                 ; > 'V' -> invalid
   tax
   lda BSR_TABLE,x              ; fetch BSR command byte for this char
   jmp BSRSEND

; --- SETRMODE: store character as format selector ---
SETRMODE:
   sta CLOCK_RMODE,x            ; read mode = '%','&','<','>','#', etc.
   jmp FINALIZE

; --- SETTIMEMD: enter set-time mode ---
SETTIMEMD:
   lda #RTC_TP_64HZ
   jsr RTC_CMD                  ; set 64 Hz mode (why?)
   lda #RTC_SHIFT
   jsr RTC_CMD                  ; enter shift mode
   lda #$21                     ; write mode = '!'

; --- SETWMODE: store new write mode ---
SETWMODE:
   sta CLOCK_WMODE,x            ; CLOCK_WMODE = new mode

HOOKEXIT:
   jmp FINALIZE

; --- SETRATE: set interrupt rate ---
SETRATE:
   txa
   jsr RTC_CMD
   bne HOOKEXIT                 ; always

; ============================================================================
; SET-TIME DIGIT HANDLER
;
;   In set-time mode ('!' write mode) each arriving character is a digit or
;   space forming the time string "!MM W DD HH MM SS<CR>".
;
;   The uPD1990AC shift register acts as a 10-nibble delay line.
;
;   Each arriving digit calls CLK_SHIFT, which clocks the digit nibble into the
;   MSB of the shift register while the oldest nibble exits from the LSB as
;   data-out. After 11 digits have been shifted in, the shift register
;   holds nibbles 2-11, and the very first nibble shifted in (month tens)
;   has just exited as the data-out of the 11th (seconds ones) CLK_SHIFT call.
;
;   MONTH COMBINING -- the uPD1990AC stores month as a hexadecimal nibble,
;   not BCD. The tens digit of the month (0 or 1) is captured indirectly:
;   the BEQ/LDA sequence converts the data-out to 0 (if zero) or 10
;   (if non-zero), storing it in CLOCK_IRQEN2,x. Because the shift register is
;   40 bits, the month tens digit (the first one shifted in) is
;   exactly the data-out on the 11th CLK_SHIFT call. So at CR time,
;   CLOCK_IRQEN2,x = 0 for months 1-9, or 10 for months 10-12.
;
;   COMMITTIME (on CR) performs two phases using 10+10 CLK_SHIFT calls:
;     Phase 1 (read):  10 CLK_SHIFT calls read out all 10 nibbles from the
;                      shift register, pushing each onto the stack.
;                      The first data-out is the month ones digit; ADC CLOCK_IRQEN2,x
;                      adds the month tens digit value to get the month nibble.
;     Phase 2 (write): 10 PLA+CLK_SHIFT calls pop the stack (LIFO = reverse
;                      order) and shift the values back in. The reversal
;                      places nibbles in the correct chip layout with
;                      the month in the MSB ... seconds in the LSB
;   Finally RTC_CMD with RTC_TIME_SET latches the shift register data
;   into the time counter.
; ============================================================================

SETTIMDIG:
   pla
   cmp #$0D                     ; CR?
   beq COMMITTIME
   cmp #$20
   beq FINALIZE                 ; ignore spaces
   and #$0F                     ; extract BCD digit
   jsr CLK_SHIFT
   beq LC8F4
   lda #10

LC8F4:
   sta CLOCK_IRQEN2,x           ; CLOCK_IRQEN2 = 0 if data-out was 0, else 10
   clc
   bcc FINALIZE                 ; always

COMMITTIME:
; Phase 1: read out shift reg (10 nibbles) onto stack
   jsr CLK_SHIFT                ; read out 1st nibble: month ones digit
   adc CLOCK_IRQEN2,x           ; add month tens value
   pha                          ; push hexadecimal month nibble
   lda #$09
   sta CLOCK_LCNT1,x            ; CLOCK_LCNT1 = 9

LC906:
   jsr CLK_SHIFT                ; read out remaining 9 nibbles
   pha
   dec CLOCK_LCNT1,x
   bne LC906
   lda #$0A
   sta CLOCK_LCNT1,x            ; CLOCK_LCNT1 = 10

LC914:
; Phase 2: pop stack and shift back into shift reg (LIFO reverses order)
   pla
   jsr CLK_SHIFT
   dec CLOCK_LCNT1,x
   bne LC914
   lda #RTC_TIME_SET
   jsr RTC_CMD                  ; copy shift register data to the time counter
   bne SETWMODE                 ; always -> update CLOCK_WMODE

; ----------------------------------------------------------------------------
; $C924  RETCR -- SYNTHESISE CR RETURN VALUE FOR CALLER
;
;   Reconstructs the register stack so that a CR is returned in A
;   to the original caller, then falls into FINALIZE.
; ----------------------------------------------------------------------------

RETCR:
   tsx
   pla
   pla
   tya
   pha
   pla
   pla
   lda #$8D                     ; CR
   pha
   txs

; ----------------------------------------------------------------------------
; $C92F  FINALIZE -- INTERRUPT RE-ENABLE CHECK, RESTORE STATE
;
;   Reading/writing the THUNDERCLOCK resets its interrupt hardware.
;   If scratchpad RAM bytes CLOCK_IRQEN1,x and CLOCK_IRQEN2,x (at $0478+n and $07F8+n)
;   both equal RTC_IRQ_ENABLE ($40), write RTC_IRQ_ENABLE to the control register
;   to re-enable interrupts.
; ----------------------------------------------------------------------------

FINALIZE:
   ldx MSLOT
   ldy SLOT16
   lda CLOCK_IRQEN1,x
   cmp CLOCK_IRQEN2,x           ; do both interrupt enable bytes match?
   bne RESTORE_STATE
   ora CLOCK_IRQEN2,x
   beq RESTORE_STATE            ; both zero -> interrupts not enabled
   cmp #RTC_IRQ_ENABLE          ; both = RTC_IRQ_ENABLE ($40)?
   bne RESTORE_STATE
   sta RTC_CONTROL,y            ; write RTC_IRQ_ENABLE to control register

RESTORE_STATE:
   pla
   tay                          ; restore Y
   pla
   tax                          ; restore X
   pla                          ; restore A
   plp                          ; restore flags
   rts

; ============================================================================
; $C950  READ_TIME -- READ uPD1990AC AND FORMAT OUTPUT STRING
;
;   Entered from CLK_DISPATCH when C=1 (CLOCK_READ path, $Cn08 entry).
;   Read mode (set by a prior COUT of '%','&','<','>','#') selects
;   the output format.
;
; uPD1990AC DATA ORDER (shift register, LSB-first, 10 nibbles = 40 bits):
;   Nibble  1   seconds ones digit  (0-9  BCD)   shifted out first
;   Nibble  2   seconds tens digit  (0-5  BCD)
;   Nibble  3   minutes ones digit  (0-9  BCD)
;   Nibble  4   minutes tens digit  (0-5  BCD)
;   Nibble  5   hours ones digit    (0-9  BCD)
;   Nibble  6   hours tens digit    (0-2  BCD)
;   Nibble  7   date ones digit     (0-9  BCD)
;   Nibble  8   date tens digit     (0-3  BCD)
;   Nibble  9   day of week         (0-6  BCD)    0=Sun
;   Nibble 10   month               (1-12 binary) shifted out last
; ============================================================================

READ_TIME:
   pla                          ; discard saved character
   lda #RTC_TIME_READ
   jsr RTC_CMD                  ; copy time counter data to the shift register
   lda #RTC_SHIFT
   jsr RTC_CMD                  ; enter shift mode
   lda #$09
   sta CLOCK_LCNT1,x            ; CLOCK_LCNT1 = 9

; --- Read nibbles 1-9: seconds ones digit through day of week ---
RDNIBBLE:
   jsr CLK_SHIFT
   cmp #$0A                     ; valid BCD?
   bmi LC969
   lda #$00                     ; clamp invalid nibble to 0

LC969:
   pha                          ; push nibble
   dec CLOCK_LCNT1,x
   bne RDNIBBLE

; --- Read nibble 10: month ---
   jsr CLK_SHIFT
   cmp #$0D
   bmi LC978
   lda #$00

LC978:
   pha                          ; push month

; --- Select output format ---
   lda CLOCK_RMODE,x            ; read mode
   beq FMT_NUMERIC              ; 0 -> Mountain Clock format
   cmp #$23                     ; '#' Numeric?
   bne FMT_DAYNAME              ; no -> day-name format

; ============================================================================
; FMT_NUMERIC
;
;   Handles these two read modes:
;    0  Mountain -> "05/12 16;32;55.000"
;   '#' Numeric  -> "05,02,12,16,32,55"
; ============================================================================

FMT_NUMERIC:
   ldy #$00                     ; Y = month tens digit (0 for Jan-Sep)
   pla                          ; pop month
   cmp #$0A
   bmi LC98D
   iny                          ; Y=1 for Oct-Dec
   sec
   sbc #$0A

LC98D:
   pha                          ; save month ones
   tya                          ; A = month tens
   ldx #$00                     ; X = text buffer index
   jsr EMIT_DIGIT               ; emit month tens
   pla
   jsr EMIT_DIGIT               ; emit month ones
   ldy MSLOT                    ; Y = $Cn
   lda CLOCK_RMODE,y            ; read mode
   bne FMT_NUM24                ; non-zero -> numeric path

; --- Mountain format: "/" + 4 field pairs + back-patch space + ".000" ---
   lda #$AF                     ; '/' | $80
   jsr EMIT_CHAR
   pla                          ; pop day-of-week (not used in Mountain format)
   ldy #$04                     ; 4 pairs: DATE, HR, MIN, SEC

MTNPAIR:
   pla                          ; pop tens nibble
   jsr EMIT_DIGIT
   pla                          ; pop ones nibble
   jsr EMIT_DIGIT
   dey
   beq LC9BA
   lda #$3B                     ; ';' (first one will be patched to space below)
   jsr EMIT_CHAR
   bne MTNPAIR

LC9BA:
   lda #$A0                     ; Apple II high-bit space
   sta $0205                    ; back-patch buf[5]: "MM/DD;HH..." -> "MM/DD HH..."

LC9BF:
   lda MTN_SUFFIX,y             ; emit ".000"
   beq FMTDONE
   jsr EMIT_CHAR
   iny
   bne LC9BF

; --- Numeric: 5 field pairs with "," separators ---
FMT_NUM24:
   lda #$00
   pha                          ; leading zero pad
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

; ============================================================================
; FMT_DAYNAME -- DAY-NAME FORMAT  "TUE MAY 12 4:32:55 PM" / "...16:32:55"
; ============================================================================

FMT_DAYNAME:
   pla                          ; pop month
   tax                          ; X = month
   pla                          ; pop day-of-week
   asl
   asl                          ; A = day-of-week * 4
   tay                          ; Y = day-of-week * 4 (index into DAY_TABLE)
   txa
   asl
   asl                          ; A = month * 4
   pha                          ; save month * 4 (index into MONTH_TABLE)
   ldx MSLOT
   lda CLOCK_RMODE,x            ; A = read mode
   ldx #$A0                     ; default leading char = space | $80
   cmp #$3C                     ; '<' or '>'?
   bcs LC9F8
   ldx #$A2                     ; Applesoft: '"' | $80 as leading char

LC9F8:
   txa
   ldx #$00                     ; reset text buffer index
   jsr EMIT_CHAR

; --- Emit day name ---
EMITDAY:
   lda DAY_TABLE,y              ; e.g. day-of-week=2: $CBA3+8 = "TUE "
   iny
   jsr EMIT_CHAR
   cmp #$A0                     ; space (terminator)?
   bne EMITDAY

   pla                          ; pop month * 4
   tay                          ; Y = month * 4 (index into MONTH_TABLE)

; --- Emit month name ---
EMITMON:
   lda MONTH_TABLE-4,y          ; month is 1 based so index into MONTH_TABLE-4
   iny
   jsr EMIT_CHAR
   cmp #$A0
   bne EMITMON

; --- Emit date (leading-zero suppressed) ---
   pla                          ; date tens
   jsr EMIT_NOZERO
   pla                          ; date ones
   jsr EMIT_DIGIT
   jsr EMIT_SPACE
   ldy #$03                     ; 3 pairs: HR, MIN, SEC

; --- Emit H:MM:SS ---
EMITTIME:
   pla                          ; hours tens
   jsr EMIT_NOZERO              ; suppress leading zero on hours
   bne LCA2C                    ; (always non-zero after emit)

EMITLO:
   jsr EMIT_DIGIT               ; emit low nibble of current field

LCA2C:
   pla                          ; hours ones (first pass), then minutes ones, seconds ones
   jsr EMIT_DIGIT
   dey
   beq CHKAMPM
   lda #$BA                     ; ':' | $80
   jsr EMIT_CHAR
   pla                          ; minutes tens (second pass), seconds tens (third pass)
   jmp EMITLO

CHKAMPM:
   ldy MSLOT
   lda CLOCK_RMODE,y            ; read mode
   cmp #$25                     ; '%'?
   beq CONV_12H
   cmp #$3E                     ; '>'?
   bne FMTFINAL                 ; 24-hour -> no AM/PM

; ============================================================================
; CONV_12H -- 24-HOUR TO 12-HOUR CONVERSION + "AM"/"PM"
; ============================================================================

CONV_12H:
   ldy #$41                     ; Y = 'A' (AM)
   lda $020C                    ; hours tens digit from text buffer
   cmp #$A0                     ; was it suppressed?
   bne LCA55
   lda #$30                     ; treat as '0'

LCA55:
   asl
   asl
   asl
   asl                          ; shift tens into upper nibble
   sta $0220
   lda $020D                    ; hours ones digit
   and #$0F
   ora $0220                    ; combine -> BCD $00-$23
   cmp #$12
   bmi LCA6A
   ldy #$50                     ; Y = 'P' (PM)

LCA6A:
   cmp #$00                     ; midnight?
   bne LCA72
   lda #$12                     ; -> display as 12
   bne LCA7B

LCA72:
   cmp #$13                     ; >= 1 PM?
   bmi LCA8C                    ; 1-12 -> already correct
   sed                          ; BCD mode
   sec
   sbc #$12                     ; subtract 12: 13->1, ..., 23->11
   cld

LCA7B:
   ldx #$0C                     ; re-emit at buffer offset $0C
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
   tya                          ; A = 'A' or 'P'
   jsr EMIT_CHAR
   lda #$4D                     ; 'M'
   jsr EMIT_CHAR                ; -> " AM" or " PM"

FMTFINAL:
   txa
   tay
   lda #$8D                     ; CR | $80
   jsr EMIT_CHAR                ; terminate string
   jmp RETCR

; ============================================================================
; GETLN TEXT BUFFER HELPERS
; ============================================================================

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

; ============================================================================
; RTC_CMD -- STROBE COMMAND INTO uPD1990AC
;
;   Entry: A = command in bits 5:3, Y = $n0
; ============================================================================

RTC_CMD:
   sta RTC_CONTROL,y            ; write command w/o strobe
   ora #RTC_STROBE
   sta RTC_CONTROL,y            ; raise strobe
; STB is held high for 54 cycles (6 JSR + 46 STBDLY + 2 EOR)
; comfortably meeting the uPD1990AC >40 us STB pulse width requirement.
   jsr STBDLY                   ; delay
   eor #RTC_STROBE              ; clear strobe bit
   sta RTC_CONTROL,y            ; drop strobe

STBDLY:
; Executes STBDL1 twice: once via JSR, then falls through to STBDL1 a second time.
   jsr STBDL1
STBDL1:
   pha
   pha
   pla
   pla
   rts

; ============================================================================
; CLK_SHIFT -- CLOCK ONE NIBBLE INTO AND OUT OF THE uPD1990AC SHIFT REGISTER
;
;   Each call shifts the entire 40-bit shift register 4 bits to the right.
;   The 4 bits of A on entry are shifted into the MSB (data in).
;   The 4 bits that exit from the LSB are returned in A (data out).
;
;   Entry: A = nibble to shift in (low 4 bits)
;          X = $Cn, Y = $n0
;   Exit:  A = nibble shifted out (low 4 bits)
; ============================================================================

CLK_SHIFT:
   pha                          ; save data-in
   lda #4
   sta CLOCK_LCNT2,x            ; 4 bits
   lda #0
   sta CLOCK_DOUT,x             ; CLOCK_DOUT = 0

SHLOOP:
; In RTC_SHIFT mode, the LSB of the shift register appears on DATA OUT, which is
; read via bit 7 of the control register
   lda RTC_CONTROL,y            ; get DATA OUT bit in bit 7
   asl                          ; DATA OUT bit -> carry
   ror CLOCK_DOUT,x             ; rotate into CLOCK_DOUT
   pla
   pha                          ; get & resave data-in
   and #1                       ; bit 0 only
   sta RTC_CONTROL,y            ; write one bit of data to DATA IN
   ora #RTC_CLK
   sta RTC_CONTROL,y            ; raise CLK: clock the shift register
   eor #RTC_CLK
   sta RTC_CONTROL,y            ; lower CLK
   pla
   ror                          ; shift data-in for next bit
   pha
   dec CLOCK_LCNT2,x            ; done 4 bits?
   bne SHLOOP

   pla                          ; adjust stack
   lda CLOCK_DOUT,x
   clc

ROR4:
   ror
   ror
   ror
   ror
   rts

; ============================================================================
; $CB04  BSRSEND -- TRANSMIT BSR/X-10 COMMAND VIA ULTRASONIC INTERFACE
; ============================================================================

BSRSEND:
   pha
   ldx MSLOT
   lda CLOCK_BSRDUR,x           ; load duration
   sta CLOCK_LCNT2,x

BSRLOOP:
   jsr LONGBIT
   pla
   pha
   jsr BITOUT                   ; serialise command
   pla
   pha
   eor #$F8
   jsr BITOUT                   ; serialise complement
   ldx #$A0
   jsr CARRIER
   ldx #$A0
   jsr CARRIER
   ldy #$18
   jsr TDELAY
   ldx MSLOT
   dec CLOCK_LCNT2,x
   bne BSRLOOP
   pla
   ldy #$BC

BSRWAIT:
   dex
   bne BSRWAIT
   dey
   bne BSRWAIT
   jmp FINALIZE

BITOUT_ENTRY:
   pha
   bcc LC848
   jsr LONGBIT
   beq LC84B                    ; always

LC848:
   jsr SHORTBIT

LC84B:
   pla

BITOUT:
   asl
   bne BITOUT_ENTRY
   rts

LONGBIT:
   ldx #$50
   jsr CARRIER
   ldy #$28
   bne TDELAY                   ; always

SHORTBIT:
   ldx #$18
   jsr CARRIER
   ldy #$44

TDELAY:
   ldx #$13

TDELAY_INNER:
   dex
   bne TDELAY_INNER
   dey
   bne TDELAY
   rts

; ============================================================================
; $CB69  CARRIER: Generate X ultrasonic carrier cycles
; BSR/X-10 ultrasonic RTC_TRANSDUCER is connected to control register bit 5
; Does not affect the uPD1990AC since STB (bit 2) is low
; ============================================================================
CARRIER:
   ldy SLOT16                   ; Y = $n0

CARRIER_LOOP:
   lda #RTC_TRANSDUCER
   sta RTC_CONTROL,y            ; carrier high
   nop
   nop
   nop
   eor #RTC_TRANSDUCER
   sta RTC_CONTROL,y            ; carrier low
   nop
   nop
   nop
   eor #RTC_TRANSDUCER
   sta RTC_CONTROL,y            ; carrier high
   nop
   nop
   nop
   eor #RTC_TRANSDUCER
   sta RTC_CONTROL,y            ; carrier low
   dex
   bne CARRIER_LOOP
   rts

; ============================================================================
; $CB8D  BSR_TABLE -- BSR/X-10 COMMAND BYTE TABLE
;
;   22 entries corresponding to BSR command characters A-V
; ============================================================================

BSR_TABLE:
   .byte $64                    ; A  button  1
   .byte $E4                    ; B  button  2
   .byte $24                    ; C  button  3
   .byte $A4                    ; D  button  4
   .byte $14                    ; E  button  5
   .byte $94                    ; F  button  6
   .byte $54                    ; G  button  7
   .byte $D4                    ; H  button  8
   .byte $74                    ; I  button  9
   .byte $F4                    ; J  button 10
   .byte $34                    ; K  button 11
   .byte $B4                    ; L  button 12
   .byte $04                    ; M  button 13
   .byte $84                    ; N  button 14
   .byte $44                    ; O  button 15
   .byte $C4                    ; P  button 16
   .byte $2C                    ; Q  ON
   .byte $3C                    ; R  OFF
   .byte $5C                    ; S  BRIGHT
   .byte $4C                    ; T  DIM
   .byte $1C                    ; U  ALL LIGHTS ON
   .byte $0C                    ; V  ALL OFF

; ============================================================================
; $CBA3  DAY_TABLE -- Day of week abbreviations, 4 bytes each
; ============================================================================

DAY_TABLE:
   .byte "SUN "                 ; day-of-week=0
   .byte "MON "                 ; day-of-week=1
   .byte "TUE "                 ; day-of-week=2
   .byte "WED "                 ; day-of-week=3
   .byte "THU "                 ; day-of-week=4
   .byte "FRI "                 ; day-of-week=5
   .byte "SAT "                 ; day-of-week=6
   .byte "ERR "                 ; day-of-week=7  (error / invalid)

; ============================================================================
; $CBC3  MONTH_TABLE -- Month abbreviations, 4 bytes each
; ============================================================================

MONTH_TABLE:
   .byte "JAN "
   .byte "FEB "
   .byte "MAR "
   .byte "APR "
   .byte "MAY "
   .byte "JUN "
   .byte "JUL "
   .byte "AUG "
   .byte "SEP "
   .byte "OCT "
   .byte "NOV "
   .byte "DEC "

; ============================================================================
; $CBF3  MTN_SUFFIX -- Mountain Clock ".000" suffix
; ============================================================================

MTN_SUFFIX:
   .byte $AE,$B0,$B0,$B0        ; ".000"
   .byte $00                    ; null terminator

   .byte $AE,$B0,$B0,$B0,$00,$A0,$A0,$C1

; ============================================================================
; $CC00-$CFFF  UNPROGRAMMED ROM ($FF fill, 1024 bytes)
;
;   The upper half of the 2KB chip is not used.
; ============================================================================

   .res $0400, $FF              ; $CC00-$CFFF unprogrammed

; ============================================================================
; END OF ThunderClock Plus ROM  ($C800-$CFFF, 2048 bytes)
; ============================================================================
