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
- Triggers: tap right Option, or F13 (PrtSc on PC-layout keyboards).
- Log: `~/Library/Logs/Dictate.log`

## Token

Clients read `~/.config/dictate/token`, which must match `~/whisper-server/token` on marvin. It's not in this folder.
