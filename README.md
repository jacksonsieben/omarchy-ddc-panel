# Omarchy DDC Panel

Monitor input switching, contrast, and OLED blanking over **DDC/CI**, folded
into the Display panel Omarchy already has in its bar.

This is the Omarchy port of [gnome-ddc-panel][gnome] and
[cosmic-ddc-applet][cosmic]. It is deliberately the smallest of the three,
because Omarchy 4 already does a chunk of the job: `omarchy-brightness-display`
detects non-eDP monitors and drives **VCP 10** through
`omarchy-brightness-display-ddc`, so the brightness slider in the Display panel
is already a DDC slider. What was missing is everything else.

[gnome]: https://github.com/jacksonsieben/gnome-ddc-panel
[cosmic]: https://github.com/jacksonsieben/cosmic-ddc-applet

## What it adds

| | Where it comes from |
|---|---|
| **Input switching** (VCP `60`) | new |
| **Contrast** (VCP `12`) | new |
| **Per-monitor OLED blanking** (VCP `D6`) | new |
| Brightness (VCP `10`) | already in Omarchy — untouched |
| Idle blanking without locking | already handled by [Screen Off Only](#relationship-to-screen-off-only) |

It appears at the bottom of the existing Display panel, one block per
DDC-capable monitor. Monitors that do not speak DDC — laptop eDP panels,
nearly always — never appear, because controls that silently do nothing are
worse than no controls.

## Requirements

- Omarchy 4.x (the Quickshell `omarchy-shell` bar).
- `ddcutil`, and read/write access to `/dev/i2c-*`:

```sh
omarchy pkg add ddcutil
sudo usermod -aG i2c "$USER"    # then log out and back in
ddcutil detect --brief          # should list your external monitor
```

## Install

```sh
git clone https://github.com/jacksonsieben/omarchy-ddc-panel.git
cd omarchy-ddc-panel
./install.sh
```

Re-running `install.sh` is safe, and is the intended way to pick up an Omarchy
update — see [How the Display panel is extended](#how-the-display-panel-is-extended).

## The CLI

The shell plugin does nothing the CLI cannot, which is the point: when a
monitor refuses a command, you can reproduce it in a terminal without the shell
in the way.

```sh
omarchy-ddc list                      # JSON for every DDC display
omarchy-ddc input HDMI-A-1            # read the current input
omarchy-ddc input HDMI-A-1 0x0f       # switch to DisplayPort-1
omarchy-ddc contrast HDMI-A-1 75
omarchy-ddc blank HDMI-A-1            # DDC standby, this monitor only
omarchy-ddc wake HDMI-A-1
omarchy-ddc refresh                   # drop the detection cache
```

`target` is a Hyprland connector name, an i2c bus number, or omitted for the
focused monitor.

## How the Display panel is extended

Omarchy's Display panel is a first-party plugin, and its `Panel.qml` is ~930
lines. Forking that wholesale would mean owning a merge conflict every time
Omarchy touched it. So the split is:

```
~/.config/omarchy/plugins/
├── <user>.monitor/        clone of omarchy.monitor, rebuilt on every install
│   └── Panel.qml          + a ~14-line Loader block, injected between markers
└── <user>.ddc/            every line of actual logic lives here
    ├── Service.qml        ddcutil state, actions, MPRIS media signal
    └── PanelSection.qml   the UI
```

`install.sh` re-clones the Display panel **from the current built-in** on every
run and re-applies the injection. So after `omarchy update`, re-running the
installer brings the clone up to the new upstream panel rather than freezing it
at whatever shipped the day it was first installed.

The clone carries `omarchy.clonedFrom`, which is what makes the shell swap it
into the built-in's existing slot in the bar and disable the original, rather
than showing two Display icons.

Anything you hand-edit inside `<user>.monitor/` is discarded on the next
install. That is the trade for staying current; the customisation lives in this
repo instead.

### If Omarchy changes the panel's shape

The injection anchors on the trailing spacer `Item` that closes `panelColumn`.
If upstream removes it, the installer stops with a clear error rather than
producing a broken panel, and the anchor in `install.sh` needs updating.

## OLED care

### Blanking one monitor

Each OLED block gets a **Blank this display** button, which powers that panel
down over DDC/CI (`VCP D6` → `0x04`).

Blanking goes over DDC rather than Hyprland's DPMS on purpose. Hyprland's
`dpms` dispatcher takes an optional monitor selector, and when that selector
fails to resolve it silently falls back to **every** monitor:

```c
// src/config/lua/bindings/LuaBindingsDispatchers.cpp
std::optional<PHLMONITOR> mon = std::nullopt;
if (!lua_isnil(L, lua_upvalueindex(2))) {
    auto m = State::monitorState()->query()...run();
    if (m) mon = m;          // no else — a miss leaves nullopt
}
return Internal::checkResult(L, CA::dpms(action, mon));
```

For a feature whose entire job is "darken *this* screen", blacking out the
whole session on a selector miss is not an acceptable failure mode. `VCP D6`
addresses a single i2c bus by construction, so it cannot spill.

The trade-off is real: DDC standby takes a second or two to come back, and some
monitors re-scan their inputs on wake. `0x04` ("DPM off") is used rather than
`0x05` ("power off") because `0x05` is a coin flip on real hardware — plenty of
panels will not answer DDC again until you press their physical power button.

### Which monitors count as OLED

There is no field in EDID that says "this panel is OLED". EDID 1.4 has no
panel-technology entry, and the DisplayID block that does is absent from
essentially every desktop monitor shipping today. So detection matches the model
string each monitor advertises against known OLED-only product families — the
same table as the GNOME extension, ported to `bin/omarchy-ddc`.

It is deliberately conservative: it would rather miss an OLED than blank an LCD
nobody asked it to. `omarchy-ddc list` reports the verdict as `"oled": true|false`.

### Relationship to Screen Off Only

Idle blanking is **not** in this plugin. It is already handled by the
[Screen Off Only][screenoff] plugin, which holds Omarchy's idle service in
stay-awake and runs its own timer that only drives DPMS — the screen sleeps,
the session stays unlocked.

That is a better answer than what the GNOME and COSMIC ports do. They draw an
opaque black overlay because neither desktop could blank without locking; a
black OLED pixel is an unlit one, so it works, but it is a workaround. DPMS off
is the panel genuinely unpowered.

This plugin contributes one thing to that side: its service exposes
`mediaPlaying`, an MPRIS "is anything actually playing" signal. Screen Off Only
already respects session idle inhibitors, which covers video players and
presentation tools; MPRIS covers audio-only playback, which usually holds no
inhibitor because nobody minds the screen sleeping during music.

[screenoff]: https://github.com/jacksonsieben/omarchy-ansible

## IPC

```sh
omarchy-shell ddc status                    # JSON: displays, mediaPlaying
omarchy-shell ddc refresh
omarchy-shell ddc blank HDMI-A-1
omarchy-shell ddc input HDMI-A-1 0f
```

## Known limitations

- **No keyboard navigation.** The Display panel's `j`/`k` cursor model lives in
  three functions inside `Panel.qml` (`visibleSections`, `sectionCount`,
  `activateCursor`). Teaching it about this section means editing all three,
  which defeats the small-injection design. The section is mouse-driven; `j`/`k`
  walks past it.
- **`ddcutil capabilities` fails on plenty of monitors** even where
  `getvcp`/`setvcp` work fine — a known firmware quirk, not a bug here. The
  input list then falls back to the standard MCCS set
  (VGA/DVI/DisplayPort/HDMI). Vendor-specific codes such as USB-C will not
  appear; switch to them with `omarchy-ddc input <target> 0x1b`.
- **Brightness is not duplicated here.** Omarchy's own slider already writes
  VCP 10, and two sliders writing the same feature would fight.

## Uninstall

```sh
rm -rf ~/.config/omarchy/plugins/$USER.ddc ~/.config/omarchy/plugins/$USER.monitor
rm -f ~/.local/bin/omarchy-ddc
jq 'del(.plugins[] | select(. == "'"$USER"'.ddc"))' ~/.config/omarchy/shell.json | sponge ~/.config/omarchy/shell.json
omarchy restart shell
```

Removing the `<user>.monitor` clone restores the built-in Display panel.

## License

[GPL-3.0](LICENSE), matching `ddcutil` and the sibling projects.
