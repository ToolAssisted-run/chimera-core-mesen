/* gate-harness.h - the shared half of run-native.c and run-wbx.c.
 *
 * One replay-and-digest loop over an abstract core interface, so the native
 * reference and the sandboxed core run exactly the same schedule: the same
 * input file or the same pseudo-random pad exercise, digesting video, audio,
 * lag and every memory domain. The two drivers differ only in how the
 * exports are reached.
 *
 * Wire (waterbox.config button order): 0 Power, 1 Reset, then P1, P2, P3
 * and P4 x {A, B, Select, Start, Up, Down, Left, Right}, 34 P2 Trigger (the
 * Zapper), 35 P2 Fire (the Arkanoid controller), 36 Expansion Trigger, 37
 * Expansion Fire (the same devices on the Famicom's expansion port). Axes:
 * 0 P2 Zapper X, 1 P2 Zapper Y (0..65535), 2 P2 Paddle (0..160), 3
 * Expansion Zapper X, 4 Expansion Zapper Y, 5 Expansion Paddle.
 *
 * Input files are this repository's own: one line per frame,
 *     |Pr|UDLRSsBA|UDLRSsBA|UDLRSsBA|UDLRSsBA|@T F x=N y=N p=N t f X=N Y=N k=N|
 * a '.' for a button not held, the letter for one held (the console field
 * is P = Power, r = Reset). Pad fields are P1 to P4, as many as the line
 * has (at least one). The last field, starting with '@', is optional: T
 * holds the Zapper's trigger, F the Arkanoid controller's button, x= and y=
 * say where the Zapper points and p= where the knob is; t, f, X=, Y= and k=
 * are the same for the expansion port's Zapper and Arkanoid controller. An
 * axis a line does not name rests at its neutral value (32768 for a
 * Zapper's, 80 for a knob).
 */
#ifndef GATE_HARNESS_H
#define GATE_HARNESS_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define GATE_BTN_COUNT (2 + 4 * 8 + 2 + 2)
#define GATE_AXIS_COUNT 6
static const int32_t gate_axis_neutral[GATE_AXIS_COUNT] = { 32768, 32768, 80, 32768, 32768, 80 };

struct gate_core
{
	int (*init)(void);
	const char *(*load_error)(void);
	void (*set_button)(int32_t index, int32_t state);
	/* the axes, each pushed before every frame, as Chimera does */
	void (*set_axis)(int32_t index, int32_t value);
	void (*frame)(void);
	const uint32_t *(*video)(int *w, int *h);
	const int16_t *(*audio)(int *n);
	int (*input_was_read)(void);
	int (*domain_count)(void);
	const char *(*domain_name)(int i);
	const uint8_t *(*domain_ptr)(int i);
	int64_t (*domain_size)(int i);
	int (*vsync_numerator)(void);
	int (*vsync_denominator)(void);
	int32_t (*savedata_count)(void);
	const char *(*savedata_name)(int32_t i);
	int64_t (*savedata_size)(int32_t i);
	const uint8_t *(*savedata_buffer)(int32_t i);
	/* optional per-frame hook (the rerecord leg); may be NULL */
	void (*pre_frame)(void);
	/* optional: turn the core's drawing on and off (the turbo leg); may be NULL */
	void (*set_rendering)(int on);
	/* optional: the whole machine to and from a file (the session leg); NULL
	 * in the native reference, which has no machine outside its process */
	int (*save_state)(const char *path);
	int (*load_state)(const char *path);
	/* the system bus as a tool reads it (the look option) */
	const uint8_t *(*read_bus)(int32_t bus, int64_t addr, int32_t len);
};

