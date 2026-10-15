#!/bin/bash

# Installs the DDC controls into Omarchy's Display panel.
#
# Safe to re-run, and meant to be: the Display panel is a *clone* of Omarchy's
# built-in one, so it goes stale when Omarchy updates. Every run re-clones from
# the current built-in and re-applies the patch, which is how the clone picks up
# upstream fixes instead of freezing at whatever shipped the day it was made.

set -euo pipefail

readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
readonly PLUGINS_DIR="$HOME/.config/omarchy/plugins"
readonly SHELL_CONFIG="$HOME/.config/omarchy/shell.json"
readonly BIN_DIR="${OMARCHY_DDC_BIN_DIR:-$HOME/.local/bin}"

# The id prefix matches `omarchy plugin clone`, which names a personal plugin
# after the user. Overridable so the same repo can be installed under a chosen
# name rather than whatever the account happens to be called.
readonly PREFIX="${OMARCHY_DDC_PREFIX:-${USER:-$(id -un)}}"
readonly MONITOR_ID="$PREFIX.monitor"
# Up to v1 the service was a plugin of its own and PanelSection.qml reached it
# with `bar.shell.serviceFor()`. Omarchy limits a plugin shell to resolving the
# calling plugin's own service -- pluginOwnsTarget() in shell.qml -- and the
# section runs under the Display clone, so it got null back and the DDC block
# rendered empty with nothing in the log. Service and section now ship inside
# the clone itself; this id exists only to clean up what v1 installed.
readonly LEGACY_SERVICE_ID="$PREFIX.ddc"
readonly MONITOR_SOURCE_ID="omarchy.monitor"
readonly MONITOR_SOURCE_DIR="$OMARCHY_PATH/shell/plugins/panels/monitor"

readonly MARKER_BEGIN="// >>> omarchy-ddc-panel (generated; re-applied on install)"
readonly MARKER_END="// <<< omarchy-ddc-panel"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ preflight

command -v ddcutil >/dev/null 2>&1 || die "ddcutil is not installed (omarchy pkg add ddcutil)"
command -v jq      >/dev/null 2>&1 || die "jq is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
[[ -d $MONITOR_SOURCE_DIR ]] || die "built-in Display panel not found at $MONITOR_SOURCE_DIR"

if ! id -nG | tr ' ' '\n' | grep -qx i2c; then
  warn "$USER is not in the 'i2c' group; ddcutil will not reach your monitors."
  warn "Fix with:  sudo usermod -aG i2c \"$USER\"   (then log out and back in)"
fi

# ----------------------------------------------------------------------- cli

say "Installing omarchy-ddc into $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 755 "$SOURCE_DIR/bin/omarchy-ddc" "$BIN_DIR/omarchy-ddc"

case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) warn "$BIN_DIR is not on your PATH; the shell plugin will not find omarchy-ddc" ;;
esac

# -------------------------------------------------------------------- plugin

# ------------------------------------------------------- Display panel clone
#
# Rebuilt from the built-in every run. Anything hand-edited inside the clone is
# discarded, which is the trade: the clone stays current with Omarchy, and this
# repo stays the only place the customisation lives.

say "Cloning the built-in Display panel to $MONITOR_ID"
if [[ -e $PLUGINS_DIR/$MONITOR_ID && ! -f $PLUGINS_DIR/$MONITOR_ID/.omarchy-ddc-clone ]]; then
  die "$PLUGINS_DIR/$MONITOR_ID exists and was not created by this installer; move it aside first"
fi

rm -rf "${PLUGINS_DIR:?}/$MONITOR_ID"
mkdir -p "$PLUGINS_DIR/$MONITOR_ID"
cp -aL "$MONITOR_SOURCE_DIR/." "$PLUGINS_DIR/$MONITOR_ID/"
touch "$PLUGINS_DIR/$MONITOR_ID/.omarchy-ddc-clone"

# `clonedFrom` is what makes the shell treat this as a replacement for the
# built-in: it swaps into the built-in's existing slot in the bar layout and
# disables the original, instead of appearing alongside it.
jq \
  --arg id "$MONITOR_ID" \
  --arg source "$MONITOR_SOURCE_ID" \
  --slurpfile extra "$SOURCE_DIR/plugin/manifest-fragment.json" '
    .id = $id |
    .name = "Display" |
    (if (.barWidget | type) == "object" then .barWidget.displayName = "Display" else . end) |
    .omarchy = ((if (.omarchy | type) == "object" then .omarchy else {} end) + { clonedFrom: $source }) |
    del(.omarchy.clonePaths) |
    # `*` is a recursive merge, so entryPoints keeps the built-in panel entry
    # and gains ours. `kinds` is a list and is replaced outright, which is why
    # the fragment spells out bar-widget alongside service.
    . * ($extra[0] | del(._comment))
  ' "$PLUGINS_DIR/$MONITOR_ID/manifest.json" >"$PLUGINS_DIR/$MONITOR_ID/manifest.json.tmp"
mv "$PLUGINS_DIR/$MONITOR_ID/manifest.json.tmp" "$PLUGINS_DIR/$MONITOR_ID/manifest.json"

# After the clone, which wipes the directory first.
say "Installing the DDC service and panel section into $MONITOR_ID"
for file in Service.qml PanelSection.qml; do
  sed "s|__PLUGIN_ID__|$MONITOR_ID|g" "$SOURCE_DIR/plugin/$file" >"$PLUGINS_DIR/$MONITOR_ID/$file"
