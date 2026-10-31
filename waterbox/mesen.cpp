/* mesen.cpp - Mesen (MesenCE) behind Chimera's guest ABI, as an NES.
 *
 * Mesen's Emulator object is the glue between its consoles and its
 * frontend: settings, the sound mixer, the video decoder, the input
 * providers. This file builds one Emulator, gives it a Chimera input
 * provider, a sound device that keeps the frame's samples and a rendering
 * device that keeps the frame's picture, and steps it one frame per
 * FrameAdvance on the caller's thread (patch 0001: no emulation thread, no
 * decode or render thread, no frame limiter).
 *
 * The same file is compiled into the guest (miniBox emulibc) and into the
 * native reference (native-shim/emulibc.h). That is what makes the
 * equivalence gate a proof.
 */
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <map>
#include <string>
#include <vector>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "pch.h"
#include "Shared/Emulator.h"
#include "Shared/EmuSettings.h"
#include "Shared/SettingTypes.h"
#include "Shared/MemoryType.h"
#include "Shared/MessageManager.h"
#include "Shared/BatteryManager.h"
#include "Shared/BaseControlDevice.h"
#include "Shared/BaseControlManager.h"
#include "Shared/RenderedFrame.h"
#include "Shared/Audio/SoundMixer.h"
#include "Shared/Video/VideoDecoder.h"
#include "Shared/Video/VideoRenderer.h"
#include "Shared/Interfaces/IAudioDevice.h"
#include "Shared/Interfaces/IRenderingDevice.h"
#include "Shared/Interfaces/IInputProvider.h"
#include "Shared/Interfaces/IConsole.h"
#include "NES/NesConsole.h"
#include "NES/NesMemoryManager.h"
#include "NES/GameDatabase.h"
#include "NES/Input/NesController.h"
#include "NES/BaseMapper.h"
#include "NES/Mappers/FDS/Fds.h"
#include "Shared/IControllerHub.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/RandomHelper.h"
#include "Utilities/VirtualFile.h"

/* A text a person reads is a key of languages/en.json, each of its
 * arguments after a TEXT_ARG (chimera docs/translations.md). */
#define TEXT_ARG "\x1f"

/* the game database Mesen's UI ships beside the program, compiled in
 * (mesen-nes-db.cpp is generated from UI/Dependencies/MesenNesDB.txt) */
extern "C" const char mesen_nes_db[];
extern "C" const size_t mesen_nes_db_size;

/* ---- the wire: waterbox.config "input.buttons" order ----
 * 0 Power, 1 Reset, then P1, P2, P3 and P4 x {A, B, Select, Start, Up,
 * Down, Left, Right} (quickerNES's order; P3 and P4 through the Four
 * Score or the four-player adapter), then 34 P2 Trigger (the Zapper's) and
 * 35 P2 Fire (the Arkanoid controller's), then 36 Expansion Trigger and 37
 * Expansion Fire (the same two devices made for the Famicom's expansion
 * port), then 38 Previous Disk, 39 Next Disk and 40 Eject Disk (the Famicom
 * Disk System's drive: a selector over the disk's sides, and the disk out
 * of the drive while Eject is held). The declaration is the union of every device the ports can hold;
 * IsButtonActive says which of them this machine has. The order only
 * grows, so a movie made before keeps its columns.
 *
 * Axes ("input.axes", SetAxis): 0 P2 Zapper X and 1 P2 Zapper Y (where the
 * Zapper points, 0..65535 across the picture's width and height), 2 P2
 * Paddle (the Arkanoid controller's knob, 0..160, as quickerNES's), then
 * 3 Expansion Zapper X, 4 Expansion Zapper Y and 5 Expansion Paddle, the
 * same for the expansion port's devices. */
#define BTN_CONSOLE 2
#define BTN_PER_PAD 8
#define BTN_PADS 4
#define BTN_TRIGGER (BTN_CONSOLE + BTN_PADS * BTN_PER_PAD)
#define BTN_FIRE (BTN_TRIGGER + 1)
#define BTN_EXP_TRIGGER (BTN_FIRE + 1)
#define BTN_EXP_FIRE (BTN_EXP_TRIGGER + 1)
#define BTN_PREV_DISK (BTN_EXP_FIRE + 1)
#define BTN_NEXT_DISK (BTN_PREV_DISK + 1)
#define BTN_EJECT_DISK (BTN_NEXT_DISK + 1)
#define BTN_COUNT (BTN_EJECT_DISK + 1)
static uint8_t g_buttons[BTN_COUNT];

#define AXIS_ZAPPER_X 0
#define AXIS_ZAPPER_Y 1
#define AXIS_PADDLE 2
#define AXIS_EXP_ZAPPER_X 3
#define AXIS_EXP_ZAPPER_Y 4
#define AXIS_EXP_PADDLE 5
#define AXIS_COUNT 6
static int32_t g_axes[AXIS_COUNT] = { 32768, 32768, 80, 32768, 32768, 80 };

