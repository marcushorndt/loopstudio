# LinkBridge

Ableton Link, built as a package target. `link/` is the Link repository as a git submodule
(`git submodule update --init --recursive` after a fresh clone). Only `abl_link.cpp`, the C API,
is compiled; the rest of Link is header-only. `include/abl_link.h` is a copy of
`link/extensions/abl_link/include/abl_link.h`, because Swift needs the public header inside the
target. Refresh the copy when the submodule moves.

Link is licensed under the GNU GPL v2 or later (`link/LICENSE.md`). That license applies to
LoopStudio as a whole when it is distributed. Ableton offers a proprietary license on request.