struct gate_opts
{
	long frames;          /* run length; an input file may end earlier, padded with idle */
	const char *inputPath; /* NULL = idle, or the pad exercise */
	const char *screenshotPath; /* optional final-frame .tga */
	int exercise;         /* nonzero: drive P1 with a deterministic pattern */
	const char *dumpDomain;     /* optional: memory domain to dump after the run... */
	const char *dumpPath;       /* ...into this file */
	const char *savedataDir;    /* optional: write every savedata export here after the run */
	int turbo;            /* nonzero: draw nothing for the first half of the run */
	long stallFrame;      /* the virtual-time leg: before this frame... */
	long stallMs;         /* ...the host sleeps this long */
	const char *audioPath; /* optional: the whole run's samples, raw s16le stereo */
	long saveAt;          /* the session leg: before this frame (>0)... */
	const char *savePath; /* ...the machine is written here and the run ends */
	const char *loadPath; /* or: the run starts from this machine... */
	long loadAt;          /* ...at this frame of the schedule */
	int look;             /* read the whole system bus after every frame, as a tool would */
	int lookPpu;          /* the same with the PPU bus (bus 1, 16 KiB) */
	int dumpBus;          /* after the run, bus dumpBus (0 or 1)... */
	const char *dumpBusPath; /* ...is written here, whole */
};

static uint64_t gate_fnv(uint64_t h, const void *p, size_t n)
{
	const uint8_t *b = (const uint8_t *)p;
	if (!h) h = 1469598103934665603ULL;
	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
	return h;
}

/* deterministic P1 pad pattern, identical in both drivers, so the input path
 * is part of the comparison; Power and Reset stay untouched. The pad changes
 * every 4 frames, and Start is held only now and then. */
static void gate_exercise_pad(long frame, uint8_t *buttons)
{
	uint64_t x = (uint64_t)(frame / 4) * 6364136223846793005ULL + 1442695040888963407ULL;
	x ^= x >> 33;
	for (int k = 0; k < 8; k++)
		buttons[2 + k] = (x >> k) & 1;
	buttons[2 + 3] = ((x >> 13) & 7) == 0; /* Start */
	buttons[2 + 2] = 0;                    /* Select */
	/* no pad holds Up+Down or Left+Right */
	if (buttons[2 + 4] && buttons[2 + 5]) buttons[2 + 5] = 0;
	if (buttons[2 + 6] && buttons[2 + 7]) buttons[2 + 7] = 0;
}

struct gate_inputs
{
	char **lines;
	long count;
};

static int gate_inputs_load(const char *path, struct gate_inputs *in)
{
	FILE *f = fopen(path, "rb");
	if (!f) return 0;
	in->lines = NULL;
	in->count = 0;
	long cap = 0;
	char line[256];
	while (fgets(line, sizeof line, f))
	{
		size_t n = strlen(line);
		while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
		if (n == 0) continue;
		if (in->count == cap)
		{
			cap = cap ? cap * 2 : 1024;
			in->lines = (char **)realloc(in->lines, (size_t)cap * sizeof(char *));
		}
		in->lines[in->count++] = strdup(line);
	}
	fclose(f);
	return 1;
}

/* one pad field (8 columns, U D L R S s B A) -> the wire's pad at base,
 * whose order is A B Select Start Up Down Left Right */
static int gate_parse_pad(const char *s, uint8_t *buttons, int base)
{
	static const char cols[8] = { 'U', 'D', 'L', 'R', 'S', 's', 'B', 'A' };
	static const int wire[8] = { 4, 5, 6, 7, 3, 2, 1, 0 };
	for (int i = 0; i < 8; i++)
	{
		if (s[i] != '.' && s[i] != cols[i])
			return 0;
		buttons[base + wire[i]] = s[i] != '.';
	}
	return 1;
}

/* the '@' field: T, F, x=N, y=N, p=N, t, f, X=N, Y=N, k=N separated by
 * spaces, up to the '|' */
static int gate_parse_extra(const char *s, uint8_t *buttons, int32_t *axes)
{
	s++; /* '@' */
	while (*s && *s != '|')
	{
		if (*s == ' ') { s++; continue; }
		if (*s == 'T') { buttons[34] = 1; s++; continue; }
		if (*s == 'F') { buttons[35] = 1; s++; continue; }
		if (*s == 't') { buttons[36] = 1; s++; continue; }
		if (*s == 'f') { buttons[37] = 1; s++; continue; }
		int axis = *s == 'x' ? 0 : *s == 'y' ? 1 : *s == 'p' ? 2 : *s == 'X' ? 3 : *s == 'Y' ? 4 : *s == 'k' ? 5 : -1;
		if (axis < 0 || s[1] != '=') return 0;
		char *end;
		long v = strtol(s + 2, &end, 10);
		if (end == s + 2) return 0;
		axes[axis] = (int32_t)v;
		s = end;
	}
	return *s == '|' && s[1] == 0;
}