/* what the ports hold (the settings port1, port2 and expansion) */
enum { PORT1_GAMEPAD, PORT1_NONE, PORT1_FOUR_SCORE };
enum { PORT2_NONE, PORT2_GAMEPAD, PORT2_ZAPPER, PORT2_ARKANOID };
enum { EXP_NONE, EXP_ZAPPER, EXP_ARKANOID, EXP_FOUR_PLAYER, EXP_EPSM };
static int g_port1 = PORT1_GAMEPAD, g_port2 = PORT2_NONE, g_exp = EXP_NONE;

/* wire column -> NesController::Buttons bit */
static const uint8_t kColToBit[BTN_PER_PAD] = {
	NesController::A, NesController::B, NesController::Select, NesController::Start,
	NesController::Up, NesController::Down, NesController::Left, NesController::Right,
};

static char g_loadError[512];
static Emulator *g_emu;
static int g_inputRead;
static int g_epsm;

/* the Famicom Disk System's drive: which side the selector is on, and the
 * disk buttons as they were on the frame before (a press is an edge). Plain
 * guest memory, so a savestate carries them with the machine. */
static int g_fds;
static int g_diskSelected;
static uint8_t g_diskWas[3];

/* the picture of the frame, BGRA; Mesen's decoder writes 0xAARRGGBB words,
 * which are BGRA bytes on a little-endian machine */
#define VIDEO_MAX_W 640
#define VIDEO_MAX_H 480
static uint32_t g_video[VIDEO_MAX_W * VIDEO_MAX_H];
static int g_vwidth = 256, g_vheight = 240;
/* Turbo is the frontend's policy for the moment, not part of the machine */
ECL_INVISIBLE static int g_render = 1;

/* the sound of the frame: 48000 Hz stereo */
#define AUDIO_RATE 48000
#define AUDIO_MAX 8192
static int16_t g_audio[AUDIO_MAX * 2];
static int g_nsamples;

/* Chimera's function to call at each read of the controls (chimera#344).
 * The same callback slot in every session; no savestate carries it. */
ECL_INVISIBLE static uintptr_t (*g_inputPoll)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);

/* patch 0003 calls this at each read of $4016/$4017 */
static void on_input_read()
{
	if (g_inputPoll)
		g_inputPoll(0, 0, 0, 0, 0, 0);
}

/* Mesen's palette by default: the UI's NesConfig.UserPalette default
 * (UI/Config/NesConfig.cs), which the core does not carry itself */
static const uint32_t kDefaultPalette[64] = {
	0xFF666666, 0xFF002A88, 0xFF1412A7, 0xFF3B00A4, 0xFF5C007E, 0xFF6E0040, 0xFF6C0600, 0xFF561D00,
	0xFF333500, 0xFF0B4800, 0xFF005200, 0xFF004F08, 0xFF00404D, 0xFF000000, 0xFF000000, 0xFF000000,
	0xFFADADAD, 0xFF155FD9, 0xFF4240FF, 0xFF7527FE, 0xFFA01ACC, 0xFFB71E7B, 0xFFB53120, 0xFF994E00,
	0xFF6B6D00, 0xFF388700, 0xFF0C9300, 0xFF008F32, 0xFF007C8D, 0xFF000000, 0xFF000000, 0xFF000000,
	0xFFFFFEFF, 0xFF64B0FF, 0xFF9290FF, 0xFFC676FF, 0xFFF36AFF, 0xFFFE6ECC, 0xFFFE8170, 0xFFEA9E22,
	0xFFBCBE00, 0xFF88D800, 0xFF5CE430, 0xFF45E082, 0xFF48CDDE, 0xFF4F4F4F, 0xFF000000, 0xFF000000,
	0xFFFFFEFF, 0xFFC0DFFF, 0xFFD3D2FF, 0xFFE8C8FF, 0xFFFBC2FF, 0xFFFEC4EA, 0xFFFECCC5, 0xFFF7D8A5,
	0xFFE4E594, 0xFFCFEF96, 0xFFBDF4AB, 0xFFB3F3CC, 0xFFB5EBF2, 0xFFB8B8B8, 0xFF000000, 0xFF000000,
};

/* ---- the three devices Mesen talks to ---- */

static void set_pad(BaseControlDevice *device, int player)
{
	const uint8_t *pad = &g_buttons[BTN_CONSOLE + player * BTN_PER_PAD];
	for (int col = 0; col < BTN_PER_PAD; col++)
		device->SetBitValue(kColToBit[col], pad[col] != 0);
}

