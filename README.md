# Dictation

Press a key, speak, press again: the audio is transcribed by Whisper on marvin's GPU,
pasted into the focused window, and Enter is pressed.

## server/ (marvin)

Lives in `~/whisper-server/` (venv in `.venv`, token in `token`).

- `server.py`: HTTP server, `POST /transcribe` with a 16 kHz mono 16-bit WAV and `Authorization: Bearer <token>`. Optional `?lang=en|zh`.
- `run.sh`: sets the CUDA library path and binds to marvin's Tailscale IP, port 8765.
- `whisper-server.service`: systemd user unit (`~/.config/systemd/user/`), lingering enabled.

## linux/ (XFCE, e.g. the Lenovo)

- `dictate` goes in `~/.local/bin/`. It needs `arecord`, `xclip`, `xprop` and `notify-send`, plus xdotool unpacked in `~/.local/opt/xdotool`.
- Shortcut: `xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print -s ~/.local/bin/dictate`
- Toshy must not remap PrtSc (the old `User PrtSc to F11` modmap was removed).

## mac/

- `build.sh` builds `/Applications/Dictate.app` and installs a LaunchAgent. Every rebuild resets its macOS permissions, so after each one re-grant Input Monitoring, Accessibility and Microphone.
- Triggers: a lone tap of right Command, right Option or Fn/Globe (the system's "Press globe
  key to" action is set to Do Nothing via `defaults write com.apple.HIToolbox AppleFnUsageType -int 0`),
  or F13 (Print Screen on a
  PC-layout keyboard, i.e. a Keychron in Win mode; in Mac mode the Keychron's PrtSc key sends
  Cmd+Shift+4, which can't be told apart from a real screenshot shortcut).
- If a terminal has Secure Keyboard Entry on (Ghostty turns it on at password prompts and it
  can stick), macOS hides key presses from every other app: F13 stops working while the
  modifier taps still do. The app shows a warning bubble after 15 s of that.
- Shift held at either tap: paste without pressing Return. Esc while recording: cancel.
- Log: `~/Library/Logs/Dictate.log`

## Token

Clients read `~/.config/dictate/token`, which must match `~/whisper-server/token` on marvin. It's not in this folder.
