# Sounds go here

Drop audio files into these folders — the hook plays them round-robin (in
filename order), cycling through all of a folder's clips before repeating.

```
sounds/
├── needs/    🔔  Claude is blocked on you (permission prompt / idle input)
├── ready/    ✅  a turn finished cleanly — ready for your next message
├── fail/     ❌  a turn ended in an error
├── denied/   🚫  you denied a tool request
└── start/    🎬  a new session began
```

- Formats: `.wav`, `.ogg`, `.oga`, `.flac`. (`.mp3` won't play on the
  libsndfile-based players like `pw-play`/`paplay` — convert to `.wav`/`.ogg`.)
  **`.wav` is the only format that plays on all three platforms** — on Windows
  without `ffplay`, the built-in `Media.SoundPlayer` handles `.wav` and nothing
  else. Use `.wav` if you sync your sound set across machines.
- Put **as many files as you like** in a folder; they rotate. One file = it
  plays every time. **Empty folder = silent** for that event.
- Reset a folder's rotation by deleting its counter in `sounds/.rr/`.

## Where to get sounds

- **Free / CC0:** your system's freedesktop theme
  (`/usr/share/sounds/freedesktop/stereo/*.oga`), [Kenney audio
  packs](https://kenney.nl/assets?q=audio), [freesound.org](https://freesound.org).
- **Game voices** make this delightful — but they're **copyrighted**. Rip them
  only from a copy you legally own, for personal use, and **don't redistribute
  them**. That's why this project ships with no audio.
