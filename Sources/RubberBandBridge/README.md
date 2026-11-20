# RubberBandBridge

Rubber Band Library 4.0.0 by Particular Programs Ltd., built as a package target for the
Complex and Complex Pro warp modes. `rubberband/` is the Rubber Band repository as a git
submodule (`git submodule update --init --recursive` after a fresh clone), pinned at the tag
`v4.0.0`. `rb_bridge.cpp` compiles the library's single-file build
(`rubberband/single/RubberBandSingle.cpp`, vDSP FFT on Apple platforms) and adds one C call,
`rb_stretch_offline`, for an offline stretch with a key frame map. Complex uses the R2 engine,
Complex Pro the R3 engine.

Rubber Band is licensed under the GNU GPL v2 or later (`rubberband/COPYING`). That license
applies to LoopStudio as a whole when it is distributed. Particular Programs offers a commercial
license on request.
