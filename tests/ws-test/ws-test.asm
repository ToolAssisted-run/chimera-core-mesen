; ws-test.asm - the WonderSwan test cartridge this repository uses: a small
; V30MZ program (the WonderSwan's CPU, an 8086 of NEC's) that keeps what it
; reads from the buttons in its RAM, and shows and sounds them.
;
; Built by make-ws-test.py with nasm; the 64 KiB cartridge is the code at
; its start and the header the console reads in its last 16 bytes.
;
; What the program does:
;   - at power on it turns every layer off (the picture is the background
;     colour only), copies a square wave into the sound chip's wave memory
;     and turns sound channel 1 on at full volume;
;   - each frame it waits for line 144 (the start of the vertical blank),
;     reads the three groups of buttons (port $B5: the Y group, the X group,
;     then Start, A and B), and keeps them in RAM at $0100 (Y1-Y4 on bits
;     0-3), $0101 (X1-X4) and $0102 (Start on bit 1, A on bit 2, B on bit
;     3), 1 for held; it counts frames at $0103, and keeps port $62 at
;     $0104 (on a colour console, bit 7 is set on the SwanCrystal);
;   - the background's shade is the X group's bits and the Y group's, and
;     channel 1 plays at a frequency they give.
; The program starts 16 bytes into the cartridge, where the Pocket Challenge
; V2 starts (4000:0010; the WonderSwans start at the jump at the end), so
; the same file is that machine's test too. On the Pocket Challenge V2 the
; three groups hold its own buttons (Mesen's WsControlManager): Clear,
; Circle and Pass on bits 0, 2 and 3 of the first; View, Esc and Right of
; the second; Left, Down and Up of the third; bit 1 always set.
;
; This is our own program, written for this repository's tests; it is under
; the repository's licence.

bits 16
org 0

	times 0x10 db 0x90       ; the Pocket Challenge V2 starts at offset $10
start:
	cli
	xor ax, ax
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov sp, 0x2000
	mov di, 0x0100
	mov cx, 8
	cld
	rep stosb                ; the RAM the program uses, cleared
	xor al, al
	out 0x00, al             ; no layer: the background colour only
	out 0x01, al             ; background colour: palette 0's colour 0
	out 0x20, al             ; palette 0: every colour shade entry 0
	out 0x21, al
	mov di, 0x0E00           ; the wave memory, at $0E00 (port $8F = $38)
	mov cx, 8
	mov al, 0xFF
	rep stosb
	mov cx, 8
	xor al, al
	rep stosb
	mov al, 0x38
	out 0x8F, al
	mov al, 0xFF
	out 0x88, al             ; channel 1 at full volume, both sides
	mov al, 0x01
	out 0x90, al             ; channel 1 on
	mov al, 0x0F
	out 0x91, al             ; the sound out
main:
	in al, 0x02
	cmp al, 144
	jne main                 ; wait for line 144
	mov al, 0x10
	out 0xB5, al
	nop
	nop
	in al, 0xB5
	and al, 0x0F
	mov [0x0100], al         ; Y1-Y4
	mov al, 0x20
	out 0xB5, al
	nop
	nop
	in al, 0xB5
	and al, 0x0F
	mov [0x0101], al         ; X1-X4
	mov al, 0x40
	out 0xB5, al
	nop
	nop
	in al, 0xB5
	and al, 0x0F
	mov [0x0102], al         ; Start, A, B
	inc byte [0x0103]
	in al, 0x62
	mov [0x0104], al         ; the console's model (SwanCrystal: bit 7)
	mov al, [0x0100]
	shl al, 4
	or al, [0x0101]
	out 0x1C, al             ; the shades of colours 0 and 1
	out 0x80, al             ; channel 1's frequency, low byte
	mov al, 0x07
	out 0x81, al             ; and high bits
leave:
	in al, 0x02
	cmp al, 144
	je leave                 ; wait for the line to change
	jmp main

	times 0xFFF0 - ($ - $$) db 0xFF
	; the cartridge's last 16 bytes: the jump the console starts at, then
	; the header (no colour, no saved game, no clock)
	jmp 0xF000:start
	db 0x00                  ; maintenance
	db 0x00                  ; developer
	db 0x00                  ; system: WonderSwan (bit 0 would be colour)
	db 0x00                  ; game
	db 0x00                  ; version
	db 0x00                  ; ROM size
	db 0x00                  ; save type: none
	db 0x04                  ; flags
	db 0x00                  ; no clock
	dw 0x0000                ; checksum (written by make-ws-test.py)
