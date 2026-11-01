@ gba-test.s - this repository's own Game Boy Advance test program.
@
@ It runs from the cartridge without the console's BIOS: it calls no BIOS
@ function and turns no interrupt on, so it needs Mesen's "skip the boot
@ screen" start (the CPU starts at the cartridge, in system mode, as the
@ BIOS would leave it). Its header carries no Nintendo logo.
@
@ What it does, once a frame (it waits for line 160, the start of the
@ vertical blank, by reading VCOUNT):
@   - reads the buttons (KEYINPUT, 0x04000130) and keeps them, held = 1, at
@     EWRAM 0x02000000 (16 bits: A B Select Start Right Left Up Down R L
@     from bit 0); the frame before's at +2;
@   - counts frames at +4 (32 bits);
@   - shows the buttons as the backdrop colour (palette 0) and sounds
@     channel 1 at a frequency they give, restarted when they change;
@   - writes the buttons and the frame count into the cartridge's SRAM
@     (0x0E000000: the buttons' two bytes, then the count's low byte);
@   - reads the cartridge's clock (an S-3511A behind the GPIO pins at
@     0x080000C4) with its "date and time" command and keeps the seven
@     bytes (year, month, day, day of week, hour, minute, second, BCD) at
@     +0x10.
@ At power on it keeps the CPU's status register (CPSR) at +8: 0x1F, system
@ mode, when the boot screen was skipped.
@
@ The strings SRAM_V113 and SIIRTC_V001 at the end tell Mesen that the
@ cartridge has SRAM and the clock.
@
@ This is our own program, written for this repository's tests; it is under
@ the repository's licence. Assembled with LLVM's assembler
@ (make-gba-test.py).

	.syntax unified
	.arm
	.section .text
	.global _start
_start:
	b	start
	.space	0x9C, 0		@ 0x04: the logo, left empty (the BIOS is not run)
	.ascii	"CHIMERA TEST"	@ 0xA0: title
	.ascii	"CMTE"		@ 0xAC: game code
	.ascii	"00"		@ 0xB0: maker
	.byte	0x96		@ 0xB2: fixed value
	.byte	0, 0		@ 0xB3: unit, device
	.space	7, 0		@ 0xB5: reserved
	.byte	0		@ 0xBC: version
	.byte	0		@ 0xBD: header checksum (make-gba-test.py)
	.space	2, 0		@ 0xBE: reserved
	@ 0xC0-0xFF: nothing, so that no instruction is fetched where the
	@ clock's GPIO pins answer once they are made readable
	.space	0x40, 0

start:					@ 0x100
	ldr	r1, =0x02000000		@ our RAM
	mrs	r0, cpsr
	str	r0, [r1, #8]
	ldr	r0, =0xFFFF
	strh	r0, [r1, #2]		@ no buttons "before": the first frame sounds
	mov	r2, #0x04000000		@ the I/O registers
	mov	r0, #0
	strh	r0, [r2]		@ DISPCNT: mode 0, no layer: the backdrop only
	mov	r0, #0x80
	strh	r0, [r2, #0x84]		@ SOUNDCNT_X: sound on
	ldr	r0, =0x1177
	strh	r0, [r2, #0x80]		@ SOUNDCNT_L: channel 1 to both sides, full volume
	mov	r0, #2
	strh	r0, [r2, #0x82]		@ SOUNDCNT_H: the PSG channels at 100%
	ldr	r0, =0xF080
	strh	r0, [r2, #0x62]		@ SOUND1CNT_H: volume 15, duty 50%
	ldr	r3, =0x080000C4		@ the GPIO pins: data, +2 direction, +4 control
	mov	r0, #1
	strh	r0, [r3, #4]		@ the pins readable

frame:
leave:	ldrh	r0, [r2, #6]		@ VCOUNT
	cmp	r0, #160
	beq	leave
reach:	ldrh	r0, [r2, #6]
	cmp	r0, #160
	bne	reach

	add	r0, r2, #0x100
	ldrh	r0, [r0, #0x30]		@ KEYINPUT, 0 = held
	ldr	r4, =0x3FF
	eor	r0, r0, r4
	and	r0, r0, r4
	strh	r0, [r1]
	ldr	r5, [r1, #4]
	add	r5, r5, #1
	str	r5, [r1, #4]

	mov	r6, #0x05000000
	strh	r0, [r6]		@ the backdrop colour

	mov	r6, #0x0E000000		@ SRAM, a byte at a time
	strb	r0, [r6]
	mov	r7, r0, lsr #8
	strb	r7, [r6, #1]
	strb	r5, [r6, #2]

	ldrh	r7, [r1, #2]
	strh	r0, [r1, #2]
	cmp	r7, r0
	beq	quiet
	add	r7, r0, #0x400		@ the frequency
	orr	r7, r7, #0x8000		@ restart
	strh	r7, [r2, #0x64]		@ SOUND1CNT_X
quiet:
	bl	clock
	b	frame

@ the clock's "date and time": the command 0x65 sent highest bit first
@ (a bit is put on SIO with SCK low and taken on SCK's rise), then 56 bits
@ read lowest first (the chip puts a bit out on SCK's fall)
clock:
	mov	r0, #7
	strh	r0, [r3, #2]		@ SCK, SIO and CS out
	mov	r0, #1
	strh	r0, [r3]		@ CS low, SCK high
	mov	r0, #5
	strh	r0, [r3]		@ CS high
	mov	r8, #0x65
	mov	r9, #7
command:
	mov	r0, r8, lsr r9
	and	r0, r0, #1
	mov	r0, r0, lsl #1
	orr	r0, r0, #4		@ CS high, SCK low, the bit on SIO
	strh	r0, [r3]
	orr	r0, r0, #1		@ SCK high
	strh	r0, [r3]
	subs	r9, r9, #1
	bpl	command
	mov	r0, #5
	strh	r0, [r3, #2]		@ SIO in
	add	r10, r1, #0x10
	mov	r11, #0
	mov	r12, #0
bits:
	mov	r0, #4
	strh	r0, [r3]		@ SCK low: the chip's next bit
	ldrh	r0, [r3]
	mov	r0, r0, lsr #1
	and	r0, r0, #1
	and	r7, r11, #7
	orr	r12, r12, r0, lsl r7
	mov	r0, #5
	strh	r0, [r3]		@ SCK high
	add	r11, r11, #1
	tst	r11, #7
	strbeq	r12, [r10], #1
	moveq	r12, #0
	cmp	r11, #56
	bne	bits
	mov	r0, #1
	strh	r0, [r3]		@ CS low: done
	bx	lr

	.ltorg
	.align	4
	.ascii	"SRAM_V113"
	.align	4
	.ascii	"SIIRTC_V001"
	.align	4