static int gate_parse_line(const char *line, uint8_t *buttons, int32_t *axes)
{
	memset(buttons, 0, GATE_BTN_COUNT);
	for (int i = 0; i < GATE_AXIS_COUNT; i++)
		axes[i] = gate_axis_neutral[i];
	const char *s = line;
	if (*s++ != '|') return 0;
	if (*s != '.' && *s != 'P') return 0;
	buttons[0] = *s++ == 'P';
	if (*s != '.' && *s != 'r') return 0;
	buttons[1] = *s++ == 'r';
	int pads = 0;
	for (;;)
	{
		if (*s++ != '|') return 0;
		if (*s == 0) return pads > 0;
		if (*s == '@') return pads > 0 && gate_parse_extra(s, buttons, axes);
		if (pads == 4 || !gate_parse_pad(s, buttons, 2 + pads * 8)) return 0;
		pads++;
		s += 8;
	}
}

static int gate_write_tga(const char *path, const uint32_t *bgra, int w, int h)
{
	FILE *f = fopen(path, "wb");
	if (!f) return 0;
	uint8_t hdr[18] = { 0 };
	hdr[2] = 2;
	hdr[12] = w & 0xff; hdr[13] = (w >> 8) & 0xff;
	hdr[14] = h & 0xff; hdr[15] = (h >> 8) & 0xff;
	hdr[16] = 32;
	hdr[17] = 0x20;
	fwrite(hdr, 1, 18, f);
	fwrite(bgra, 4, (size_t)w * h, f);
	fclose(f);
	return 1;
}