done

say "Patching the cloned Panel.qml"
# Via `env` rather than an assignment prefix: these names are readonly in this
# shell, and bash rejects a prefix assignment to a readonly variable even when
# it only ever applies to the child process.
env \
  PLUGIN_ID="$MONITOR_ID" \
  MARKER_BEGIN="$MARKER_BEGIN" \
  MARKER_END="$MARKER_END" \
  python3 - "$PLUGINS_DIR/$MONITOR_ID/Panel.qml" <<'PYTHON'
import os
import re
import sys

path = sys.argv[1]
plugin_id = os.environ["PLUGIN_ID"]
begin = os.environ["MARKER_BEGIN"]
end = os.environ["MARKER_END"]

source = open(path, encoding="utf-8").read()

# Re-applying onto an already-patched file: strip the old block first so the
# patch is idempotent even if the clone was somehow not rebuilt.
source = re.sub(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n",
    "",
    source,
    flags=re.DOTALL,
)

# Anchor: the trailing spacer Item that closes panelColumn. It is the last
# child of the column, so inserting before it puts the DDC block at the bottom
# of the panel, under the DISPLAYS list.
anchor = re.compile(
    r"\n(?P<indent>[ \t]*)Item \{\n"
    r"[ \t]*width: parent\.width\n"
    r"[ \t]*height: Style\.space\(4\)\n"
    r"[ \t]*\}\n"
)

match = anchor.search(source)
if not match:
    sys.exit(
        "omarchy-ddc-panel: could not find the panelColumn trailing spacer in "
        f"{path}.\nThe built-in Display panel has changed shape; the injection "
        "anchor in install.sh needs updating."
    )

indent = match.group("indent")


def line(text=""):
    return (indent + text).rstrip() if text else ""


block = "\n".join(
    [
        "",
        line(begin),
        line("// Mounts the DDC controls, which install.sh drops into this same"),
        line("// plugin directory."),
        line("//"),
        line("// A relative source, not a registry lookup: a scoped plugin shell"),
        line("// exposes no pluginRegistry, so entryPointUrl() resolved to an"),
        line("// empty string and the Loader rendered nothing, in silence. Same"),
        line("// file, same directory -- the relative path needs no host API."),
        line("Loader {"),
        line("  width: panelColumn.width"),
        line("  active: true"),
        line("  source: \"PanelSection.qml\""),
        line("  onLoaded: if (item) item.panel = root"),
        line("}"),
        line(end),
        "",
    ]
)

source = source[: match.start()] + block + source[match.start():]
open(path, "w", encoding="utf-8").write(source)
print(f"  patched {path}")
PYTHON

# ---------------------------------------------------------------- shell.json
#
# v1 added the standalone service to `plugins[]`, because a service-only plugin
# loads no other way. The service is part of the Display clone now, which is
# enabled by its slot in the bar layout, so that entry is stale and its plugin
# directory is gone -- leaving it behind makes the registry log a missing
# plugin on every start.

if [[ -f $SHELL_CONFIG ]]; then
  if jq -e --arg id "$LEGACY_SERVICE_ID" '
       any((.plugins // [])[]; (if type == "object" then .id else . end) == $id)
     ' "$SHELL_CONFIG" >/dev/null; then
    say "Dropping the retired $LEGACY_SERVICE_ID entry from shell.json"
    tmp="$(mktemp "$SHELL_CONFIG.XXXXXX")"
    jq --arg id "$LEGACY_SERVICE_ID" '
      .plugins = [ (.plugins // [])[]
                   | select((if type == "object" then .id else . end) != $id) ]
    ' "$SHELL_CONFIG" >"$tmp"
    chmod --reference="$SHELL_CONFIG" "$tmp"
    mv "$tmp" "$SHELL_CONFIG"
  fi
else
  warn "$SHELL_CONFIG does not exist yet; the plugin loads after first login"
fi

# ------------------------------------------------------- retire v1's plugin
#
# Disabled before the directory goes: a plugin that disappears while the shell
# still has it enabled strands an entry that `omarchy plugin disable` can no
# longer resolve.

if [[ -d $PLUGINS_DIR/$LEGACY_SERVICE_ID ]]; then
  say "Retiring $LEGACY_SERVICE_ID"
  omarchy plugin disable "$LEGACY_SERVICE_ID" >/dev/null 2>&1 || true
  rm -rf "${PLUGINS_DIR:?}/$LEGACY_SERVICE_ID"
fi

# --------------------------------------------------------------- live shell

if omarchy-shell shell ping >/dev/null 2>&1; then
  say "Telling the running shell to rescan"
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true

  # Swaps the clone into the built-in's slot in the bar. Harmless if it is
  # already there.
  omarchy plugin enable "$MONITOR_ID" >/dev/null 2>&1 || true

  # Qt caches compiled QML per URL, so changed plugin code only runs after the
  # whole process restarts -- a rescan alone is not enough.
  say "Restarting the shell"
  omarchy restart shell >/dev/null 2>&1 || warn "could not restart the shell; run 'omarchy restart shell' yourself"
else
  warn "no running Omarchy shell; the plugin loads at next login"
fi

say "Done. Open the Display panel in the bar to see the DDC controls."
say "From a terminal: omarchy-ddc list"