class ChimeraInput : public IInputProvider
{
public:
	bool SetInput(BaseControlDevice *device) override
	{
		ControllerType t = device->GetControllerType();
		int port = device->GetPort();
		switch (t) {
		case ControllerType::NesController:
		case ControllerType::FamicomController:
		case ControllerType::FamicomControllerP2:
			if (port < 0 || port > 1)
				return false;
			set_pad(device, port);
			return true;
		case ControllerType::FourScore:
		case ControllerType::FourPlayerAdapter: {
			/* the Four Score's sub-ports are the four players: 0 and 2 are
			 * read through $4016, 1 and 3 through $4017. The Famicom's
			 * four-player adapter is the same on the expansion port's data
			 * line (bit 1), with the two signatures the other way round. */
			IControllerHub *hub = dynamic_cast<IControllerHub *>(device);
			if (hub == nullptr)
				return false;
			for (int i = 0; i < hub->GetHubPortCount() && i < BTN_PADS; i++) {
				shared_ptr<BaseControlDevice> pad = hub->GetController(i);
				if (pad)
					set_pad(pad.get(), i);
			}
			hub->RefreshHubState();
			return true;
		}
		case ControllerType::NesZapper:
		case ControllerType::FamicomZapper: {
			/* the Zapper's coordinates are the picture's pixels */
			int exp = t == ControllerType::FamicomZapper;
			MousePosition pos;
			pos.X = (int16_t)((int64_t)g_axes[exp ? AXIS_EXP_ZAPPER_X : AXIS_ZAPPER_X] * 256 / 65536);
			pos.Y = (int16_t)((int64_t)g_axes[exp ? AXIS_EXP_ZAPPER_Y : AXIS_ZAPPER_Y] * 240 / 65536);
			device->SetCoordinates(pos);
			device->SetBitValue(0, g_buttons[exp ? BTN_EXP_TRIGGER : BTN_TRIGGER] != 0); /* Zapper::Fire */
			return true;
		}
		case ControllerType::NesArkanoidController:
		case ControllerType::FamicomArkanoidController: {
			/* the knob's position as an X coordinate (patch 0007) */
			int exp = t == ControllerType::FamicomArkanoidController;
			int32_t v = g_axes[exp ? AXIS_EXP_PADDLE : AXIS_PADDLE];
			MousePosition pos;
			pos.X = (int16_t)(v < 0 ? 0 : v > 160 ? 160 : v);
			pos.Y = 0;
			device->SetCoordinates(pos);
			device->SetBitValue(0, g_buttons[exp ? BTN_EXP_FIRE : BTN_FIRE] != 0); /* ArkanoidController::Fire */
			return true;
		}
		default:
			return false;
		}
	}
};

class ChimeraAudio : public IAudioDevice
{
public:
	void PlayBuffer(int16_t *buf, uint32_t count, uint32_t rate, bool stereo) override
	{
		(void)rate;
		(void)stereo;
		for (uint32_t i = 0; i < count && g_nsamples < AUDIO_MAX; i++) {
			g_audio[g_nsamples * 2] = buf[i * 2];
			g_audio[g_nsamples * 2 + 1] = buf[i * 2 + 1];
			g_nsamples++;
		}
	}
	void Stop() override {}
	void Pause() override {}
	void ProcessEndOfFrame() override {}
	string GetAvailableDevices() override { return ""; }
	void SetAudioDevice(string) override {}
	AudioStatistics GetStatistics() override { return AudioStatistics(); }
};

class ChimeraVideo : public IRenderingDevice
{
public:
	void UpdateFrame(RenderedFrame &frame) override
	{
		int w = (int)frame.Width, h = (int)frame.Height;
		if (w > VIDEO_MAX_W) w = VIDEO_MAX_W;
		if (h > VIDEO_MAX_H) h = VIDEO_MAX_H;
		const uint32_t *src = (const uint32_t *)frame.FrameBuffer;
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
				g_video[y * w + x] = src[y * frame.Width + x] | 0xFF000000u;
		g_vwidth = w;
		g_vheight = h;
	}
	void ClearFrame() override {}
	void Render(RenderSurfaceInfo &, RenderSurfaceInfo &) override {}
	void Reset() override {}
	void SetFullscreenMode(FullscreenSettings) override {}
};

/* What the game saves to its battery-backed memory, kept in the guest's
 * memory (patch 0005): a project's save data file is what it starts with,
 * what the game saves since replaces it, and a power cycle reloads it, as on
 * the console. Being guest memory, it is part of every savestate. */
class ChimeraBattery : public IBatteryProvider, public IBatterySink
{
public:
	std::map<std::string, std::vector<uint8_t>> files;

	vector<uint8_t> LoadBattery(string extension) override
	{
		auto it = files.find(extension);
		return it == files.end() ? vector<uint8_t>() : it->second;
	}
	void SaveBattery(string extension, uint8_t *data, uint32_t length) override
	{
		files[extension].assign(data, data + length);
	}
};

static ChimeraInput *g_input;
static shared_ptr<ChimeraBattery> *g_battery;
static ChimeraAudio *g_audioDev;
static ChimeraVideo *g_videoDev;

/* ---- settings ---- */

static int setting_choice(const char *name, const char *const *options, int count, int dflt)
{
	char buf[64];
	buf[0] = 0;
	if (wbx_setting_str(name, buf, sizeof buf) < 0)
		return dflt;
	for (int i = 0; i < count; i++)
		if (strcmp(buf, options[i]) == 0)
			return i;
	fprintf(stderr, "[mesen] unknown %s '%s', using '%s'\n", name, buf, options[dflt]);
	return dflt;
}

