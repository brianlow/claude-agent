This is a container for running Claude Code with remote session on

It is using Apple Container tech
https://github.com/apple/container

## Troubleshooting

### macOS "allow container to access files…" popup on every run

This is a macOS privacy (TCC) prompt, not something Apple Container controls. It
fires because the mounts point at protected locations — the Obsidian vault lives
in iCloud Drive (`~/Library/Mobile Documents/...`) and the Bear dir lives in
Group Containers (`~/Library/Group Containers/...`).

To stop the prompt, grant **Full Disk Access** (System Settings → Privacy &
Security → Full Disk Access) to:

- `/usr/local/bin/container` (the CLI)
- The per-VM runtime helper that actually performs the mounts:
  `/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux`
  (in the file picker press **⌘⇧G** and paste this path — `libexec` is hidden by
  default)
- Your terminal app (Terminal.app / iTerm / Ghostty / VS Code) — whichever you
  launch `run-claude.sh` from

Then quit and relaunch the terminal app (FDA only takes effect on process
restart), and restart the helper so it picks up the new grant:

```sh
container system stop && container system start
```

Notes:

- A prompt worded **"…would like to access data from other apps"** is the Group
  Containers TCC class — i.e. the Bear mount. If you don't need Bear, removing
  its `--mount …/bear` line from `run-claude.sh` also makes that prompt go away.
- Clicking "Allow" on the iCloud Drive variant of the prompt often doesn't
  stick — Full Disk Access is the reliable fix.

