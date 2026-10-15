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
| **Per-monitor blanking** (DPMS, optional `D6` standby) | new |
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
omarchy-ddc blank HDMI-A-1            # DPMS off, this monitor only
omarchy-ddc blank HDMI-A-1 --standby  # and power it down over DDC, if supported
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
└── <user>.monitor/        clone of omarchy.monitor, rebuilt on every install
    ├── Panel.qml          + a small Loader block, injected between markers
    ├── Service.qml        ddcutil state, actions, MPRIS media signal
    └── PanelSection.qml   the UI
```

### Why it is one plugin and not two

Until v1 the logic lived in a second plugin, `<user>.ddc`, and `PanelSection.qml`
reached it with `bar.shell.serviceFor("<user>.ddc")`. Omarchy limits a plugin
shell to resolving the calling plugin's own service:

```qml
function pluginOwnsTarget(pluginId, requestedId) {
  return resolveEnabledId(requestedId) === caller
}
```

The section runs under the Display clone, so the lookup returned `null` and the
DDC block rendered as nothing — no error, no log line. Sharing one plugin id is
what makes the service reachable, so the service and the section now ship
inside the clone. `install.sh` retires `<user>.ddc` if it finds one.

`kinds` therefore reads `["bar-widget", "service"]`. Keeping `bar-widget` in it
matters beyond tidiness: the shell tests clone status by membership, so dropping
it would cost the clone its standing as a replacement for the built-in panel.

The same sandbox took a second thing with it. The injected Loader used to find
`PanelSection.qml` through `pluginRegistry.entryPointUrl()`, and a scoped plugin
shell exposes no `pluginRegistry` at all — so the source resolved to an empty
string and the Loader rendered nothing, again with no error. Now that the two
files sit in one directory, the Loader just names the file:

```qml
source: "PanelSection.qml"
```

which needs no host API and cannot be withdrawn by one.

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

Each OLED block gets a **Blank this display** button, which drives Hyprland's
per-monitor DPMS.

DDC standby (`VCP D6`) is the obvious candidate, and it is what the GNOME port
offers — but it is not trustworthy. The ASUS XG27AQDMGR this was developed
against accepts the write and quietly ignores it:

```
$ ddcutil --bus 3 setvcp D6 4
Verification failed for feature d6
    Try errors: DDCRC_VERIFY
```

With `--noverify`, which you want everywhere else for speed, that looks like
success. A blank button that silently does nothing is worse than no button.
DPMS works on every monitor, including the laptop eDP panel that speaks no DDC
at all, comes back instantly, and does not make the monitor re-scan its inputs
the way a standby cycle does.

`omarchy-ddc list` reports `"supportsStandby"` per monitor — determined by one
deliberately *verified* `D6` write, cached, since the answer never changes for a
given panel. Where it is `true`, `blank --standby` also powers the panel down
for the real power saving. `0x04` ("DPM off") is used rather than `0x05`
("power off"): `0x05` is a coin flip on real hardware, and plenty of panels will
not answer DDC again until you press their physical power button.

#### The one hazard worth knowing about

Hyprland's `dpms` dispatcher takes an **optional** monitor selector, and a
selector that fails to resolve leaves it `std::nullopt` — which means *every*
monitor:

```c
// src/config/lua/bindings/LuaBindingsDispatchers.cpp
std::optional<PHLMONITOR> mon = std::nullopt;
if (!lua_isnil(L, lua_upvalueindex(2))) {
    auto m = State::monitorState()->query()...run();
    if (m) mon = m;          // no else — a miss silently means "all"
}
```

So `omarchy-ddc` never dispatches a name without first confirming Hyprland has
a monitor by that name:

```
$ omarchy-ddc blank NOPE-1
omarchy-ddc: hyprland has no monitor named NOPE-1; refusing to dispatch
```

#### Blanking does not survive your next keypress

`misc:key_press_enables_dpms` and `misc:mouse_move_enables_dpms` are on by
default in Hyprland, and they wake **every** blanked monitor, not just the one
the input was aimed at. So a manual blank lasts until you next touch the
keyboard or mouse.

That makes the button useful for stepping away, and not useful for keeping one
screen dark while you keep working on another — which is the case the GNOME port
handles with an input-transparent overlay and a pointer warp. Doing the
equivalent here means turning those two options off while a partial blank is
held, and that carries a genuine lockout risk if the remaining lit monitor then
blanks on idle. It is deliberately not done.

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
- **Plenty of monitors report a useless input list.** `ddcutil capabilities`
  either fails outright where `getvcp`/`setvcp` work fine, or — worse — returns
  a list that is simply wrong: the ASUS XG27AQDMGR advertises `60(01 03)`,
  VGA-1 and DVI-1, on a panel that has neither while running on HDMI-2. Both
  are firmware quirks, not bugs here. A capability list that omits the input
  the monitor is *currently displaying* is treated as untrustworthy, and the
  input list falls back to the standard MCCS set (VGA/DVI/DisplayPort/HDMI)
  merged with whatever the monitor did say.

  Those fallback entries are guesses, so the panel dims them and `omarchy-ddc
  inputs` marks them `assumed`; only the live input is confirmed. Picking a
  port the monitor does not have leaves it on "no signal" — and with the input
  switched away it stops answering DDC, so the way back is the monitor's own
  buttons, not this panel. Vendor-specific codes such as USB-C never appear at
  all; switch to them with `omarchy-ddc input <target> 0x1b`.
- **Brightness is not duplicated here.** Omarchy's own slider already writes
  VCP 10, and two sliders writing the same feature would fight.

## Uninstall

```sh
omarchy plugin disable $USER.monitor
rm -rf ~/.config/omarchy/plugins/$USER.monitor
rm -f ~/.local/bin/omarchy-ddc
omarchy restart shell
```

Disable before deleting: a plugin directory that disappears while the shell
still has it enabled strands an entry that `omarchy plugin disable` can no
longer resolve.

Removing the `<user>.monitor` clone restores the built-in Display panel.

## License

[GPL-3.0](LICENSE), matching `ddcutil` and the sibling projects.