static void read_ports(void)
{
	static const char *const opts1[] = { "gamepad", "none", "fourScore" };
	static const char *const opts2[] = { "none", "gamepad", "zapper", "arkanoid" };
	static const char *const optsExp[] = { "none", "famicomZapper", "famicomArkanoid", "fourPlayerAdapter", "epsm" };
	g_port1 = setting_choice("port1", opts1, 3, PORT1_GAMEPAD);
	g_port2 = setting_choice("port2", opts2, 4, PORT2_NONE);
	g_exp = setting_choice("expansion", optsExp, 5, EXP_NONE);
}

static void configure(EmuSettings *s)
{
	static const char *const regions[] = { "auto", "ntsc", "pal", "dendy" };
	static const ConsoleRegion regionValues[] = { ConsoleRegion::Auto, ConsoleRegion::Ntsc, ConsoleRegion::Pal, ConsoleRegion::Dendy };
	static const char *const ramStates[] = { "zeros", "ones", "random" };
	static const RamState ramValues[] = { RamState::AllZeros, RamState::AllOnes, RamState::Random };

	AudioConfig audio = s->GetAudioConfig();
	audio.SampleRate = AUDIO_RATE;
	audio.DisableDynamicSampleRate = true; /* no rate chasing a sound card */
	audio.EnableAudio = true;
	audio.MasterVolume = 100;
	s->SetAudioConfig(audio);

	PreferencesConfig prefs = s->GetPreferences();
	prefs.RewindBufferSize = 0; /* Chimera keeps the history, not Mesen */
	prefs.AutoSaveStateDelay = 0;
	prefs.ShowDebugInfo = false;
	s->SetPreferences(prefs);

	EmulationConfig emu = s->GetEmulationConfig();
	emu.RunAheadFrames = 0;
	emu.EmulationSpeed = 100;
	s->SetEmulationConfig(emu);

	NesConfig nes = s->GetNesConfig();
	nes.Region = regionValues[setting_choice("region", regions, 4, 0)];
	nes.RamPowerOnState = ramValues[setting_choice("ramPowerOnState", ramStates, 3, 0)];
	read_ports();
	static const ControllerType port2Types[] = { ControllerType::None, ControllerType::NesController,
		ControllerType::NesZapper, ControllerType::NesArkanoidController };
	if (g_port1 == PORT1_FOUR_SCORE) {
		/* the Four Score takes both ports and holds four pads */
		nes.Port1.Type = ControllerType::FourScore;
		for (int i = 0; i < 4; i++)
			nes.Port1SubPorts[i].Type = ControllerType::NesController;
		nes.Port2.Type = ControllerType::None;
	} else {
		nes.Port1.Type = g_port1 == PORT1_GAMEPAD ? ControllerType::NesController : ControllerType::None;
		nes.Port2.Type = port2Types[g_port2];
	}
	/* the Famicom's expansion port, beside the two controller ports (Mesen
	 * plugs it in whatever console it emulates) */
	static const ControllerType expTypes[] = { ControllerType::None, ControllerType::FamicomZapper,
		ControllerType::FamicomArkanoidController, ControllerType::FourPlayerAdapter, ControllerType::None };
	nes.ExpPort.Type = expTypes[g_exp];
	/* the EPSM in the expansion port: Mesen builds it with the cartridge, as
	 * for a header that asks for it (patch 0008). A header that asks for it
	 * plugs it in whatever this setting says, as in Mesen. */
	MesenExpansionEpsm = g_exp == EXP_EPSM;
	for (int i = 0; i < 4; i++)
		nes.ExpPortSubPorts[i].Type = g_exp == EXP_FOUR_PLAYER ? ControllerType::NesController : ControllerType::None;
	nes.LightDetectionRadius = 0; /* Mesen's UI's default */
	nes.AutoConfigureInput = false; /* the project's ports decide, not the database */
	nes.EnableHdPacks = false;
	nes.DisableGameDatabase = false;
	/* a Disk System game starts with its first side in the drive, as a
	 * person would put it in; Mesen's automatic side changes stay off (the
	 * movie says when a side is changed) */
	nes.FdsAutoLoadDisk = true;
	nes.FdsAutoInsertDisk = false;
	nes.FdsFastForwardOnLoad = false;
	for (int i = 0; i < 11; i++) {
		nes.ChannelVolumes[i] = 100;
		nes.ChannelPanning[i] = 0;
	}
	nes.EpsmVolume = 100;
	nes.InputScanline = 241;
	memcpy(nes.UserPalette, kDefaultPalette, sizeof kDefaultPalette);
	nes.IsFullColorPalette = false;
	s->SetNesConfig(nes);
}

/* ---- memory domains ---- */

struct Domain
{
	MemoryType type;
	const char *name;
};
static const Domain kDomains[] = {
	{ MemoryType::NesInternalRam, "RAM" },
	{ MemoryType::NesWorkRam, "WRAM" },
	{ MemoryType::NesSaveRam, "Battery RAM" },
	{ MemoryType::NesMapperRam, "Mapper RAM" },
	{ MemoryType::NesNametableRam, "CIRAM" },
	{ MemoryType::NesPaletteRam, "PALRAM" },
	{ MemoryType::NesSpriteRam, "OAM" },
	{ MemoryType::NesChrRam, "CHR RAM" },
	{ MemoryType::NesChrRom, "CHR ROM" },
	{ MemoryType::NesPrgRom, "PRG ROM" },
};
#define DOMAIN_KINDS (int)(sizeof kDomains / sizeof kDomains[0])

