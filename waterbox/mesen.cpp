/* mesen.cpp - Mesen (MesenCE) behind Chimera's guest ABI.
 *
 * Mesen's Emulator object is the glue between its consoles and its
 * frontend: settings, the sound mixer, the video decoder, the input
 * providers. This file builds one Emulator, gives it a Chimera input
 * provider, a sound device that keeps the frame's samples and a rendering
 * device that keeps the frame's picture, and steps it one frame per
 * FrameAdvance on the caller's thread (patch 0001: no emulation thread, no
 * decode or render thread, no frame limiter).
 *
 * The package is several machines (waterbox.config "machines"), one per
 * system Mesen emulates; the setting "machine" says which. The NES is the
 * first and the default, and a project made before the other machines
 * existed is an NES project: everything the NES does here is what it did
 * when it was the only machine.
 *
 * The same file is compiled into the guest (miniBox emulibc) and into the
 * native reference (native-shim/emulibc.h). That is what makes the
 * equivalence gate a proof.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
#include "SNES/SnesConsole.h"
#include "SNES/SnesMemoryManager.h"
#include "SNES/MemoryMappings.h"
#include "SNES/BaseCartridge.h"
#include "SNES/Spc.h"
#include "SNES/Input/SnesController.h"
#include "Gameboy/Gameboy.h"
#include "Gameboy/GbMemoryManager.h"
#include "Gameboy/Input/GbController.h"
#include "GBA/GbaConsole.h"
#include "GBA/GbaMemoryManager.h"
#include "GBA/Input/GbaController.h"
#include "PCE/PceConsole.h"
#include "PCE/PceMemoryManager.h"
#include "PCE/PceVce.h"
#include "PCE/Input/PceController.h"
#include "Shared/CdReader.h"
#include "SMS/SmsConsole.h"
#include "SMS/SmsMemoryManager.h"
#include "SMS/Input/SmsController.h"
#include "SMS/Input/ColecoVisionController.h"
#include "WS/WsConsole.h"
#include "WS/WsMemoryManager.h"
#include "WS/WsPpu.h"
#include "WS/Input/WsController.h"
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

/* patch 0009: the time of day the cartridges' clocks read */
extern int64_t MesenVirtualClockMs;

/* ---- the machines: waterbox.config "machines", picked by the setting
 * "machine". The order is the setting's options'. ---- */
enum Machine {
	M_NES, M_SNES, M_SGB, M_GB, M_GBC, M_GBA, M_PCE, M_SGX, M_PCECD,
	M_SMS, M_GG, M_SG, M_CV, M_WS, M_WSC, M_COUNT
};
static const char *const kMachineOptions[M_COUNT] = {
	"nes", "snes", "sgb", "gb", "gbc", "gba", "pce", "sgx", "pcecd",
	"sms", "gg", "sg1000", "coleco", "ws", "wsc",
};
static int g_machine = M_NES;

/* ---- the NES's wire: waterbox.config "input.buttons" order ----
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
/* the largest wire of any machine (the ColecoVision's: 2 + 2 x 18) */
#define BTN_MAX 64
static uint8_t g_buttons[BTN_MAX];

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

/* NES wire column -> NesController::Buttons bit */
static const uint8_t kColToBit[BTN_PER_PAD] = {
	NesController::A, NesController::B, NesController::Select, NesController::Start,
	NesController::Up, NesController::Down, NesController::Left, NesController::Right,
};

/* ---- the other machines' wires ----
 * Each is the console's buttons, then the same pad once per player:
 * player 1's columns, then player 2's, and so on. A console button is
 * Power, Reset, or a bit of player 1's device (the Master System's Pause,
 * the WonderSwan's Sound button). The orders are the ones Chimera's other
 * cores use for the same consoles (snes9x, gambatte, gpgx). */
enum { CON_POWER = -1, CON_RESET = -2 };
struct PadLayout
{
	int consoleCount;
	int console[3];   /* CON_POWER, CON_RESET, or a bit of player 1's device */
	int padCount;     /* columns per player */
	uint8_t pad[18];  /* column -> the device's bit */
	int maxPlayers;
};
static const PadLayout kLayouts[M_COUNT] = {
	/* M_NES: not used; the NES keeps its own wire above */
	{ 2, { CON_POWER, CON_RESET }, 8, {}, 4 },
	/* M_SNES: Up Down Left Right Select Start Y B X A L R; players 1 to 5
	 * (2 to 5 through the multitap in port 2) */
	{ 2, { CON_POWER, CON_RESET }, 12, { SnesController::Up, SnesController::Down, SnesController::Left, SnesController::Right,
		SnesController::Select, SnesController::Start, SnesController::Y, SnesController::B, SnesController::X,
		SnesController::A, SnesController::L, SnesController::R }, 5 },
	/* M_SGB: the Super Game Boy is a Super NES cartridge: the same pads */
	{ 2, { CON_POWER, CON_RESET }, 12, { SnesController::Up, SnesController::Down, SnesController::Left, SnesController::Right,
		SnesController::Select, SnesController::Start, SnesController::Y, SnesController::B, SnesController::X,
		SnesController::A, SnesController::L, SnesController::R }, 5 },
	/* M_GB, M_GBC: Up Down Left Right Start Select B A */
	{ 1, { CON_POWER }, 8, { GbController::Up, GbController::Down, GbController::Left, GbController::Right,
		GbController::Start, GbController::Select, GbController::B, GbController::A }, 1 },
	{ 1, { CON_POWER }, 8, { GbController::Up, GbController::Down, GbController::Left, GbController::Right,
		GbController::Start, GbController::Select, GbController::B, GbController::A }, 1 },
	/* M_GBA: the same, then L R */
	{ 1, { CON_POWER }, 10, { GbaController::Up, GbaController::Down, GbaController::Left, GbaController::Right,
		GbaController::Start, GbaController::Select, GbaController::B, GbaController::A, GbaController::L,
		GbaController::R }, 1 },
	/* M_PCE, M_SGX, M_PCECD: Up Down Left Right I II Select Run; players 1
	 * to 5 through the multitap (TurboTap) */
	{ 1, { CON_POWER }, 8, { PceController::Up, PceController::Down, PceController::Left, PceController::Right,
		PceController::I, PceController::II, PceController::Select, PceController::Run }, 5 },
	{ 1, { CON_POWER }, 8, { PceController::Up, PceController::Down, PceController::Left, PceController::Right,
		PceController::I, PceController::II, PceController::Select, PceController::Run }, 5 },
	{ 1, { CON_POWER }, 8, { PceController::Up, PceController::Down, PceController::Left, PceController::Right,
		PceController::I, PceController::II, PceController::Select, PceController::Run }, 5 },
	/* M_SMS: Power, Reset, Pause; Up Down Left Right Button 1 Button 2 */
	{ 3, { CON_POWER, CON_RESET, SmsController::Pause }, 6, { SmsController::Up, SmsController::Down,
		SmsController::Left, SmsController::Right, SmsController::B, SmsController::A }, 2 },
	/* M_GG: Power; Up Down Left Right Button 1 Button 2 Start (the
	 * controller's Pause bit, which the Game Gear reads as Start) */
	{ 1, { CON_POWER }, 7, { SmsController::Up, SmsController::Down, SmsController::Left, SmsController::Right,
		SmsController::B, SmsController::A, SmsController::Pause }, 1 },
	/* M_SG: Power (Mesen does not emulate the SG-1000's Hold button: its
	 * pause interrupt is the Master System's only) */
	{ 1, { CON_POWER }, 6, { SmsController::Up, SmsController::Down,
		SmsController::Left, SmsController::Right, SmsController::B, SmsController::A }, 2 },
	/* M_CV: Power, Reset; Up Down Left Right, the two side buttons, the
	 * keypad's 1 to 9, 0, * and # */
	{ 2, { CON_POWER, CON_RESET }, 18, { ColecoVisionController::Up, ColecoVisionController::Down,
		ColecoVisionController::Left, ColecoVisionController::Right, ColecoVisionController::L,
		ColecoVisionController::R, ColecoVisionController::Num1, ColecoVisionController::Num2,
		ColecoVisionController::Num3, ColecoVisionController::Num4, ColecoVisionController::Num5,
		ColecoVisionController::Num6, ColecoVisionController::Num7, ColecoVisionController::Num8,
		ColecoVisionController::Num9, ColecoVisionController::Num0, ColecoVisionController::Star,
		ColecoVisionController::Pound }, 2 },
	/* M_WS, M_WSC: Power, Sound; X1 X2 X3 X4 (up, right, down, left), Y1
	 * Y2 Y3 Y4, Start, A, B */
	{ 2, { CON_POWER, WsController::Sound }, 11, { WsController::Up, WsController::Right, WsController::Down,
		WsController::Left, WsController::Up2, WsController::Right2, WsController::Down2, WsController::Left2,
		WsController::Start, WsController::A, WsController::B }, 1 },
	{ 2, { CON_POWER, WsController::Sound }, 11, { WsController::Up, WsController::Right, WsController::Down,
		WsController::Left, WsController::Up2, WsController::Right2, WsController::Down2, WsController::Left2,
		WsController::Start, WsController::A, WsController::B }, 1 },
};
static int wire_count(void)
{
	if (g_machine == M_NES)
		return BTN_COUNT;
	const PadLayout &l = kLayouts[g_machine];
	return l.consoleCount + l.padCount * l.maxPlayers;
}

