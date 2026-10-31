# chimera-core-mesen: Mesen (MesenCE) in miniBox's sandbox, as a Chimera core.
#
# Native reference build (run-native and run-wbx; run-wbx links miniBox's
# host library out of its meson-cpp build dir):
#     meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
# Guest (core.wbx) build through the cross file waterbox/setup-guest.sh writes
# (needs miniBox's C++ guest toolchain, build/meson-cpp):
#     sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest core.wbx
#
# Both flavors compile the same upstream sources and the same
# waterbox/mesen.cpp; only emulibc.h differs (native-shim/ for the reference).
project('chimera-core-mesen', ['c', 'cpp'],
  default_options: ['c_std=gnu11', 'cpp_std=c++17', 'optimization=2', 'debug=false', 'warning_level=0'])

up = 'extern/MesenCE'

# the submodule pin is pristine upstream; overlay this repository's patches
# (all of them or none - see waterbox/apply-patches.sh)
run_command(files('waterbox/apply-patches.sh'), check: true)

mb = get_option('minibox_dir')
if mb == ''
  error('pass -Dminibox_dir=<miniBox checkout> (Chimera keeps it at extern/chimera-common-minibox)')
endif

# Build options Mesen's own makefile does not set, all of them this
# repository's patches: one thread (0001), a random sequence of our own
# (0002), a call at each read of the controls (0003), files named by their
# bare names in the folder "." (0004), saved games kept by the host (0005).
defs = [
  '-DNDEBUG',
  '-DMESEN_SINGLE_THREAD',
  '-DMESEN_FIXED_RANDOM',
  '-DMESEN_INPUT_READ_HOOK',
  '-DMESEN_BARE_PATHS',
  '-DMESEN_BATTERY_SINK',
]
add_project_arguments(defs + ['-fno-strict-aliasing', '-Wno-narrowing'], language: ['c', 'cpp'])

inc = include_directories(up, up / 'Core', up / 'Utilities', 'waterbox')

srcs = run_command(find_program('python3'), files('waterbox/list-sources.py'), meson.current_source_dir() / up,
  check: true).stdout().strip().split('\n')
core_sources = []
foreach s : srcs
  core_sources += files(up / s)
endforeach

db = custom_target('mesen-nes-db',
  input: up / 'UI/Dependencies/MesenNesDB.txt',
  output: 'mesen-nes-db.cpp',
  command: [find_program('python3'), files('waterbox/embed-db.py'), '@INPUT@', '@OUTPUT@'])

core_sources += [db, files('waterbox/mesen.cpp')]

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  # miniBox's musl/libstdc++ toolchain arrives through the cross file; the link
  # recipe is the C++ guest kit's (cxxglue for the unwinder, the pthread
  # functions libstdc++ declares weak pulled in by name).
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')

  executable('core', core_sources + files('waterbox/guest-syscalls.c'),
    name_suffix: 'wbx',
    include_directories: inc,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax', '-Wl,-z,stack-size=8388608',
      '-T', mbdir / 'source/guest/linkscript.T',
      '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
      '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
      '-Wl,-u,pthread_mutex_lock', '-Wl,-u,pthread_mutex_unlock',
      mbuild / 'source/guest/cxxglue.c.o',
      mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  m = meson.get_compiler('c').find_library('m', required: false)
  thr = dependency('threads')
  executable('run-native', core_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim'), inc],
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    cpp_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    dependencies: [m, thr])

  # the host library comes from the same miniBox build dir as the guest
  # toolchain: meson-cpp (-Dguest_cpp=true)
  mbhost = mb / 'build/meson-cpp/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host'],
    link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
endif