static int domain_kind(int index)
{
	if (!g_emu)
		return -1;
	int found = 0;
	for (int k = 0; k < DOMAIN_KINDS; k++) {
		ConsoleMemoryInfo m = g_emu->GetMemory(kDomains[k].type);
		if (m.Memory == nullptr || m.Size == 0)
			continue;
		if (found == index)
			return k;
		found++;
	}
	return -1;
}

extern "C" {

ECL_EXPORT const char *GetLoadError(void)
{
	return g_loadError;
}

/* Whether a file is a Famicom Disk System disk: fwNES's header, or a bare
 * disk image, whose first block starts "\x01*NINTENDO-HVC*" */
static int is_fds_image(const uint8_t *d, size_t n)
{
	return (n >= 4 && memcmp(d, "FDS\x1a", 4) == 0) || (n >= 15 && memcmp(d, "\x01*NINTENDO-HVC*", 15) == 0);
}

/* The program's stores to the EPSM's registers, $401C-$401F: STA, STX and
 * STY absolute and STA indexed. A cartridge whose header does not ask for
 * the EPSM but whose program writes there was made for one. */
static int epsm_stores(const uint8_t *prg, size_t n)
{
	static const uint8_t ops[] = { 0x8C, 0x8D, 0x8E, 0x99, 0x9D };
	int count = 0;
	for (size_t i = 0; i + 2 < n; i++)
		if (prg[i + 2] == 0x40 && prg[i + 1] >= 0x1C && prg[i + 1] <= 0x1F && memchr(ops, prg[i], sizeof ops))
			count++;
	return count;
}
/* fewer than this many could be chance in a large program's data */
#define EPSM_STORES_SUGGEST 8

/* What the core would choose before the game boots (Chimera's new-project
 * window asks it instead of Init, on the same mounts). A cartridge whose
 * header has the EPSM gets the EPSM's drums suggested, and with them the
 * rhythm ROM they play from. A cartridge with a plain header whose program
 * writes the EPSM's registers gets the EPSM in the expansion port as well.
 * Neither can be told of a game that reaches the chip only through $4016. */
ECL_EXPORT const char *SuggestSettings(void)
{
	static char answer[256];
	char name[512];
	const char *file = "rom";
	if (wbx_slot_count("rom") > 0 && wbx_slot_name("rom", 0, name, sizeof name) != NULL)
		file = name;
	std::vector<uint8_t> d;
	FILE *f = fopen(file, "rb");
	if (f) {
		uint8_t buf[65536];
		for (size_t n; (n = fread(buf, 1, sizeof buf, f)) > 0 && d.size() < (16u << 20);)
			d.insert(d.end(), buf, buf + n);
		fclose(f);
	}
	if (is_fds_image(d.data(), d.size())) {
		snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.fds\"}");
		return answer;
	}
	if (d.size() < 16 || memcmp(d.data(), "NES\x1a", 4) != 0) {
		snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.not_ines\"}");
		return answer;
	}
	const uint8_t *h = d.data();
	/* NES 2.0, console type 3 (extended), extended console type 4: the EPSM
	 * (Mesen's NesHeader::HasEpsm) */
	int epsm = (h[7] & 0x0C) == 0x08 && (h[7] & 0x03) == 0x03 && (h[13] & 0x0F) == 0x04;
	if (epsm) {
		snprintf(answer, sizeof answer, "{\"values\": {\"epsmDrums\": \"on\"}, \"note\": \"suggest.epsm\"}");
		return answer;
	}
	/* the program: after the header and a trainer, as many 16 KiB banks as
	 * the header's low byte says (enough for this question) */
	size_t at = 16 + ((h[6] & 0x04) ? 512 : 0);
	size_t prg = (size_t)h[4] * 16384;
	if (at > d.size())
		at = d.size();
	if (prg == 0 || prg > d.size() - at)
		prg = d.size() - at;
	if (epsm_stores(d.data() + at, prg) >= EPSM_STORES_SUGGEST)
		snprintf(answer, sizeof answer, "{\"values\": {\"expansion\": \"epsm\", \"epsmDrums\": \"on\"}, \"note\": \"suggest.epsm_program\"}");
	else
		snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.no_epsm\"}");
	return answer;
}

