# MIDI in LoopStudio

How MIDI gets in and out of the app, with cables, over the network, and with Ableton Link.
The architecture is in `architecture.md`, sections 9 and 11b. This page is the how-to.

## 1. What goes where

| Path | What travels | Where to set it |
|---|---|---|
| MIDI From (per MIDI track) | Notes and controllers from a device or a session into the track | Mixer strip of the track: device and channel |
| MIDI To (per MIDI track) | The track's notes to a hardware synth or a session, with a channel and a time shift in ms | Mixer strip of the track |
| MIDI clock out | Tempo, Start, Stop and the song position to one port | Settings > Audio > MIDI clock out |
| MIDI clock in | The app follows a device's clock and transport | Settings > Audio > MIDI clock in |
| Ableton Link | Tempo, beat grid, start and stop with every Link app on the network | Link button in the transport bar; start/stop sync in Settings > Audio |
| MIDI Learn | Knobs, faders and buttons of a controller mapped to controls in the app | Learn button in the transport bar (⌘⇧M) |

Link carries no notes and no audio. Notes over the network go through Network MIDI (section 3).
Audio over the network needs a driver that shows up as a sound card (section 4).

## 2. Cables and USB

A device that macOS sees is in the app. Settings > Audio lists the inputs under "MIDI inputs";
the mixer pickers show inputs and outputs. "Rescan Devices" refreshes the lists; a plugged device
also appears on its own.

Each MIDI track chooses its input under MIDI From: a device or "All", and a channel or "All".
Armed tracks get the notes. The Keys track receives from the computer keyboard too (the piano
icon in the transport bar).

MIDI To sends the track's clip notes and live input to a device. "Clip Ch" keeps the channel of the
note; Ch 1 to 16 forces one. The ms field shifts the notes earlier to make up for the device's own
latency. Stop sends note-offs for every note that is still held.

## 3. Network MIDI: notes to and from another Mac

macOS has Network MIDI built in (RTP-MIDI). A session is a MIDI device like any other, so once it
is on, it appears in MIDI From, MIDI To and the clock pickers. Live on the other Mac sees it the
same way. A wired network gives a few milliseconds of latency; Wi-Fi gives more and more jitter.

The setup lives in Audio MIDI Setup. The app cannot turn the session on itself: macOS ignores the
`MIDINetworkSession` API from a third-party process. Settings > Audio > Network MIDI shows the
sessions that are on and opens Audio MIDI Setup.

Do this on both Macs:

1. Open Audio MIDI Setup (Applications > Utilities, or the button in the app's settings).
2. Window > Show MIDI Studio (⌘2; on a German Mac: Fenster > MIDI-Studio einblenden). Click the
   Network button (the globe, "Netzwerk") in the toolbar. That opens "MIDI Network Setup"
   ("MIDI-Netzwerkkonfiguration").
3. Under "My Sessions" click + to make a session. Tick its checkbox. Give it a name, "LoopStudio"
   on this Mac, "Live" on the other.
4. Set "Who may connect to me" to "Anyone".
5. Both Macs now show each other under "Directory". On one Mac select the other and click
   "Connect". The connection shows under "Participants".

Then, in LoopStudio:

- Send a track to Live: MIDI To > the session name. In Live, set the track's MIDI From to the
  session and arm it.
- Receive from Live: MIDI From > the session name, arm the track. In Live, set the track's
  MIDI To to the session.
- Clock: the session can also be the clock port in Settings > Audio. With Link on, both apps
  already share the tempo and the transport, so leave the clock off.

If the Directory stays empty: both Macs must be on the same network, and the other Mac must
be allowed on the local network. Bonjour finds the sessions; a firewall rule that blocks
incoming connections to Audio MIDI Setup stops it.

"Driver error: [address]:5004 refused the connection request" ("Treiberfehler ... hat die
Verbindungsanfrage abgelehnt") means the other Mac's session is not ticked, or its "Who may
connect to me" is not "Anyone". Fix it there, or connect from that side.

Pick the RTP session, not "Network MIDI 2" ("Netzwerk MIDI 2", "UMP-Netzwerk"): that is the new
UMP network standard of macOS 26. It needs macOS 26 and a host that supports it on both ends,
and Live uses the classic ports.

Verified on 2026-10-29: Live on another MacBook sends notes to a LoopStudio track over the RTP
session "Netzwerk RTP-Sitzung 1", with Link keeping both on one grid.

## 4. Audio over the network

macOS has no network audio device out of the box. What works today, all as a sound card the
app selects in Settings > Audio:

- **AVB** over Ethernet (Audio MIDI Setup > Window > Show Network Device Browser). It needs
  AVB-capable Ethernet on both Macs: the built-in Ethernet port of a Mac mini, Mac Studio or Mac
  Pro, not a USB adapter.
- **Dante Virtual Soundcard** and similar drivers. Paid; they give channels on the network.
- **An own audio link** between two LoopStudio instances, clocked by Link, is not built. It is
  a real feature: packet loss, jitter buffers and the drift between two sound cards need handling.

## 5. Ableton Link

The Link button in the transport bar turns Link on; the number next to it is the peer count.
Settings > Audio has "Start/stop sync". Tempo goes both ways. Play starts on the shared bar.
With start/stop sync, Play and Stop here start and stop Live, and the other way round.

Two things to know:

- A peer that joins a session while the others already play reads "stopped": Link resets that
  state on a join and only passes on the next change. After a relaunch of the app, press Stop and
  Play once in Live. The app re-announces its own playing state when a peer appears, so Live
  joining while the app plays works without that.
- Link needs the macOS Local Network permission. Without it, the app sees peers on the same Mac
  but none on the network. On this Mac the prompt never appears and the app is not listed in
  System Settings, so `scripts/run-app.sh` starts the app from the shell, which runs under the
  terminal's grant.

The app's Link log shows peers, tempo and start/stop traffic:

```
/usr/bin/log stream --predicate 'subsystem == "app.loopstudio"'
```