/* what the other machines' ports hold */
enum { SNES_PORT_NONE, SNES_PORT_GAMEPAD, SNES_PORT_MULTITAP };
enum { PCE_PORT_GAMEPAD, PCE_PORT_NONE, PCE_PORT_MULTITAP };
static int g_snesPort1 = SNES_PORT_GAMEPAD, g_snesPort2 = SNES_PORT_GAMEPAD;
static int g_pcePort = PCE_PORT_GAMEPAD;
static int g_smsPort2 = 1; /* the Master System's and SG-1000's second pad */

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

/* a game Mesen is given from memory under the name that picks the machine
 * (a ColecoVision game called .bin is given as .col): Mesen reloads a game
 * by its path at a power cycle, so this core does that one itself */
static std::vector<uint8_t> *g_gameData;
static std::string *g_gameName;

/* the machine's own time, for the cartridges' clocks (patch 0009): the
 * setting rtcStart, then each frame's length */
static int64_t g_clockStartMs;
static uint64_t g_clockFrames, g_clockNum, g_clockDen;

/* the picture of the frame, BGRA; Mesen's decoder writes 0xAARRGGBB words,
 * which are BGRA bytes on a little-endian machine. The NES's fits the
 * array; a PC Engine picture mixing resolutions is drawn at four times its
 * size (1168 x 968), into a larger buffer made for it. */
#define VIDEO_MAX_W 640
#define VIDEO_MAX_H 480
#define PCE_VIDEO_MAX_W 1168
#define PCE_VIDEO_MAX_H 968
static uint32_t g_videoNes[VIDEO_MAX_W * VIDEO_MAX_H];
static uint32_t *g_video = g_videoNes;
static int g_videoMaxW = VIDEO_MAX_W, g_videoMaxH = VIDEO_MAX_H;
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

/* patch 0003 calls this at each read of the controls */
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

/* the PC Engine's palette by default: the UI's PcEngineConfig.DefaultPalette
 * (UI/Config/PcEngineConfig.cs); the core's own is all zeros */
#include "pce-palette.inc"

/* ---- the three devices Mesen talks to ---- */

static void set_pad(BaseControlDevice *device, int player)
{
	const uint8_t *pad = &g_buttons[BTN_CONSOLE + player * BTN_PER_PAD];
	for (int col = 0; col < BTN_PER_PAD; col++)
		device->SetBitValue(kColToBit[col], pad[col] != 0);
}

/* another machine's pad: the player's columns of the wire, and on player
 * 1's device the console buttons that are its bits */
static void set_machine_pad(BaseControlDevice *device, int player)
{
	const PadLayout &l = kLayouts[g_machine];
	if (player < 0 || player >= l.maxPlayers)
		return;
	const uint8_t *pad = &g_buttons[l.consoleCount + player * l.padCount];
	for (int col = 0; col < l.padCount; col++)
		device->SetBitValue(l.pad[col], pad[col] != 0);
	if (player == 0)
		for (int i = 0; i < l.consoleCount; i++)
			if (l.console[i] >= 0)
				device->SetBitValue((uint8_t)l.console[i], g_buttons[i] != 0);
}