ECL_EXPORT int Init(void)
{
	g_loadError[0] = 0;

	/* the sequence Mesen's "random" draws from; the seed is a setting, so a
	 * project that wants a different power-on state says so */
	MesenFixedRandom::Seed((uint64_t)wbx_setting_ulong("randomSeed", 0));

	FolderUtilities::SetHomeFolder(".");

	std::string db(mesen_nes_db, mesen_nes_db_size);
	std::istringstream dbStream(db);
	GameDatabase::LoadGameDb(dbStream);

	BaseControlManager::InputReadHook = on_input_read;

	g_emu = new Emulator();
	g_emu->Initialize(false);
	configure(g_emu->GetSettings());
	/* every folder Mesen asks for is the guest's root, where the frontend
	 * mounts a firmware file under its id. After configure(): setting the
	 * preferences sets the overrides again, the firmware one to nothing. */
	FolderUtilities::SetFolderOverrides(".", ".", ".", ".");

	g_input = new ChimeraInput();
	g_audioDev = new ChimeraAudio();
	g_videoDev = new ChimeraVideo();
	g_emu->GetSoundMixer()->RegisterAudioDevice(g_audioDev);
	g_emu->GetVideoRenderer()->RegisterRenderingDevice(g_videoDev);

	/* the saved game the project starts from, if it has one */
	g_battery = new shared_ptr<ChimeraBattery>(new ChimeraBattery());
	char saveName[512];
	int hasSave = wbx_slot_count("savedata") > 0 && wbx_slot_name("savedata", 0, saveName, sizeof saveName) != NULL;
	if (hasSave) {
		FILE *sf = fopen(saveName, "rb");
		if (sf == NULL) {
			snprintf(g_loadError, sizeof g_loadError, "error.not_opened" TEXT_ARG "%s", saveName);
			return 0;
		}
		std::vector<uint8_t> &data = (*g_battery)->files[".sav"];
		uint8_t buf[4096];
		for (size_t n; (n = fread(buf, 1, sizeof buf, sf)) > 0;)
			data.insert(data.end(), buf, buf + n);
		fclose(sf);
	}
	g_emu->GetBatteryManager()->SetBatteryProvider(*g_battery);
	g_emu->GetBatteryManager()->SetBatterySink(*g_battery);

	/* the cartridge: the project slot's file, else the plain rom mount */
	char name[512];
	const char *file = "rom";
	if (wbx_slot_count("rom") > 0 && wbx_slot_name("rom", 0, name, sizeof name) != NULL)
		file = name;
	FILE *f = fopen(file, "rb");
	if (f == NULL) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_file");
		return 0;
	}
	uint8_t head[16] = { 0 };
	size_t headLen = fread(head, 1, sizeof head, f);
	fclose(f);
	/* a Disk System disk needs the Disk System's BIOS, which the frontend
	 * mounts under its id; Mesen would only say the game did not load */
	if (is_fds_image(head, headLen)) {
		FILE *bf = fopen("disksys.rom", "rb");
		if (bf == NULL) {
			snprintf(g_loadError, sizeof g_loadError, "error.no_fds_bios");
			return 0;
		}
		fclose(bf);
	}

	if (!g_emu->LoadRom(VirtualFile(std::string(file)), VirtualFile())) {
		snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", file);
		return 0;
	}
	if (g_emu->GetConsoleType() != ConsoleType::Nes) {
		snprintf(g_loadError, sizeof g_loadError, "error.not_nes" TEXT_ARG "%s", file);
		return 0;
	}
	if (hasSave && g_emu->GetMemory(MemoryType::NesSaveRam).Size == 0) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_battery" TEXT_ARG "%s", saveName);
		return 0;
	}

	/* an input provider belongs to the console, so it is given once the
	 * console exists, and again whenever a power cycle makes a new one */
	g_emu->RegisterInputProvider(g_input);

	/* what Mesen said while loading (the header it read, the mapper, a
	 * firmware it did not find) goes to the core's log, for a person and
	 * for the gate */
	std::istringstream log(MessageManager::GetLog());
	for (std::string line; std::getline(log, line);)
		if (!line.empty())
			fprintf(stderr, "[mesen] %s\n", line.c_str());

	NesConsole *nes = dynamic_cast<NesConsole *>(g_emu->GetConsole().get());
	g_epsm = nes != nullptr && nes->GetEpsm() != nullptr;
	Fds *fds = nes != nullptr ? dynamic_cast<Fds *>(nes->GetMapper()) : nullptr;
	g_fds = fds != nullptr ? (int)fds->GetSideCount() : 0;
	g_diskSelected = 0;
	memset(g_diskWas, 0, sizeof g_diskWas);
	if (g_fds)
		fprintf(stderr, "[mesen] Disk System: %d disk sides\n", g_fds);
	/* one greppable line per boot: the gate witnesses through it that both
	 * flavors built the same machine around the cartridge's header */
	fprintf(stderr, "[mesen] EPSM %s\n", g_epsm ? "present" : "absent");
	if (g_epsm) {
		/* whether the drums have their sounds: Mesen reads the file only if
		 * it is exactly 8 KiB (FirmwareHelper::LoadYmf288AdpcmRom) */
		FILE *rf = fopen("ymf288_adpcm_rom.bin", "rb");
		long size = -1;
		if (rf) {
			fseek(rf, 0, SEEK_END);
			size = ftell(rf);
			fclose(rf);
		}
		fprintf(stderr, "[mesen] EPSM rhythm ROM %s\n", size == 0x2000 ? "loaded" : "missing: the drums are silent");
	}
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BTN_COUNT)
		g_buttons[index] = state != 0;
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed;
	if (!g_emu)
		return;

	/* Power and Reset are levels held on a frame, as on the console */
	if (g_buttons[0]) {
		g_emu->PowerCycle();
		g_emu->RegisterInputProvider(g_input);
		/* a new console: its drive has the first side in again */
		g_diskSelected = 0;
	} else if (g_buttons[1])
		g_emu->Reset();

	/* the Disk System's drive, between frames: Previous and Next Disk move
	 * the selector over the disk's sides when pressed; Eject Disk takes the
	 * disk out when pressed and puts the selected side in when let go (the
	 * BIOS sees the drive empty for as long as it is held) */
	if (g_fds) {
		NesConsole *nes = dynamic_cast<NesConsole *>(g_emu->GetConsoleUnsafe());
		Fds *fds = nes != nullptr ? dynamic_cast<Fds *>(nes->GetMapper()) : nullptr;
		const uint8_t *now = &g_buttons[BTN_PREV_DISK];
		if (now[0] && !g_diskWas[0])
			g_diskSelected = (g_diskSelected + g_fds - 1) % g_fds;
		if (now[1] && !g_diskWas[1])
			g_diskSelected = (g_diskSelected + 1) % g_fds;
		if (fds != nullptr) {
			if (now[2] && !g_diskWas[2])
				fds->EjectDisk();
			else if (!now[2] && g_diskWas[2])
				fds->InsertDisk((uint32_t)g_diskSelected);
		}
		memcpy(g_diskWas, now, sizeof g_diskWas);
	}

	g_emu->GetVideoDecoder()->SetDecodeEnabled(g_render != 0);
	g_nsamples = 0;
	uint32_t lagBefore = g_emu->GetLagCounter();
	g_emu->RunSingleFrame();
	g_inputRead = g_emu->GetLagCounter() == lagBefore;
}

