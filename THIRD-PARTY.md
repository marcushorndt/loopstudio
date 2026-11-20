# Third-party code and what is not in this repository

LoopStudio is licensed under the GNU GPL, version 3 (see `LICENSE`). The licence follows from
Ableton Link and Rubber Band, which the app links as C++ targets.

## In this repository

| Part | Where | Licence |
|---|---|---|
| Ableton Link | `Sources/LinkBridge/link` (git submodule) | GPL v2 or later, with a proprietary option from Ableton |
| Rubber Band Library 4.0.0 | `Sources/RubberBandBridge/rubberband` (git submodule), for the Complex and Complex Pro warp modes | GPL v2 or later, with a commercial option from Particular Programs |
| Live Cut | `Sources/LoopStudioEngine/BuiltInCutter.swift`, a port of Livecut by Rémy Muller with the BBCut procedures of Nick Collins | GPL v2 or later |

## Plugins that LoopStudio hosts, kept in their own repositories

LoopStudio hosts Audio Units. It runs without any of these. The plugins are not part of this
repository and have their own licences:

| Plugin | Source | Licence | Note |
|---|---|---|---|
| Lemus machines (303, 808, 909, 101, Virus C, QuadraVerb GT) | https://github.com/lemus-dev/lemus | AGPL v3 | Needs ROM dumps that you supply yourself. Lemus ships none, and so does LoopStudio. |
| Gaze | private repository | not cleared for release | A port of a web app of unknown licence. Private use only. |
| Remote MIDI | https://git.marcushorndt.de/marcushorndt/remote-midi | own work | |

## Reference material

Third-party scripts used as the reference for the Gaze port are not in this repository. The
analysis in `docs/gaze-original-analysis.md` is our own text.
