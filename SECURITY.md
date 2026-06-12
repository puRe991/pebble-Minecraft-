# Security Policy

## What Pebble is (and isn't)

Pebble is a fully offline, local, singleplayer macOS game:

- **Zero network access.** The app makes no network connections of any kind — no telemetry, no analytics, no update checks, no multiplayer. The only thing that touches the network is the `pebble update` shell command, which is just `git pull` on your own checkout.
- **No accounts, no credentials, no personal data.** Pebble stores worlds, settings, and keybinds under `~/Library/Application Support/Pebble/`.
- **No elevated privileges.** It's an ad-hoc-signed app running in a normal user session.

That makes the realistic threat model: **malicious files that you load into the game.**

## Attack surface

If you're auditing Pebble, these are the interesting places — all of them parse untrusted input:

| Surface | Where | Notes |
|---|---|---|
| Texture zip (bundled Faithful) | `Sources/Pebble/ResourcePacks.swift` | custom zip central-directory parser + raw-deflate via Apple's Compression framework; PNG decode via CoreGraphics. Only the bundled archive is read, but the parser still treats it as untrusted input |
| Save database | `Sources/PebbleCore/Game/Saves.swift` | SQLite blobs in a `VCK1` container with a JSON tail; decode paths bounds-check lengths and clamp out-of-range block/item ids rather than trusting them |
| Settings/keybinds | `Sources/PebbleCore/Game/Settings.swift` | plain JSON via `Codable` |

Hardening that already exists: chunk-blob decoding validates section lengths and clamps corrupted block ids to air; player-data loading repairs array sizes and drops out-of-range item ids; SQLite errors are surfaced and failed writes retried rather than ignored; the zip reader never writes outside its own buffers (it extracts to memory, not to disk paths from the archive).

## Reporting a vulnerability

If you find a way for a crafted save file or texture archive to do anything beyond crashing the game (memory corruption, code execution, file writes outside the support directory), please report it privately:

- **Email:** briangaoo2@gmail.com — subject line starting with `[pebble security]`
- Include: macOS version, a minimal reproducing file if possible, and what you observed.

Plain crashes / hangs from malformed files are ordinary bugs — file those as [regular GitHub issues](https://github.com/thebriangao/pebble/issues) with the offending file attached (the README lists what else to include). This is a beta; reports of every kind are incredibly welcome.

You can expect an acknowledgment within a few days. There's no bug bounty; you'll get credit in the changelog and my genuine thanks.

## Supported versions

Only the latest release is supported. There's no backporting; the fix ships in the next version.