ECL_EXPORT void SetRenderingEnabled(int on) { g_render = on != 0; }

ECL_EXPORT void SetAxis(int32_t index, int32_t value)
{
	if (index >= 0 && index < AXIS_COUNT)
		g_axes[index] = value;
}

/* Which declared controls this machine has, from what the ports hold
 * (Chimera asks once, after Init). Indices are the wire's. */
ECL_EXPORT int IsButtonActive(int32_t index)
{
	int fourScore = g_port1 == PORT1_FOUR_SCORE;
	/* the four-player adapter's players are players 1 to 4; with a pad in
	 * a controller port as well, that pad and the adapter's are one player */
	int adapter = g_exp == EXP_FOUR_PLAYER;
	if (index < BTN_CONSOLE)
		return index >= 0;
	if (index < BTN_TRIGGER) {
		int player = (index - BTN_CONSOLE) / BTN_PER_PAD;
		switch (player) {
		case 0: return g_port1 != PORT1_NONE || adapter;
		case 1: return fourScore || g_port2 == PORT2_GAMEPAD || adapter;
		default: return fourScore || adapter;
		}
	}
	if (index == BTN_TRIGGER)
		return !fourScore && g_port2 == PORT2_ZAPPER;
	if (index == BTN_FIRE)
		return !fourScore && g_port2 == PORT2_ARKANOID;
	if (index == BTN_EXP_TRIGGER)
		return g_exp == EXP_ZAPPER;
	if (index == BTN_EXP_FIRE)
		return g_exp == EXP_ARKANOID;
	if (index == BTN_PREV_DISK || index == BTN_NEXT_DISK)
		return g_fds > 1;
	if (index == BTN_EJECT_DISK)
		return g_fds > 0;
	return 0;
}

ECL_EXPORT int IsAxisActive(int32_t index)
{
	int fourScore = g_port1 == PORT1_FOUR_SCORE;
	if (index == AXIS_ZAPPER_X || index == AXIS_ZAPPER_Y)
		return !fourScore && g_port2 == PORT2_ZAPPER;
	if (index == AXIS_PADDLE)
		return !fourScore && g_port2 == PORT2_ARKANOID;
	if (index == AXIS_EXP_ZAPPER_X || index == AXIS_EXP_ZAPPER_Y)
		return g_exp == EXP_ZAPPER;
	if (index == AXIS_EXP_PADDLE)
		return g_exp == EXP_ARKANOID;
	return 0;
}

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_video; }
ECL_EXPORT int GetVideoWidth(void) { return g_vwidth; }
ECL_EXPORT int GetVideoHeight(void) { return g_vheight; }

ECL_EXPORT int16_t *GetAudio(void) { return g_audio; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_nsamples; }

ECL_EXPORT int GetVsyncNumerator(void)
{
	return g_emu && g_emu->GetRegion() != ConsoleRegion::Ntsc ? 322445 : 39375000;
}
ECL_EXPORT int GetVsyncDenominator(void)
{
	return g_emu && g_emu->GetRegion() != ConsoleRegion::Ntsc ? 6448 : 655171;
}

ECL_EXPORT int InputWasRead(void) { return g_inputRead; }

