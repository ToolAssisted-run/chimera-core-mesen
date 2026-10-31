/* snes-coprocessor.inc - which program ROM a Super NES cartridge's chip
 * needs, read from the cartridge's header the way Mesen reads it
 * (SNES/BaseCartridge.cpp: GetHeaderScore, GetCoprocessorType,
 * GetDspVersion, GetSt01xVersion), for SuggestSettings' "firmware" answer.
 *
 * The DSP-1, DSP-1B, DSP-2, DSP-3, DSP-4, ST010 and ST011 are NEC uPD7725
 * and uPD96050 chips, and the ST018 an ARM: each runs a program of its own
 * that is not in the game's file. Mesen reads it from a file named after
 * the chip, which Chimera mounts under that name. The Cx4, the SA-1, the
 * Super FX, the S-DD1, the SPC7110 and the OBC1 need none. */

struct SnesChipFirmware
{
	const char *id;      /* the file Mesen reads */
	const char *display; /* the language tables' key */
	int size;
	const char *sha1;
};
static const SnesChipFirmware kSnesChips[] = {
	{ "dsp1.rom", "firmware.dsp1", 8192, "188D471FEFEA71EB53F0EE7064697FF0971B1014" },
	{ "dsp1b.rom", "firmware.dsp1b", 8192, "78B724811F5F18D8C67669D9390397EB1A47A5E2" },
	{ "dsp2.rom", "firmware.dsp2", 8192, "198C4B1C3BFC6D69E734C5957AF3DBFA26238DFB" },
	{ "dsp3.rom", "firmware.dsp3", 8192, "558DA7CB3BD3876A6CA693661FFC6C110E948CF9" },
	{ "dsp4.rom", "firmware.dsp4", 8192, "AF6478AECB6F1B67177E79C82CA04C56250A8C72" },
	{ "st010.rom", "firmware.st010", 53248, "6472828403DE3589433A906E2C3F3D274C0FF008" },
	{ "st011.rom", "firmware.st011", 53248, "FECBAE2CEC76C710422486BAA186FFA7CA1CF925" },
	{ "st018.rom", "firmware.st018", 163840, "91383B92745CC7CC4F15409AC5BC2C2F699A43F1" },
};
enum { CHIP_DSP1, CHIP_DSP1B, CHIP_DSP2, CHIP_DSP3, CHIP_DSP4, CHIP_ST010, CHIP_ST011, CHIP_ST018 };

/* Mesen's score for a header at addr (BaseCartridge::GetHeaderScore) */
static int snes_header_score(const uint8_t *rom, size_t size, uint32_t addr)
{
	if (size < (size_t)addr + 0x7FFF + 1)
		return -1;
	const uint8_t *h = rom + addr + 0x7FB0;
	int score = 0;
	uint8_t mode = h[0x25] & ~0x10;
	if ((mode == 0x20 || mode == 0x22) && (addr & ~0x400000u) < 0x8000)
		score++;
	else if ((mode == 0x21 || mode == 0x25) && (addr & ~0x400000u) >= 0x8000)
		score++;
	if (h[0x26] < 0x08)
		score++;
	if (h[0x27] < 0x10)
		score++;
	if (h[0x28] < 0x08)
		score++;
	unsigned complement = h[0x2C] | (h[0x2D] << 8);
	unsigned checksum = h[0x2E] | (h[0x2F] << 8);
	if (checksum + complement == 0xFFFF && checksum != 0 && complement != 0)
		score += 8;
	unsigned reset = rom[addr + 0x7FFC] | (rom[addr + 0x7FFD] << 8);
	if (reset < 0x8000)
		return -1;
	uint8_t op = rom[addr + (reset & 0x7FFF)];
	if (op == 0x18 || op == 0x78 || op == 0x4C || op == 0x5C || op == 0x20 || op == 0x22 || op == 0x9C)
		score += 8;
	else if (op == 0xC2 || op == 0xE2 || op == 0xA9 || op == 0xA2 || op == 0xA0)
		score += 4;
	else if (op == 0x00 || op == 0xFF || op == 0xCC)
		score -= 8;
	return score < 0 ? 0 : score;
}

/* the chip whose program this cartridge needs, or -1 */
static int snes_chip(const uint8_t *rom, size_t size)
{
	static const uint32_t bases[] = { 0, 0x200, 0x8000, 0x8200, 0x400000, 0x400200, 0x408000, 0x408200 };
	int best = -1;
	const uint8_t *h = NULL;
	for (size_t i = 0; i < sizeof bases / sizeof bases[0]; i++) {
		int score = snes_header_score(rom, size, bases[i]);
		if (score >= 0 && score >= best) {
			best = score;
			h = rom + bases[i] + 0x7FB0;
		}
	}
	if (h == NULL)
		return -1;
	/* the title, without the spaces that pad it (BaseCartridge::GetCartName) */
	char name[22];
	memcpy(name, h + 0x10, 21);
	name[21] = 0;
	for (int i = 20; i >= 0 && (name[i] == ' ' || name[i] == 0); i--)
		name[i] = 0;
	uint8_t romType = h[0x26], cartType = h[0x0F];
	if ((romType & 0x0F) < 0x03)
		return -1;
	switch ((romType & 0xF0) >> 4) {
	case 0x0:
		if (!strcmp(name, "DUNGEON MASTER")) return CHIP_DSP2;
		if (!strcmp(name, "PILOTWINGS")) return CHIP_DSP1;
		if (!strcmp(name, "SD\xB6\xDE\xDD\xC0\xDE\xD1GX")) return CHIP_DSP3;
		if (!strcmp(name, "PLANETS CHAMP TG3000") || !strcmp(name, "TOP GEAR 3000")) return CHIP_DSP4;
		return CHIP_DSP1B;
	case 0xF:
		if (cartType == 0x01) return !strcmp(name, "2DAN MORITA SHOUGI") ? CHIP_ST011 : CHIP_ST010;
		if (cartType == 0x02) return CHIP_ST018;
		return -1;
	default:
		return -1;
	}
}

/* The "firmware" array for SuggestSettings, or NULL when the cartridge's
 * chip needs no program (a Satellaview file is not a cartridge) */
static const char *snes_coprocessor_firmware(const uint8_t *rom, size_t size, int isBsx)
{
	static char json[512];
	if (isBsx || size < 0x8000)
		return NULL;
	int chip = snes_chip(rom, size);
	if (chip < 0)
		return NULL;
	const SnesChipFirmware &c = kSnesChips[chip];
	snprintf(json, sizeof json,
		"{\"id\": \"%s\", \"display\": \"%s\", \"description\": \"firmware.snes_chip.about\", \"name\": \"%s\", "
		"\"size\": %d, \"sha1\": \"%s\", \"nameHints\": [\"%.*s\"]}",
		c.id, c.display, c.id, c.size, c.sha1, (int)(strchr(c.id, '.') - c.id), c.id);
	return json;
}