/* the loop both drivers share; prints the digest block to stdout */
static int gate_run(const struct gate_core *c, const struct gate_opts *o)
{
	struct gate_inputs in = { NULL, 0 };
	if (o->inputPath && !gate_inputs_load(o->inputPath, &in))
	{
		fprintf(stderr, "cannot read input file %s\n", o->inputPath);
		return 1;
	}

	if (c->init() != 1)
	{
		fprintf(stderr, "Init failed: %s\n", c->load_error ? c->load_error() : "?");
		return 1;
	}

	FILE *audioOut = NULL;
	if (o->audioPath && !(audioOut = fopen(o->audioPath, "wb")))
	{
		perror(o->audioPath);
		return 1;
	}

	long frames = o->frames;
	if (in.count > 0 && frames < in.count)
		frames = in.count;

	uint64_t vh = 0, ah = 0, th = 0;
	long samples = 0;
	const long tail = frames / 2;
	long lag = 0;

	uint8_t buttons[GATE_BTN_COUNT];
	uint8_t prev[GATE_BTN_COUNT];
	int32_t axes[GATE_AXIS_COUNT];
	memset(prev, 0, sizeof prev);
	if (o->loadPath)
	{
		if (!c->load_state || !c->load_state(o->loadPath))
		{
			fprintf(stderr, "cannot load the machine from %s\n", o->loadPath);
			return 1;
		}
		/* what the frontend would have pressed before the save is pressed now */
		if (o->loadAt > 0 && o->loadAt - 1 < in.count)
			gate_parse_line(in.lines[o->loadAt - 1], prev, axes);
		else if (o->loadAt > 0 && o->exercise)
			gate_exercise_pad(o->loadAt - 1, prev);
	}
	uint64_t lastFrame = 0;
	uint64_t busHash = 0, ppuBusHash = 0;
	int busIsRam = 1;

	for (long f = o->loadPath ? o->loadAt : 0; f < frames; f++)
	{
		if (o->savePath && f == o->saveAt)
		{
			if (!c->save_state || !c->save_state(o->savePath))
			{
				fprintf(stderr, "cannot save the machine to %s\n", o->savePath);
				return 1;
			}
			printf("savedAt=%ld\n", f);
			return 0;
		}
		memset(buttons, 0, sizeof buttons);
		for (int i = 0; i < GATE_AXIS_COUNT; i++)
			axes[i] = gate_axis_neutral[i];
		if (f < in.count)
		{
			if (!gate_parse_line(in.lines[f], buttons, axes))
			{
				fprintf(stderr, "bad input line %ld: '%s'\n", f, in.lines[f]);
				return 1;
			}
		}
		else if (o->exercise)
			gate_exercise_pad(f, buttons);

		if (o->turbo && c->set_rendering)
			c->set_rendering(f >= tail);

		if (o->stallMs > 0 && f == o->stallFrame)
		{
			/* the host stops for a while; a machine on virtual time does not notice */
			struct timespec ts = { o->stallMs / 1000, (o->stallMs % 1000) * 1000000L };
			nanosleep(&ts, NULL);
		}

		if (c->pre_frame)
			c->pre_frame();

		for (int i = 0; i < GATE_BTN_COUNT; i++)
		{
			if (buttons[i] != prev[i])
				c->set_button(i, buttons[i]);
			prev[i] = buttons[i];
		}
		if (c->set_axis)
			for (int i = 0; i < GATE_AXIS_COUNT; i++)
				c->set_axis(i, axes[i]);

		c->frame();

		int w = 0, h = 0, n = 0;
		const uint32_t *video = c->video(&w, &h);
		const int16_t *audio = c->audio(&n);
		vh = gate_fnv(vh, &w, sizeof w);
		vh = gate_fnv(vh, &h, sizeof h);
		vh = gate_fnv(vh, video, (size_t)w * h * 4);
		if (f >= tail)
		{
			th = gate_fnv(th, &w, sizeof w);
			th = gate_fnv(th, &h, sizeof h);
			th = gate_fnv(th, video, (size_t)w * h * 4);
		}
		lastFrame = gate_fnv(0, &w, sizeof w);
		lastFrame = gate_fnv(lastFrame, &h, sizeof h);
		lastFrame = gate_fnv(lastFrame, video, (size_t)w * h * 4);
		ah = gate_fnv(ah, audio, (size_t)n * 2 * sizeof(int16_t));
		samples += n;
		if (audioOut)
			fwrite(audio, sizeof(int16_t) * 2, (size_t)n, audioOut);
		if (!c->input_was_read())
			lag++;

		if (o->look && c->read_bus)
		{
			const uint8_t *bus = c->read_bus(0, 0, 0x10000);
			busHash = gate_fnv(busHash, bus, 0x10000);
			/* $0000-$07FF of the bus is the console's 2 KiB of RAM */
			for (int i = 0; i < c->domain_count(); i++)
				if (!strcmp(c->domain_name(i), "RAM") && memcmp(bus, c->domain_ptr(i), 0x800) != 0)
					busIsRam = 0;
		}

		if (o->lookPpu && c->read_bus)
			ppuBusHash = gate_fnv(ppuBusHash, c->read_bus(1, 0, 0x4000), 0x4000);

		if (o->screenshotPath && f == frames - 1)
			gate_write_tga(o->screenshotPath, video, w, h);
	}
	if (audioOut)
		fclose(audioOut);

	printf("frames=%ld\n", frames);
	printf("vsync=%d/%d\n", c->vsync_numerator(), c->vsync_denominator());
	printf("videoHash=%016llx\n", (unsigned long long)vh);
	printf("tailVideoHash=%016llx\n", (unsigned long long)th);
	printf("audioHash=%016llx\n", (unsigned long long)ah);
	printf("lastFrameHash=%016llx\n", (unsigned long long)lastFrame);
	printf("audioSamples=%ld\n", samples);
	printf("lagFrames=%ld\n", lag);
	if (o->look)
		printf("busHash=%016llx\nbusIsRam=%d\n", (unsigned long long)busHash, busIsRam);
	if (o->lookPpu)
		printf("ppuBusHash=%016llx\n", (unsigned long long)ppuBusHash);
	if (o->dumpBusPath && c->read_bus)
	{
		int32_t size = o->dumpBus == 0 ? 0x10000 : 0x4000;
		FILE *bf = fopen(o->dumpBusPath, "wb");
		if (!bf) { perror(o->dumpBusPath); return 1; }
		fwrite(c->read_bus(o->dumpBus, 0, size), 1, (size_t)size, bf);
		fclose(bf);
	}
	int nd = c->domain_count();
	for (int i = 0; i < nd; i++)
	{
		uint64_t dh = gate_fnv(0, c->domain_ptr(i), (size_t)c->domain_size(i));
		printf("domain[%s]=%016llx\n", c->domain_name(i), (unsigned long long)dh);
	}
	if (o->savedataDir)
	{
		int32_t count = c->savedata_count();
		printf("savedataFiles=%d\n", count);
		for (int32_t i = 0; i < count; i++)
		{
			char path[4096];
			snprintf(path, sizeof path, "%s/%s", o->savedataDir, c->savedata_name(i));
			FILE *f = fopen(path, "wb");
			if (!f) { perror(path); return 1; }
			fwrite(c->savedata_buffer(i), 1, (size_t)c->savedata_size(i), f);
			fclose(f);
		}
	}

	if (o->dumpDomain && o->dumpPath)
	{
		int found = 0;
		for (int i = 0; i < nd; i++)
		{
			if (strcmp(c->domain_name(i), o->dumpDomain) != 0)
				continue;
			FILE *f = fopen(o->dumpPath, "wb");
			if (!f) { perror(o->dumpPath); return 1; }
			fwrite(c->domain_ptr(i), 1, (size_t)c->domain_size(i), f);
			fclose(f);
			found = 1;
			break;
		}
		if (!found)
		{
			fprintf(stderr, "no such domain to dump: %s\n", o->dumpDomain);
			return 1;
		}
	}
	return 0;
}