ECL_EXPORT void SetInputPollCallback(uint64_t fn)
{
	g_inputPoll = (uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))(uintptr_t)fn;
}

ECL_EXPORT int GetMemoryDomainCount(void)
{
	int n = 0;
	while (domain_kind(n) >= 0)
		n++;
	return n;
}
ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	int k = domain_kind(i);
	return k >= 0 ? kDomains[k].name : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	int k = domain_kind(i);
	return k >= 0 ? (uint8_t *)g_emu->GetMemory(kDomains[k].type).Memory : NULL;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	int k = domain_kind(i);
	return k >= 0 ? (int64_t)g_emu->GetMemory(kDomains[k].type).Size : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i)
{
	int k = domain_kind(i);
	return k >= 0 && kDomains[k].type != MemoryType::NesPrgRom && kDomains[k].type != MemoryType::NesChrRom;
}

/* ---- the buses ----
 * 0 "System Bus": the CPU's 64 KiB as the CPU sees it, read and written
 * through Mesen's debugger accessors (PeekRam and DebugWrite), which have no
 * side effects: reading $2002 does not clear the vertical blank, and a write
 * lands only in RAM and the cartridge's memory, never in a register.
 * 1 "PPU Bus": the picture chip's 16 KiB as it sees them - the cartridge's
 * pattern tables at $0000-$1FFF, the nametables at $2000-$3EFF (the
 * console's 2 KiB or the cartridge's, as the mapper wires them) and the
 * palette at $3F00-$3FFF - read and written through the same accessors
 * Mesen's debugger uses (DebugReadVram, DebugWriteVram), which do not
 * tell the mapper an address went by (no MMC3 scanline counter moves). */
#define BUS_COUNT 2
static const char *const kBusNames[BUS_COUNT] = { "System Bus", "PPU Bus" };
static const int64_t kBusSizes[BUS_COUNT] = { 0x10000, 0x4000 };

static NesConsole *bus_console()
{
	return g_emu ? dynamic_cast<NesConsole *>(g_emu->GetConsoleUnsafe()) : NULL;
}

static uint8_t bus_read(NesConsole *nes, int bus, uint16_t addr)
{
	return bus == 0 ? nes->GetMemoryManager()->DebugRead(addr) : nes->DebugReadVram(addr & 0x3FFF);
}

ECL_EXPORT int GetBusCount(void) { return BUS_COUNT; }
ECL_EXPORT const char *GetBusName(int i) { return i >= 0 && i < BUS_COUNT ? kBusNames[i] : NULL; }
ECL_EXPORT int64_t GetBusSize(int i) { return i >= 0 && i < BUS_COUNT ? kBusSizes[i] : 0; }
ECL_EXPORT int GetBusWritable(int i) { return i >= 0 && i < BUS_COUNT; }

ECL_EXPORT int PeekBus(int bus, int addr)
{
	NesConsole *nes = bus_console();
	if (nes == NULL || bus < 0 || bus >= BUS_COUNT || addr < 0 || addr >= kBusSizes[bus])
		return 0;
	return bus_read(nes, bus, (uint16_t)addr);
}

ECL_EXPORT void PokeBus(int bus, int addr, int value)
{
	NesConsole *nes = bus_console();
	if (nes == NULL || bus < 0 || bus >= BUS_COUNT || addr < 0 || addr >= kBusSizes[bus])
		return;
	if (bus == 0)
		nes->GetMemoryManager()->DebugWrite((uint16_t)addr, (uint8_t)value, true);
	else
		nes->DebugWriteVram((uint16_t)addr, (uint8_t)value);
}

/* up to 64 KiB of a bus at once, into memory no savestate carries */
ECL_INVISIBLE static uint8_t g_busRead[0x10000];
ECL_EXPORT const uint8_t *ReadBus(int32_t bus, int64_t addr, int32_t len)
{
	NesConsole *nes = bus_console();
	if (len > (int32_t)sizeof g_busRead)
		len = (int32_t)sizeof g_busRead;
	int ok = nes != NULL && bus >= 0 && bus < BUS_COUNT;
	for (int32_t i = 0; i < len; i++) {
		int64_t a = addr + i;
		g_busRead[i] = (ok && a >= 0 && a < kBusSizes[bus]) ? bus_read(nes, bus, (uint16_t)a) : 0;
	}
	return g_busRead;
}

/* ---- save data: the battery-backed RAM of the cartridge ---- */
ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	if (!g_emu)
		return 0;
	ConsoleMemoryInfo m = g_emu->GetMemory(MemoryType::NesSaveRam);
	return m.Memory != nullptr && m.Size > 0 ? 1 : 0;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i) { return i == 0 ? "battery.sav" : NULL; }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	return i == 0 && GetSaveDataFileCount() ? (int64_t)g_emu->GetMemory(MemoryType::NesSaveRam).Size : 0;
}
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	return i == 0 && GetSaveDataFileCount() ? (const uint8_t *)g_emu->GetMemory(MemoryType::NesSaveRam).Memory : NULL;
}

} /* extern "C" */
