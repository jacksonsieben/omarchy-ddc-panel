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
readonly PLUGIN_ID="$PREFIX.ddc"
readonly MONITOR_ID="$PREFIX.monitor"
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

say "Installing the $PLUGIN_ID plugin"
rm -rf "${PLUGINS_DIR:?}/$PLUGIN_ID"
mkdir -p "$PLUGINS_DIR/$PLUGIN_ID"
for file in manifest.json Service.qml PanelSection.qml; do
  sed "s|__PLUGIN_ID__|$PLUGIN_ID|g" "$SOURCE_DIR/plugin/$file" >"$PLUGINS_DIR/$PLUGIN_ID/$file"
done

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
  --arg source "$MONITOR_SOURCE_ID" '
    .id = $id |
    .name = "Display" |
    (if (.barWidget | type) == "object" then .barWidget.displayName = "Display" else . end) |
    .omarchy = ((if (.omarchy | type) == "object" then .omarchy else {} end) + { clonedFrom: $source }) |
    del(.omarchy.clonePaths)
  ' "$PLUGINS_DIR/$MONITOR_ID/manifest.json" >"$PLUGINS_DIR/$MONITOR_ID/manifest.json.tmp"
mv "$PLUGINS_DIR/$MONITOR_ID/manifest.json.tmp" "$PLUGINS_DIR/$MONITOR_ID/manifest.json"

say "Patching the cloned Panel.qml"
PLUGIN_ID="$PLUGIN_ID" \
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
        line("// Mounts the DDC controls from the companion plugin. All of the"),
        line("// logic lives there, so this clone stays small enough to rebuild"),
        line("// from a newer built-in panel without a merge."),
        line("Loader {"),
        line("  width: panelColumn.width"),
        line("  active: true"),
        line("  source: {"),
        line("    var registry = root.bar && root.bar.shell ? root.bar.shell.pluginRegistry : null"),
        line("    if (!registry || !registry.installedPlugins) return \"\""),
        line('    var manifest = registry.installedPlugins["%s"]' % plugin_id),
        line("    return manifest ? registry.entryPointUrl(manifest, \"panelSection\") : \"\""),
        line("  }"),
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
# A service plugin only loads when its id appears in shell.json. Bar widgets are
# enabled by being in the layout; services need this explicit entry.

if [[ -f $SHELL_CONFIG ]]; then
  if jq -e --arg id "$PLUGIN_ID" '(.plugins // []) | index($id)' "$SHELL_CONFIG" >/dev/null; then
    say "$PLUGIN_ID already enabled in shell.json"
  else
    say "Enabling $PLUGIN_ID in shell.json"
    tmp="$(mktemp "$SHELL_CONFIG.XXXXXX")"
    jq --arg id "$PLUGIN_ID" '.plugins = ((.plugins // []) + [$id] | unique)' "$SHELL_CONFIG" >"$tmp"
    chmod --reference="$SHELL_CONFIG" "$tmp"
    mv "$tmp" "$SHELL_CONFIG"
  fi
else
  warn "$SHELL_CONFIG does not exist yet; add \"$PLUGIN_ID\" to its plugins[] after first login"
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