static int set_hub(BaseControlDevice *device, int firstPlayer)
{
	IControllerHub *hub = dynamic_cast<IControllerHub *>(device);
	if (hub == nullptr)
		return 0;
	for (int i = 0; i < hub->GetHubPortCount(); i++) {
		shared_ptr<BaseControlDevice> pad = hub->GetController(i);
		if (pad)
			set_machine_pad(pad.get(), firstPlayer + i);
	}
	hub->RefreshHubState();
	return 1;
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
		/* the other machines: a pad is its port's player */
		case ControllerType::SnesController:
		case ControllerType::SmsController:
		case ControllerType::ColecoVisionController:
			if (port < 0 || port > 1)
				return false;
			set_machine_pad(device, port);
			return true;
		case ControllerType::GameboyController:
		case ControllerType::GbaController:
		case ControllerType::PceController:
		case ControllerType::WsController:
		case ControllerType::WsControllerVertical:
			if (port != 0)
				return false;
			set_machine_pad(device, 0);
			return true;
		case ControllerType::Multitap:
			/* the Super NES multitap, in port 2: players 2 to 5 */
			return set_hub(device, port == 0 ? 0 : 1) != 0;
		case ControllerType::PceTurboTap:
			return set_hub(device, 0) != 0;
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
		if (w > g_videoMaxW) w = g_videoMaxW;
		if (h > g_videoMaxH) h = g_videoMaxH;
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

static const char *const kRamStates[] = { "zeros", "ones", "random" };
static const RamState kRamValues[] = { RamState::AllZeros, RamState::AllOnes, RamState::Random };
/* Mesen's own choice for the RAM at power on, as its UI sets it: random for
 * the Super NES, the Game Boy, the PC Engine and the Master System, zeros
 * for the Game Boy Advance and the ColecoVision (the WonderSwan has none) */
static RamState ram_state(int dflt)
{
	return kRamValues[setting_choice("ramPowerOnState", kRamStates, 3, dflt)];
}

static void configure_nes(EmuSettings *s)
{
	static const char *const regions[] = { "auto", "ntsc", "pal", "dendy" };
	static const ConsoleRegion regionValues[] = { ConsoleRegion::Auto, ConsoleRegion::Ntsc, ConsoleRegion::Pal, ConsoleRegion::Dendy };

	NesConfig nes = s->GetNesConfig();
	nes.Region = regionValues[setting_choice("region", regions, 4, 0)];
	nes.RamPowerOnState = ram_state(0);
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

static int setting_on(const char *name)
{
	static const char *const offOn[] = { "off", "on" };
	return setting_choice(name, offOn, 2, 0);
}

/* the other machines, each as Mesen's UI sets it up by default (the core's
 * own defaults are not the UI's: the Master System's and ColecoVision's
 * channel volumes are 0, the PC Engine's palette is empty), with what the
 * project's settings say. Frame blending (the UI's default for the
 * handhelds) is off: it mixes each picture with the one before, so a frame
 * drawn after frames that were not would not be the frame's own picture. */
static void configure_other(EmuSettings *s)
{
	static const char *const snesPorts[] = { "none", "gamepad", "multitap" };
	static const char *const pcePorts[] = { "gamepad", "none", "multitap" };
	static const char *const regions3[] = { "auto", "ntsc", "pal" };
	static const ConsoleRegion region3Values[] = { ConsoleRegion::Auto, ConsoleRegion::Ntsc, ConsoleRegion::Pal };

	SnesConfig snes = s->GetSnesConfig();
	g_snesPort1 = setting_choice("snesPort1", snesPorts, 2, SNES_PORT_GAMEPAD);
	g_snesPort2 = setting_choice("snesPort2", snesPorts, 3, SNES_PORT_GAMEPAD);
	snes.Port1.Type = g_snesPort1 == SNES_PORT_GAMEPAD ? ControllerType::SnesController : ControllerType::None;
	snes.Port2.Type = g_snesPort2 == SNES_PORT_GAMEPAD ? ControllerType::SnesController
		: g_snesPort2 == SNES_PORT_MULTITAP ? ControllerType::Multitap : ControllerType::None;
	for (int i = 0; i < 4; i++) {
		snes.Port1SubPorts[i].Type = ControllerType::SnesController;
		snes.Port2SubPorts[i].Type = ControllerType::SnesController;
	}
	snes.Region = region3Values[setting_choice("snesRegion", regions3, 3, 0)];
	snes.RamPowerOnState = ram_state(2);
	snes.EnableRandomPowerOnState = false;
	snes.EnableStrictBoardMappings = false;
	snes.SpcClockSpeedAdjustment = 40; /* the UI's default */
	snes.GsuClockSpeed = 100;
	snes.AllowInvalidInput = false;
	/* the picture as Mesen's UI shows it: the lines a television hides are
	 * cut (UI/Config: 7 at the top and 8 at the bottom of the Super NES's, 24
	 * and 24 of the Master System's, 48 all round the Game Gear's, 3 at the
	 * top and 18 at either side of the PC Engine's) */
	snes.Overscan.Top = 7;
	snes.Overscan.Bottom = 8;
	/* the Satellaview's clock: the same time of day as the cartridges' */
	snes.BsxCustomDate = g_clockStartMs / 1000;
	s->SetSnesConfig(snes);

	GameboyConfig gb = s->GetGameboyConfig();
	gb.Controller.Type = ControllerType::GameboyController;
	gb.Model = g_machine == M_SGB ? GameboyModel::SuperGameboy
		: g_machine == M_GBC ? GameboyModel::GameboyColor : GameboyModel::Gameboy;
	static const char *const sgbModels[] = { "sgb2", "sgb1" };
	gb.UseSgb2 = setting_choice("sgbModel", sgbModels, 2, 0) == 0;
	gb.UseLocalLinkCable = false;
	gb.BlendFrames = false;
	gb.GbcAdjustColors = true;
	gb.HideSgbBorders = false;
	gb.RamPowerOnState = ram_state(2);
	gb.AllowInvalidInput = false;
	gb.Square1Vol = gb.Square2Vol = gb.NoiseVol = gb.WaveVol = 100;
	s->SetGameboyConfig(gb);

	GbaConfig gba = s->GetGbaConfig();
	gba.Controller.Type = ControllerType::GbaController;
	gba.SkipBootScreen = false;
	gba.BlendFrames = false;
	/* off: its colour curve is computed with pow(), whose last bit the
	 * sandbox's C library and the host's do not always agree on */
	gba.GbaAdjustColors = false;
	gba.RamPowerOnState = ram_state(0);
	gba.SaveType = GbaSaveType::AutoDetect;
	gba.RtcType = GbaRtcType::AutoDetect;
	gba.AllowInvalidInput = false;
	gba.EnableMgbaLogApi = false;
	gba.ChannelAVol = gba.ChannelBVol = gba.Square1Vol = gba.Square2Vol = gba.NoiseVol = gba.WaveVol = 100;
	s->SetGbaConfig(gba);

	PcEngineConfig pce = s->GetPcEngineConfig();
	g_pcePort = setting_choice("pcePort", pcePorts, 3, PCE_PORT_GAMEPAD);
	pce.Port1.Type = g_pcePort == PCE_PORT_GAMEPAD ? ControllerType::PceController
		: g_pcePort == PCE_PORT_MULTITAP ? ControllerType::PceTurboTap : ControllerType::None;
	for (int i = 0; i < 5; i++)
		pce.Port1SubPorts[i].Type = ControllerType::PceController;
	static const char *const pceModels[] = { "auto", "pcengine", "turbografx" };
	static const PceConsoleType pceModelValues[] = { PceConsoleType::Auto, PceConsoleType::PcEngine, PceConsoleType::TurboGrafx };
	pce.ConsoleType = g_machine == M_SGX ? PceConsoleType::SuperGrafx : pceModelValues[setting_choice("pceModel", pceModels, 3, 0)];
	pce.CdRomType = PceCdRomType::Arcade;
	pce.EnableCdRomForHuCardGames = false;
	pce.DisableCdRomSaveRamForHuCardGames = false;
	pce.PreventSelectRunReset = true; /* the UI's default */
	pce.AllowInvalidInput = false;
	pce.RamPowerOnState = ram_state(2);
	pce.EnableRandomPowerOnState = false;
	pce.AdpcmClockSpeed = 32100;
	for (int i = 0; i < 6; i++)
		pce.ChannelVol[i] = 100;
	pce.CdAudioVolume = 100;
	pce.AdpcmVolume = 100;
	pce.UseHuC6280aAudio = true;
	pce.ForceFixedResolution = false;
	pce.Overscan.Top = 3;
	pce.Overscan.Left = 18;
	pce.Overscan.Right = 18;
	memcpy(pce.Palette, kPcePalette, sizeof kPcePalette);
	s->SetPcEngineConfig(pce);

	SmsConfig sms = s->GetSmsConfig();
	g_smsPort2 = setting_choice("smsPort2", snesPorts, 2, 1);
	sms.Port1.Type = ControllerType::SmsController;
	/* the Game Gear has one pad, built in */
	sms.Port2.Type = g_smsPort2 && g_machine != M_GG ? ControllerType::SmsController : ControllerType::None;
	sms.Region = region3Values[setting_choice("smsRegion", regions3, 3, 0)];
	sms.GameGearRegion = ConsoleRegion::Auto;
	sms.RamPowerOnState = ram_state(2);
	sms.Revision = SmsRevision::Compatibility;
	sms.AllowInvalidInput = false;
	sms.UseSgPalette = true;
	sms.GgBlendFrames = false;
	sms.NtscOverscan.Top = sms.NtscOverscan.Bottom = 24;
	sms.PalOverscan.Top = sms.PalOverscan.Bottom = 24;
	sms.GameGearOverscan.Top = sms.GameGearOverscan.Bottom = 48;
	sms.GameGearOverscan.Left = sms.GameGearOverscan.Right = 48;
	for (int i = 0; i < 4; i++)
		sms.ChannelVolumes[i] = 100;
	sms.FmAudioVolume = 100;
	static const char *const onOff[] = { "on", "off" };
	sms.EnableFmAudio = setting_choice("smsFm", onOff, 2, 0) == 0;
	s->SetSmsConfig(sms);

	CvConfig cv = s->GetCvConfig();
	cv.Port1.Type = ControllerType::ColecoVisionController;
	cv.Port2.Type = ControllerType::ColecoVisionController;
	cv.Region = region3Values[setting_choice("smsRegion", regions3, 3, 0)];
	cv.RamPowerOnState = ram_state(0);
	for (int i = 0; i < 4; i++)
		cv.ChannelVolumes[i] = 100;
	s->SetCvConfig(cv);

	WsConfig ws = s->GetWsConfig();
	ws.ControllerHorizontal.Type = ControllerType::WsController;
	ws.ControllerVertical.Type = ControllerType::WsControllerVertical;
	ws.Model = g_machine == M_WSC ? WsModel::Color : WsModel::Monochrome;
	ws.UseBootRom = setting_on("wsBootRom") != 0;
	ws.AutoRotate = true;
	ws.BlendFrames = false;
	ws.LcdAdjustColors = false; /* as the Game Boy Advance's: pow() */
	ws.LcdShowIcons = true;
	ws.AudioMode = WsAudioMode::Headphones;
	ws.Channel1Vol = ws.Channel2Vol = ws.Channel3Vol = ws.Channel4Vol = ws.Channel5Vol = 100;
	s->SetWsConfig(ws);
}

static void configure(EmuSettings *s)
{
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

	if (g_machine == M_NES)
		configure_nes(s);
	else
		configure_other(s);
}

/* ---- memory domains ---- */

struct Domain
{
	MemoryType type;
	const char *name;
};
static const Domain kDomainsNes[] = {
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
	{ MemoryType::None, NULL },
};
static const Domain kDomainsSnes[] = {
	{ MemoryType::SnesWorkRam, "WRAM" },
	{ MemoryType::SnesSaveRam, "Cart RAM" },
	{ MemoryType::SnesVideoRam, "VRAM" },
	{ MemoryType::SnesSpriteRam, "OAM" },
	{ MemoryType::SnesCgRam, "CGRAM" },
	{ MemoryType::SpcRam, "APU RAM" },
	{ MemoryType::Sa1InternalRam, "SA-1 IRAM" },
	{ MemoryType::GsuWorkRam, "GSU RAM" },
	{ MemoryType::Cx4DataRam, "Cx4 RAM" },
	{ MemoryType::DspDataRam, "DSP RAM" },
	{ MemoryType::St018WorkRam, "ST018 RAM" },
	{ MemoryType::BsxPsRam, "BS-X PSRAM" },
	{ MemoryType::BsxMemoryPack, "BS-X Memory Pack" },
	{ MemoryType::SufamiTurboSecondCartRam, "Sufami Turbo B RAM" },
	{ MemoryType::SnesPrgRom, "Cart ROM" },
	/* the Super Game Boy's Game Boy */
	{ MemoryType::GbWorkRam, "GB WRAM" },
	{ MemoryType::GbHighRam, "GB HRAM" },
	{ MemoryType::GbCartRam, "GB Cart RAM" },
	{ MemoryType::GbVideoRam, "GB VRAM" },
	{ MemoryType::GbSpriteRam, "GB OAM" },
	{ MemoryType::GbPrgRom, "GB Cart ROM" },
	{ MemoryType::None, NULL },
};
static const Domain kDomainsGb[] = {
	{ MemoryType::GbWorkRam, "WRAM" },
	{ MemoryType::GbHighRam, "HRAM" },
	{ MemoryType::GbCartRam, "Cart RAM" },
	{ MemoryType::GbVideoRam, "VRAM" },
	{ MemoryType::GbSpriteRam, "OAM" },
	{ MemoryType::GbBgPaletteRam, "BG Palette" },
	{ MemoryType::GbObjPaletteRam, "OBJ Palette" },
	{ MemoryType::GbPrgRom, "Cart ROM" },
	{ MemoryType::None, NULL },
};
static const Domain kDomainsGba[] = {
	{ MemoryType::GbaExtWorkRam, "EWRAM" },
	{ MemoryType::GbaIntWorkRam, "IWRAM" },
	{ MemoryType::GbaSaveRam, "Save RAM" },
	{ MemoryType::GbaVideoRam, "VRAM" },
	{ MemoryType::GbaSpriteRam, "OAM" },
	{ MemoryType::GbaPaletteRam, "Palette RAM" },
	{ MemoryType::GbaPrgRom, "Cart ROM" },
	{ MemoryType::GbaBootRom, "BIOS" },
	{ MemoryType::None, NULL },
};
static const Domain kDomainsPce[] = {
	{ MemoryType::PceWorkRam, "Work RAM" },
	{ MemoryType::PceSaveRam, "Backup RAM" },
	{ MemoryType::PceCdromRam, "CD RAM" },
	{ MemoryType::PceCardRam, "Card RAM" },
	{ MemoryType::PceAdpcmRam, "ADPCM RAM" },
	{ MemoryType::PceArcadeCardRam, "Arcade Card RAM" },
	{ MemoryType::PceVideoRam, "VRAM" },
	{ MemoryType::PceVideoRamVdc2, "VRAM 2" },
	{ MemoryType::PceSpriteRam, "SAT" },
	{ MemoryType::PceSpriteRamVdc2, "SAT 2" },
	{ MemoryType::PcePaletteRam, "Palette RAM" },
	{ MemoryType::PcePrgRom, "Card ROM" },
	{ MemoryType::None, NULL },
};
static const Domain kDomainsSms[] = {
	{ MemoryType::SmsWorkRam, "Work RAM" },
	{ MemoryType::SmsCartRam, "Cart RAM" },
	{ MemoryType::SmsVideoRam, "VRAM" },
	{ MemoryType::SmsPaletteRam, "Palette RAM" },
	{ MemoryType::SmsPrgRom, "Cart ROM" },
	{ MemoryType::SmsBootRom, "BIOS" },
	{ MemoryType::None, NULL },
};
static const Domain kDomainsWs[] = {
	{ MemoryType::WsWorkRam, "Work RAM" },
	{ MemoryType::WsCartRam, "Cart RAM" },
	{ MemoryType::WsCartEeprom, "Cart EEPROM" },
	{ MemoryType::WsInternalEeprom, "Internal EEPROM" },
	{ MemoryType::WsPrgRom, "Cart ROM" },
	{ MemoryType::WsBootRom, "Boot ROM" },
	{ MemoryType::None, NULL },
};

static const Domain *domains(void)
{
	switch (g_machine) {
	case M_NES: return kDomainsNes;
	case M_SNES: case M_SGB: return kDomainsSnes;
	case M_GB: case M_GBC: return kDomainsGb;
	case M_GBA: return kDomainsGba;
	case M_PCE: case M_SGX: case M_PCECD: return kDomainsPce;
	case M_SMS: case M_GG: case M_SG: case M_CV: return kDomainsSms;
	default: return kDomainsWs;
	}
}

static int domain_kind(int index)
{
	if (!g_emu)
		return -1;
	const Domain *d = domains();
	int found = 0;
	for (int k = 0; d[k].name != NULL; k++) {
		ConsoleMemoryInfo m = g_emu->GetMemory(d[k].type);
		if (m.Memory == nullptr || m.Size == 0)
			continue;
		if (found == index)
			return k;
		found++;
	}
	return -1;
}

static int is_rom_type(MemoryType t)
{
	switch (t) {
	case MemoryType::NesPrgRom: case MemoryType::NesChrRom: case MemoryType::SnesPrgRom:
	case MemoryType::GbPrgRom: case MemoryType::GbaPrgRom: case MemoryType::GbaBootRom:
	case MemoryType::PcePrgRom: case MemoryType::SmsPrgRom: case MemoryType::SmsBootRom:
	case MemoryType::WsPrgRom: case MemoryType::WsBootRom:
		return 1;
	default:
		return 0;
	}
}

/* ---- the game file ---- */

static int read_file(const char *name, std::vector<uint8_t> &out)
{
	FILE *f = fopen(name, "rb");
	if (f == NULL)
		return 0;
	uint8_t buf[65536];
	for (size_t n; (n = fread(buf, 1, sizeof buf, f)) > 0;)
		out.insert(out.end(), buf, buf + n);
	fclose(f);
	return 1;
}

static std::string lower_ext(const std::string &name)
{
	size_t dot = name.rfind('.');
	std::string ext = dot == std::string::npos ? "" : name.substr(dot);
	for (char &c : ext)
		c = (char)tolower((unsigned char)c);
	return ext;
}

/* The name Mesen must see the game under: Mesen picks the console (and the
 * Master System family's model) by the file's extension. A file whose own
 * extension already says this machine keeps its name; another is given
 * under the machine's. */
static std::string machine_name(const std::string &file)
{
	std::string ext = lower_ext(file);
	switch (g_machine) {
	case M_SNES:
		if (ext == ".sfc" || ext == ".smc" || ext == ".swc" || ext == ".fig" || ext == ".bs" || ext == ".st")
			return file;
		return "game.sfc";
	case M_SGB: case M_GB: case M_GBC:
		/* the model is the setting's, whatever the extension */
		return ext == ".gb" || ext == ".gbc" ? file : "game.gb";
	case M_GBA: return ext == ".gba" ? file : "game.gba";
	case M_PCE: case M_SGX: return ext == ".pce" || ext == ".sgx" ? file : "game.pce";
	case M_PCECD: return file;
	case M_SMS: return ext == ".sms" ? file : "game.sms";
	case M_GG: return ext == ".gg" ? file : "game.gg";
	case M_SG: return ext == ".sg" ? file : "game.sg";
	case M_CV: return ext == ".col" ? file : "game.col";
	case M_WS: case M_WSC: return ext == ".ws" || ext == ".wsc" ? file : "game.ws";
	default: return file;
	}
}

static ConsoleType machine_console(void)
{
	switch (g_machine) {
	case M_NES: return ConsoleType::Nes;
	case M_SNES: case M_SGB: return ConsoleType::Snes;
	case M_GB: case M_GBC: return ConsoleType::Gameboy;
	case M_GBA: return ConsoleType::Gba;
	case M_PCE: case M_SGX: case M_PCECD: return ConsoleType::PcEngine;
	case M_SMS: case M_GG: case M_SG: case M_CV: return ConsoleType::Sms;
	default: return ConsoleType::Ws;
	}
}

/* the clock the cartridges read: the start, and the frames since */
static void advance_clock(void)
{
	if (g_clockNum == 0)
		return;
	MesenVirtualClockMs = g_clockStartMs + (int64_t)(g_clockFrames * 1000 * g_clockDen / g_clockNum);
}

/* The game's file: the NES's cartridge is the slot "rom", another
 * machine's the slot "cart", the PC Engine CD's disc the slot "disc"; with
 * no slot map, the plain mount "rom" */
static const char *game_file(char *name, size_t size)
{
	static const char *const slots[] = { "rom", "cart", "disc" };
	for (const char *slot : slots)
		if (wbx_slot_count(slot) > 0 && wbx_slot_name(slot, 0, name, size) != NULL)
			return name;
	return "rom";
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

#include "snes-coprocessor.inc"

/* A PC Engine CD's disc needs the program of a card in the console's slot:
 * the Super CD-ROM System card 3.0 for almost every disc, the Games Express
 * card for the Games Express discs, which Mesen tells by 8 bytes at the
 * start of sector 0x10 (PceConsole::LoadFirmware). 1 for a Games Express
 * disc, 0 for another, -1 when the .cue cannot be read. */
static int pce_games_express(const char *cue)
{
	VirtualFile file{ std::string(cue) };
	DiscInfo disc = {};
	if (!CdReader::LoadCue(file, disc) || disc.Tracks.empty())
		return -1;
	if (disc.Tracks[0].Format == TrackFormat::Audio)
		return 0;
	static const uint8_t signature[8] = { 0x01, 0x43, 0x44, 0x30, 0x30, 0x31, 0x01, 0x00 };
	std::vector<uint8_t> data;
	disc.ReadDataSector(0x10, data);
	return data.size() >= sizeof signature && memcmp(data.data(), signature, sizeof signature) == 0;
}
static const char kSyscard3[] = "{\"id\": \"syscard3.pce\", \"display\": \"firmware.syscard3\", "
	"\"description\": \"firmware.syscard3.about\", \"name\": \"syscard3.pce\", \"size\": 262144, "
	"\"sha1\": \"79F5FF55DD10187C7FD7B8DAAB0B3FFBD1F56A2C\", \"nameHints\": [\"syscard\", \"super cd\"]}";
static const char kGecard[] = "{\"id\": \"gecard.pce\", \"display\": \"firmware.gecard\", "
	"\"description\": \"firmware.gecard.about\", \"name\": \"gecard.pce\", \"size\": 32768, "
	"\"sha1\": \"014881A959E045E00F4DB8F52955200865D40280\", \"nameHints\": [\"gecard\", \"games express\"]}";

/* What the core would choose before the game boots (Chimera's new-project
 * window asks it instead of Init, on the same mounts). A cartridge whose
 * header has the EPSM gets the EPSM's drums suggested, and with them the
 * rhythm ROM they play from. A cartridge with a plain header whose program
 * writes the EPSM's registers gets the EPSM in the expansion port as well.
 * Neither can be told of a game that reaches the chip only through $4016.
 * A Super NES cartridge with a chip that runs a program of its own (the
 * DSP-1 to 4, the ST010, ST011 and ST018) needs that program's ROM, which
 * is asked for as this game's firmware. */
ECL_EXPORT const char *SuggestSettings(void)
{
	static char answer[1024];
	char name[512];
	const char *file = game_file(name, sizeof name);
	static const char *const machines[M_COUNT] = { "nes", "snes", "sgb", "gb", "gbc", "gba", "pce", "sgx", "pcecd",
		"sms", "gg", "sg1000", "coleco", "ws", "wsc" };
	int machine = setting_choice("machine", machines, M_COUNT, M_NES);
	std::vector<uint8_t> d;
	FILE *f = fopen(file, "rb");
	if (f) {
		uint8_t buf[65536];
		for (size_t n; (n = fread(buf, 1, sizeof buf, f)) > 0 && d.size() < (16u << 20);)
			d.insert(d.end(), buf, buf + n);
		fclose(f);
	}
	if (machine == M_SNES) {
		const char *fw = snes_coprocessor_firmware(d.data(), d.size(), lower_ext(file) == ".bs");
		if (fw != NULL)
			snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.snes_chip\", \"firmware\": [%s]}", fw);
		else
			snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.snes_plain\"}");
		return answer;
	}
	if (machine == M_PCECD) {
		int ge = pce_games_express(file);
		if (ge < 0)
			snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.pce_no_cue\"}");
		else
			snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"%s\", \"firmware\": [%s]}",
				ge ? "suggest.pce_gecard" : "suggest.pce_syscard", ge ? kGecard : kSyscard3);
		return answer;
	}
	if (machine != M_NES) {
		snprintf(answer, sizeof answer, "{\"values\": {}, \"note\": \"suggest.nothing\"}");
		return answer;
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

/* the firmware Mesen wants for this machine and game, by its file name:
 * what the core says when one is missing, before Mesen only says the game
 * did not load */
static int need_file(const char *id, const char *error)
{
	FILE *f = fopen(id, "rb");
	if (f != NULL) {
		fclose(f);
		return 1;
	}
	snprintf(g_loadError, sizeof g_loadError, "%s" TEXT_ARG "%s", error, id);
	return 0;
}

ECL_EXPORT int Init(void)
{
	g_loadError[0] = 0;

	g_machine = setting_choice("machine", kMachineOptions, M_COUNT, M_NES);

	/* the sequence Mesen's "random" draws from; the seed is a setting, so a
	 * project that wants a different power-on state says so */
	MesenFixedRandom::Seed((uint64_t)wbx_setting_ulong("randomSeed", 0));

	/* the time of day the cartridges' clocks start at (patch 0009) */
	g_clockStartMs = (int64_t)wbx_setting_long("rtcStart", 946684800) * 1000;
	MesenVirtualClockMs = g_clockStartMs;
	g_clockFrames = 0;
	g_clockNum = g_clockDen = 0;

	FolderUtilities::SetHomeFolder(".");

	if (g_machine == M_NES) {
		std::string db(mesen_nes_db, mesen_nes_db_size);
		std::istringstream dbStream(db);
		GameDatabase::LoadGameDb(dbStream);
	}

	BaseControlManager::InputReadHook = on_input_read;

	if (g_machine == M_PCE || g_machine == M_SGX || g_machine == M_PCECD) {
		g_video = (uint32_t *)calloc((size_t)PCE_VIDEO_MAX_W * PCE_VIDEO_MAX_H, sizeof(uint32_t));
		g_videoMaxW = PCE_VIDEO_MAX_W;
		g_videoMaxH = PCE_VIDEO_MAX_H;
	}

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

	/* the saved game the project starts from, if it has one; the Super NES
	 * asks for it as .srm, every other console as .sav */
	g_battery = new shared_ptr<ChimeraBattery>(new ChimeraBattery());
	char saveName[512];
	int hasSave = wbx_slot_count("savedata") > 0 && wbx_slot_name("savedata", 0, saveName, sizeof saveName) != NULL;
	if (hasSave) {
		std::vector<uint8_t> &data = (*g_battery)->files[".sav"];
		if (!read_file(saveName, data)) {
			snprintf(g_loadError, sizeof g_loadError, "error.not_opened" TEXT_ARG "%s", saveName);
			return 0;
		}
		if (g_machine == M_SNES || g_machine == M_SGB)
			(*g_battery)->files[".srm"] = data;
	}
	g_emu->GetBatteryManager()->SetBatteryProvider(*g_battery);
	g_emu->GetBatteryManager()->SetBatterySink(*g_battery);

	/* the cartridge: the project slot's file, else the plain rom mount */
	char name[512];
	const char *file = game_file(name, sizeof name);
	FILE *f = fopen(file, "rb");
	if (f == NULL) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_file");
		return 0;
	}
	uint8_t head[16] = { 0 };
	size_t headLen = fread(head, 1, sizeof head, f);
	fclose(f);

	int loaded;
	if (g_machine == M_NES) {
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
		loaded = g_emu->LoadRom(VirtualFile(std::string(file)), VirtualFile());
	} else {
		/* the firmware Mesen cannot run without, said by name */
		std::string ext = lower_ext(file);
		if (g_machine == M_GBA && !need_file("gba_bios.bin", "error.no_gba_bios"))
			return 0;
		if (g_machine == M_CV && !need_file("bios.col", "error.no_coleco_bios"))
			return 0;
		static const char *const sgbModels[] = { "sgb2", "sgb1" };
		if (g_machine == M_SGB && !need_file(setting_choice("sgbModel", sgbModels, 2, 0) == 0 ? "SGB2.sfc" : "SGB1.sfc",
				"error.no_sgb_bios"))
			return 0;
		if (g_machine == M_SNES && ext != ".bs" && ext != ".st") {
			/* a chip that runs a program of its own: Mesen would load the
			 * game without it and the game would wait for the chip forever */
			std::vector<uint8_t> rom;
			read_file(file, rom);
			int chip = snes_chip(rom.data(), rom.size());
			if (chip >= 0 && !need_file(kSnesChips[chip].id, "error.no_snes_chip"))
				return 0;
		}
		if (g_machine == M_SNES && ext == ".bs" && !need_file("BS-X.bin", "error.no_bsx_bios"))
			return 0;
		if (g_machine == M_SNES && ext == ".st" && !need_file("SufamiTurbo.sfc", "error.no_sufami_bios"))
			return 0;
		if (g_machine == M_PCECD && ext != ".cue") {
			snprintf(g_loadError, sizeof g_loadError, "error.not_cue" TEXT_ARG "%s", file);
			return 0;
		}
		if (g_machine == M_PCECD) {
			int ge = pce_games_express(file);
			if (ge < 0) {
				snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", file);
				return 0;
			}
			if (!need_file(ge ? "gecard.pce" : "syscard3.pce", "error.no_pce_card"))
				return 0;
		}

		std::string given = machine_name(file);
		if (given == file) {
			loaded = g_emu->LoadRom(VirtualFile(given), VirtualFile());
		} else {
			g_gameData = new std::vector<uint8_t>();
			g_gameName = new std::string(given);
			read_file(file, *g_gameData);
			loaded = g_emu->LoadRom(VirtualFile(g_gameData->data(), g_gameData->size(), given), VirtualFile());
		}
	}
	if (!loaded) {
		snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", file);
		return 0;
	}
	if (g_emu->GetConsoleType() != machine_console()) {
		snprintf(g_loadError, sizeof g_loadError, g_machine == M_NES ? "error.not_nes" TEXT_ARG "%s" : "error.not_machine" TEXT_ARG "%s", file);
		return 0;
	}
	if (g_machine == M_NES && hasSave && g_emu->GetMemory(MemoryType::NesSaveRam).Size == 0) {
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

	if (g_machine != M_NES) {
		fprintf(stderr, "[mesen] machine %s\n", kMachineOptions[g_machine]);
		return 1;
	}

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
	if (index >= 0 && index < wire_count())
		g_buttons[index] = state != 0;
}

ECL_EXPORT int GetVsyncNumerator(void);
ECL_EXPORT int GetVsyncDenominator(void);

/* a power cycle of another machine: Mesen's own reloads the game by its
 * path, which a game given from memory does not have */
static void power_cycle(void)
{
	if (g_gameData != NULL)
		g_emu->LoadRom(VirtualFile(g_gameData->data(), g_gameData->size(), *g_gameName), VirtualFile(), false, true);
	else
		g_emu->PowerCycle();
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed;
	if (!g_emu)
		return;

	if (g_machine != M_NES) {
		const PadLayout &l = kLayouts[g_machine];
		int power = 0, reset = 0;
		for (int i = 0; i < l.consoleCount; i++) {
			if (l.console[i] == CON_POWER && g_buttons[i])
				power = 1;
			if (l.console[i] == CON_RESET && g_buttons[i])
				reset = 1;
		}
		if (power) {
			power_cycle();
			g_emu->RegisterInputProvider(g_input);
		} else if (reset)
			g_emu->Reset();

		g_emu->GetVideoDecoder()->SetDecodeEnabled(g_render != 0);
		g_nsamples = 0;
		uint32_t lagBefore = g_emu->GetLagCounter();
		g_emu->RunSingleFrame();
		g_inputRead = g_emu->GetLagCounter() == lagBefore;
		/* the cartridges' clocks move with the frames the machine has run */
		g_clockNum = (uint64_t)GetVsyncNumerator();
		g_clockDen = (uint64_t)GetVsyncDenominator();
		g_clockFrames++;
		advance_clock();
		return;
	}

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
static int machine_player_active(int player)
{
	switch (g_machine) {
	case M_SNES: case M_SGB:
		if (player == 0)
			return g_snesPort1 == SNES_PORT_GAMEPAD;
		if (player == 1)
			return g_snesPort2 != SNES_PORT_NONE;
		return g_snesPort2 == SNES_PORT_MULTITAP;
	case M_PCE: case M_SGX: case M_PCECD:
		return player == 0 ? g_pcePort != PCE_PORT_NONE : g_pcePort == PCE_PORT_MULTITAP;
	case M_SMS: case M_SG:
		return player == 0 || g_smsPort2;
	default:
		return player < kLayouts[g_machine].maxPlayers;
	}
}

ECL_EXPORT int IsButtonActive(int32_t index)
{
	if (g_machine != M_NES) {
		const PadLayout &l = kLayouts[g_machine];
		if (index < 0 || index >= wire_count())
			return 0;
		if (index < l.consoleCount)
			return 1;
		return machine_player_active((index - l.consoleCount) / l.padCount);
	}
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
	if (g_machine != M_NES)
		return 0;
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

/* The frame rate as a fraction, each console's from its own clocks (the
 * same rates Mesen's GetFps gives as decimals) */
static void vsync(int *num, int *den)
{
	if (!g_emu) {
		*num = 39375000;
		*den = 655171;
		return;
	}
	int pal = g_emu->GetRegion() != ConsoleRegion::Ntsc;
	switch (g_machine) {
	case M_NES:
		*num = pal ? 322445 : 39375000;
		*den = pal ? 6448 : 655171;
		return;
	case M_SNES: case M_SGB:
		/* 21477272.7 Hz / 357366 clocks; PAL 21281370 Hz / 425568 */
		*num = pal ? 21281370 : 236250000;
		*den = pal ? 425568 : 3931026;
		return;
	case M_GB: case M_GBC: case M_GBA:
		/* 4194304 Hz / 70224 clocks */
		*num = 4194304;
		*den = 70224;
		return;
	case M_PCE: case M_SGX: case M_PCECD: {
		/* 21477270 Hz / 1365 clocks a line / 262 or 263 lines (the VCE's) */
		PceConsole *pce = dynamic_cast<PceConsole *>(g_emu->GetConsoleUnsafe());
		int lines = pce != NULL ? (int)pce->GetVce()->GetState().ScanlineCount : 263;
		*num = 21477270;
		*den = 1365 * (lines > 0 ? lines : 263);
		return;
	}
	case M_SMS: case M_SG: case M_CV:
		if (pal) {
			/* 3546893 Hz / 228 clocks / 313 lines */
			*num = 3546893;
			*den = 228 * 313;
			return;
		}
		/* fallthrough */
	case M_GG:
		/* 3579545.45 Hz / 228 clocks / 262 lines */
		*num = 315000000;
		*den = 88 * 228 * 262;
		return;
	default: {
		/* 12000 lines a second, 159 lines a frame unless the game says */
		WsConsole *ws = dynamic_cast<WsConsole *>(g_emu->GetConsoleUnsafe());
		int lines = ws != NULL ? (int)ws->GetPpu()->GetScanlineCount() : 159;
		*num = 12000;
		*den = lines > 0 ? lines : 159;
		return;
	}
	}
}
ECL_EXPORT int GetVsyncNumerator(void)
{
	int n, d;
	vsync(&n, &d);
	return n;
}
ECL_EXPORT int GetVsyncDenominator(void)
{
	int n, d;
	vsync(&n, &d);
	return d;
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
	return k >= 0 ? domains()[k].name : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	int k = domain_kind(i);
	return k >= 0 ? (uint8_t *)g_emu->GetMemory(domains()[k].type).Memory : NULL;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	int k = domain_kind(i);
	return k >= 0 ? (int64_t)g_emu->GetMemory(domains()[k].type).Size : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i)
{
	int k = domain_kind(i);
	return k >= 0 && !is_rom_type(domains()[k].type);
}

/* ---- the buses ----
 * The NES: 0 "System Bus": the CPU's 64 KiB as the CPU sees it, read and
 * written through Mesen's debugger accessors (PeekRam and DebugWrite), which
 * have no side effects: reading $2002 does not clear the vertical blank, and
 * a write lands only in RAM and the cartridge's memory, never in a register.
 * 1 "PPU Bus": the picture chip's 16 KiB as it sees them - the cartridge's
 * pattern tables at $0000-$1FFF, the nametables at $2000-$3EFF (the
 * console's 2 KiB or the cartridge's, as the mapper wires them) and the
 * palette at $3F00-$3FFF - read and written through the same accessors
 * Mesen's debugger uses (DebugReadVram, DebugWriteVram), which do not
 * tell the mapper an address went by (no MMC3 scanline counter moves).
 *
 * The other machines: each CPU's address space as it sees it, through the
 * accessors Mesen's debugger reads and writes it with (its memory viewer's
 * "CPU memory"): the Super NES's 16 MiB (and the sound CPU's 64 KiB, and
 * for the Super Game Boy the Game Boy's 64 KiB), the Game Boy's 64 KiB, the
 * Game Boy Advance's 256 MiB (of which RAM Search covers the RAM), the PC
 * Engine's 64 KiB as its banks are set, the Master System's 64 KiB, the
 * WonderSwan's 1 MiB. */
enum BusKind { BUS_NES, BUS_NES_PPU, BUS_SNES, BUS_SPC, BUS_SGB_GB, BUS_GB, BUS_GBA, BUS_PCE, BUS_SMS, BUS_WS };
struct Bus
{
	BusKind kind;
	const char *name;
	int64_t size;
};
static const Bus kBusesNes[] = { { BUS_NES, "System Bus", 0x10000 }, { BUS_NES_PPU, "PPU Bus", 0x4000 } };
static const Bus kBusesSnes[] = { { BUS_SNES, "System Bus", 0x1000000 }, { BUS_SPC, "APU Bus", 0x10000 } };
static const Bus kBusesSgb[] = { { BUS_SNES, "System Bus", 0x1000000 }, { BUS_SPC, "APU Bus", 0x10000 }, { BUS_SGB_GB, "GB Bus", 0x10000 } };
static const Bus kBusesGb[] = { { BUS_GB, "System Bus", 0x10000 } };
static const Bus kBusesGba[] = { { BUS_GBA, "System Bus", 0x10000000 } };
static const Bus kBusesPce[] = { { BUS_PCE, "System Bus", 0x10000 } };
static const Bus kBusesSms[] = { { BUS_SMS, "System Bus", 0x10000 } };
static const Bus kBusesWs[] = { { BUS_WS, "System Bus", 0x100000 } };

static const Bus *buses(int *count)
{
	switch (g_machine) {
	case M_NES: *count = 2; return kBusesNes;
	case M_SNES: *count = 2; return kBusesSnes;
	case M_SGB: *count = 3; return kBusesSgb;
	case M_GB: case M_GBC: *count = 1; return kBusesGb;
	case M_GBA: *count = 1; return kBusesGba;
	case M_PCE: case M_SGX: case M_PCECD: *count = 1; return kBusesPce;
	case M_SMS: case M_GG: case M_SG: case M_CV: *count = 1; return kBusesSms;
	default: *count = 1; return kBusesWs;
	}
}

static const Bus *bus_at(int i)
{
	int n;
	const Bus *b = buses(&n);
	return g_emu != NULL && i >= 0 && i < n ? &b[i] : NULL;
}

static uint8_t bus_read(BusKind kind, uint32_t addr)
{
	IConsole *c = g_emu->GetConsoleUnsafe();
	switch (kind) {
	case BUS_NES: case BUS_NES_PPU: {
		NesConsole *nes = dynamic_cast<NesConsole *>(c);
		if (nes == NULL) return 0;
		return kind == BUS_NES ? nes->GetMemoryManager()->DebugRead((uint16_t)addr) : nes->DebugReadVram(addr & 0x3FFF);
	}
	case BUS_SNES: case BUS_SPC: case BUS_SGB_GB: {
		SnesConsole *snes = dynamic_cast<SnesConsole *>(c);
		if (snes == NULL) return 0;
		if (kind == BUS_SNES) return snes->GetMemoryManager()->Peek(addr);
		if (kind == BUS_SPC) return snes->GetSpc()->DebugRead((uint16_t)addr);
		Gameboy *gb = snes->GetCartridge()->GetGameboy();
		return gb != NULL ? gb->GetMemoryManager()->DebugRead((uint16_t)addr) : 0;
	}
	case BUS_GB: {
		Gameboy *gb = dynamic_cast<Gameboy *>(c);
		return gb != NULL ? gb->GetMemoryManager()->DebugRead((uint16_t)addr) : 0;
	}
	case BUS_GBA: {
		GbaConsole *gba = dynamic_cast<GbaConsole *>(c);
		return gba != NULL ? gba->GetMemoryManager()->DebugRead(addr) : 0;
	}
	case BUS_PCE: {
		PceConsole *pce = dynamic_cast<PceConsole *>(c);
		return pce != NULL ? pce->GetMemoryManager()->DebugRead((uint16_t)addr) : 0;
	}
	case BUS_SMS: {
		SmsConsole *sms = dynamic_cast<SmsConsole *>(c);
		return sms != NULL ? sms->GetMemoryManager()->DebugRead((uint16_t)addr) : 0;
	}
	case BUS_WS: {
		WsConsole *ws = dynamic_cast<WsConsole *>(c);
		return ws != NULL ? ws->GetMemoryManager()->DebugRead(addr) : 0;
	}
	}
	return 0;
}

static void bus_write(BusKind kind, uint32_t addr, uint8_t value)
{
	IConsole *c = g_emu->GetConsoleUnsafe();
	switch (kind) {
	case BUS_NES: case BUS_NES_PPU: {
		NesConsole *nes = dynamic_cast<NesConsole *>(c);
		if (nes == NULL) return;
		if (kind == BUS_NES)
			nes->GetMemoryManager()->DebugWrite((uint16_t)addr, value, true);
		else
			nes->DebugWriteVram((uint16_t)addr, value);
		return;
	}
	case BUS_SNES: case BUS_SPC: case BUS_SGB_GB: {
		SnesConsole *snes = dynamic_cast<SnesConsole *>(c);
		if (snes == NULL) return;
		if (kind == BUS_SNES) {
			snes->GetMemoryManager()->GetMemoryMappings()->DebugWrite(addr, value);
		} else if (kind == BUS_SPC) {
			snes->GetSpc()->DebugWrite((uint16_t)addr, value);
		} else {
			Gameboy *gb = snes->GetCartridge()->GetGameboy();
			if (gb != NULL) gb->GetMemoryManager()->DebugWrite((uint16_t)addr, value);
		}
		return;
	}
	case BUS_GB: {
		Gameboy *gb = dynamic_cast<Gameboy *>(c);
		if (gb != NULL) gb->GetMemoryManager()->DebugWrite((uint16_t)addr, value);
		return;
	}
	case BUS_GBA: {
		GbaConsole *gba = dynamic_cast<GbaConsole *>(c);
		if (gba != NULL) gba->GetMemoryManager()->DebugWrite(addr, value);
		return;
	}
	case BUS_PCE: {
		PceConsole *pce = dynamic_cast<PceConsole *>(c);
		if (pce != NULL) pce->GetMemoryManager()->DebugWrite((uint16_t)addr, value);
		return;
	}
	case BUS_SMS: {
		SmsConsole *sms = dynamic_cast<SmsConsole *>(c);
		if (sms != NULL) sms->GetMemoryManager()->DebugWrite((uint16_t)addr, value);
		return;
	}
	case BUS_WS: {
		WsConsole *ws = dynamic_cast<WsConsole *>(c);
		if (ws != NULL) ws->GetMemoryManager()->DebugWrite(addr, value);
		return;
	}
	}
}

ECL_EXPORT int GetBusCount(void)
{
	int n;
	buses(&n);
	return n;
}
ECL_EXPORT const char *GetBusName(int i) { const Bus *b = bus_at(i); return b ? b->name : NULL; }
ECL_EXPORT int64_t GetBusSize(int i) { const Bus *b = bus_at(i); return b ? b->size : 0; }
ECL_EXPORT int GetBusWritable(int i) { return bus_at(i) != NULL; }

ECL_EXPORT int PeekBus(int bus, int addr)
{
	const Bus *b = bus_at(bus);
	if (b == NULL || addr < 0 || addr >= b->size)
		return 0;
	return bus_read(b->kind, (uint32_t)addr);
}

ECL_EXPORT void PokeBus(int bus, int addr, int value)
{
	const Bus *b = bus_at(bus);
	if (b == NULL || addr < 0 || addr >= b->size)
		return;
	bus_write(b->kind, (uint32_t)addr, (uint8_t)value);
}

/* up to 64 KiB of a bus at once, into memory no savestate carries */
ECL_INVISIBLE static uint8_t g_busRead[0x10000];
ECL_EXPORT const uint8_t *ReadBus(int32_t bus, int64_t addr, int32_t len)
{
	const Bus *b = bus_at(bus);
	if (len > (int32_t)sizeof g_busRead)
		len = (int32_t)sizeof g_busRead;
	for (int32_t i = 0; i < len; i++) {
		int64_t a = addr + i;
		g_busRead[i] = (b != NULL && a >= 0 && a < b->size) ? bus_read(b->kind, (uint32_t)a) : 0;
	}
	return g_busRead;
}

/* What of a bus a search should cover: the Game Boy Advance's 256 MiB is
 * mostly nothing, so RAM Search covers its work RAM (EWRAM at 0x02000000,
 * IWRAM at 0x03000000) and the cartridge's save memory at 0x0E000000 */
ECL_INVISIBLE static int64_t g_busRanges[8];
ECL_EXPORT const int64_t *GetBusRanges(int32_t bus)
{
	const Bus *b = bus_at(bus);
	if (b == NULL || b->kind != BUS_GBA)
		return NULL;
	int64_t r[] = { 0x02000000, 0x40000, 0x03000000, 0x8000, 0x0E000000, 0x10000, 0, 0 };
	memcpy(g_busRanges, r, sizeof r);
	return g_busRanges;
}

/* ---- save data: what the cartridge keeps when the console is off ---- */
static MemoryType save_type(void)
{
	switch (g_machine) {
	case M_NES: return MemoryType::NesSaveRam;
	case M_SNES: case M_SGB: return MemoryType::SnesSaveRam;
	case M_GB: case M_GBC: return MemoryType::GbCartRam;
	case M_GBA: return MemoryType::GbaSaveRam;
	case M_PCE: case M_SGX: case M_PCECD: return MemoryType::PceSaveRam;
	case M_SMS: case M_GG: case M_SG: case M_CV: return MemoryType::SmsCartRam;
	default: {
		ConsoleMemoryInfo eeprom = g_emu->GetMemory(MemoryType::WsCartEeprom);
		return eeprom.Size > 0 ? MemoryType::WsCartEeprom : MemoryType::WsCartRam;
	}
	}
}
ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	if (!g_emu)
		return 0;
	ConsoleMemoryInfo m = g_emu->GetMemory(save_type());
	return m.Memory != nullptr && m.Size > 0 ? 1 : 0;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i)
{
	if (i != 0)
		return NULL;
	return "battery.sav";
}
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	return i == 0 && GetSaveDataFileCount() ? (int64_t)g_emu->GetMemory(save_type()).Size : 0;
}
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	return i == 0 && GetSaveDataFileCount() ? (const uint8_t *)g_emu->GetMemory(save_type()).Memory : NULL;
}

} /* extern "C" */
