# Stream deck (Redragon SS552 / Mirabox N4 family)

Coucou drives a Redragon SS552 (USB `0200:3001`, a Mirabox N4 clone: 10 LCD keys, a 4-panel touch
strip, 4 knobs that also click) directly over USB. GitHub build only, off by default:
**Settings → General → Stream deck**.

Only one app can drive the deck: quit OpenDeck / StreamDock before turning it on.

## Layout

```
 ┌──────┬──────┬──────┬──────┬──────┐
 │  S1  │  S2  │  S3  │  S4  │  S5  │   S1-S8: live agent sessions (Mochi in the agent's color,
 ├──────┼──────┼──────┼──────┼──────┤          project, current step). Press: jump to its terminal.
 │  S6  │  S7  │  S8  │ Dict │ Rec  │   Dict: hold to dictate (Flow). Rec: start/stop the Notetaker.
 ├──────┴─┬────┴───┬──┴─────┬┴──────┤
 │ Plan   │Session │ Music  │ Mochi │   touch strip (tap = knob press, except Music: tap = next track)
 └───◯────┴───◯────┴───◯────┴───◯───┘
   bright.  select   volume   —        turn
   screens  jump     play/pause open Coucou   press
   on/off
```

**Permission request** (Claude Code, Codex…): the strip shows the command; the bottom row becomes
`Allow · Always · – · Terminal · Deny`. **Question** (AskUserQuestion): the strip shows the
question, the keys show the options, `Terminal` answers in the terminal.

Safety:
- A request ignores its keys for 0.8 s after it appears, so a press already on its way never answers it.
- A command too long to read whole on the strip (over 240 characters or 4 lines) gets Deny only.
- Plans (ExitPlanMode), multi-select and multi-question prompts are answered on the Mac.
- A decision carries the id of the request the deck showed; a late one is ignored.

## Code

`NotchBuddy/Sources/App/StreamDeck/`:

| File | What |
|---|---|
| `DeckProtocol.swift` | wire protocol: commands, image upload, input parsing (pure) |
| `DeckLayout.swift` | which tile goes on which screen, what each control does (pure) |
| `DeckDevice.swift` | IOHIDManager: find, read, write |
| `DeckRenderer.swift` | SwiftUI tiles → 180° JPEG |
| `DeckService.swift` | observes the app, redraws changed screens, performs actions |
| `DeckSettings.swift` | the switch in Settings → General |

Tests: `bash scripts/test-deck-protocol.sh` (runs anywhere `swiftc` does, CI included).
Log: `StreamDeck.log` next to Coucou's other logs.

## First run on a Mac

1. `cd NotchBuddy && xcodegen` (picks up the new files), then `./scripts/dev-install.sh`.
2. Quit any other deck app, plug in the deck, turn on Settings → General → Stream deck.
3. Check every control once. The knob-press vs touch-strip codes come from opendeck-akp05 and are
   not confirmed on the SS552: if pressing a knob acts like tapping the strip (or the reverse), swap
   the two groups in `DeckProtocol.parse`. Unknown codes are written to `StreamDeck.log`.

`tools/streamdeck/ss552_probe.py` (Linux, hidraw) paints every screen with its slot number and logs
raw input codes, to map a new model of the family.