static int gate_parse_opts(int argc, char **argv, int first, struct gate_opts *o)
{
	memset(o, 0, sizeof *o);
	o->frames = 600;
	for (int i = first; i < argc; i++)
	{
		if (!strcmp(argv[i], "--frames") && i + 1 < argc) o->frames = strtol(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--inputs") && i + 1 < argc) o->inputPath = argv[++i];
		else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) o->screenshotPath = argv[++i];
		else if (!strcmp(argv[i], "--exercise")) o->exercise = 1;
		else if (!strcmp(argv[i], "--dump-domain") && i + 2 < argc) { o->dumpDomain = argv[++i]; o->dumpPath = argv[++i]; }
		else if (!strcmp(argv[i], "--savedata-out") && i + 1 < argc) o->savedataDir = argv[++i];
		else if (!strcmp(argv[i], "--turbo")) o->turbo = 1;
		else if (!strcmp(argv[i], "--stall") && i + 2 < argc) { o->stallFrame = strtol(argv[++i], 0, 0); o->stallMs = strtol(argv[++i], 0, 0); }
		else if (!strcmp(argv[i], "--audio-out") && i + 1 < argc) o->audioPath = argv[++i];
		else if (!strcmp(argv[i], "--save-at") && i + 2 < argc) { o->saveAt = strtol(argv[++i], 0, 0); o->savePath = argv[++i]; }
		else if (!strcmp(argv[i], "--load-at") && i + 2 < argc) { o->loadAt = strtol(argv[++i], 0, 0); o->loadPath = argv[++i]; }
		else if (!strcmp(argv[i], "--look")) o->look = 1;
		else if (!strcmp(argv[i], "--look-ppu")) o->lookPpu = 1;
		else if (!strcmp(argv[i], "--dump-bus") && i + 2 < argc) { o->dumpBus = (int)strtol(argv[++i], 0, 0); o->dumpBusPath = argv[++i]; }
		else if (!strcmp(argv[i], "--rerecord")) ; /* run-wbx's; ignored here */
		else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 0; }
	}
	return 1;
}

#endif /* GATE_HARNESS_H */
