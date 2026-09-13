import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// DDC/CI monitor state for the Display panel.
//
// Everything this service does goes through the `omarchy-ddc` CLI rather than
// driving ddcutil directly, so the panel and a terminal see exactly the same
// behaviour -- when a monitor refuses a command, `omarchy-ddc input HDMI-A-1
// 0x0f` reproduces it without the shell in the way.
//
// The panel section binds to `displays`; it owns no state of its own.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  // [{ bus, connector, manufacturer, model, serial, oled, brightness,
  //    contrast, input, blanked, inputs: [{ code, label }] }]
  property var displays: []
  property bool loaded: false
  property bool refreshing: false
  property string lastError: ""

  // A refresh requested while one was already in flight. DDC reads are slow
  // enough that a user dragging a slider can easily outrun them, and
  // overlapping ddcutil calls on one bus provoke the retry storms that make
  // DDC feel unreliable.
  property bool refreshQueued: false

  readonly property var oledDisplays: displays.filter(function(d) { return d && d.oled })
  readonly property bool anyBlanked: displays.some(function(d) { return d && d.blanked })

  // ---------------------------------------------------------------- lookup

  function displayFor(connector) {
    for (var i = 0; i < displays.length; i++) {
      if (displays[i] && displays[i].connector === connector) return displays[i]
    }
    return null
  }

  function inputLabel(display, code) {
    if (!display || !display.inputs) return String(code || "")
    var wanted = String(code || "").toLowerCase()
    for (var i = 0; i < display.inputs.length; i++) {
      if (String(display.inputs[i].code).toLowerCase() === wanted)
        return display.inputs[i].label
    }
    return "0x" + wanted
  }

  // ---------------------------------------------------------------- refresh

  function refresh() {
    if (listProc.running) {
      root.refreshQueued = true
      return
    }
    root.refreshing = true
    listProc.running = true
  }

  Process {
    id: listProc
    command: ["omarchy-ddc", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "[]"))
          root.displays = Array.isArray(parsed) ? parsed : []
          root.lastError = ""
        } catch (e) {
          // A parse failure means the CLI died mid-output. Keep the previous
          // list rather than blanking the panel to "no monitors", which reads
          // as "your monitor disappeared" when it did no such thing.
          root.lastError = "could not read monitor state"
        }
        root.loaded = true
      }
    }
    onRunningChanged: {
      if (running) return
      root.refreshing = false
      if (root.refreshQueued) {
        root.refreshQueued = false
        root.refresh()
      }
    }
  }

  // ---------------------------------------------------------------- actions
  //
  // Writes update the local model first and re-read afterwards. The optimistic
  // update keeps the UI responsive over a bus that takes ~100ms to answer;
  // the re-read is what corrects it when the monitor quietly refused.

  function patchDisplay(connector, changes) {
    var next = []
    for (var i = 0; i < displays.length; i++) {
      var d = displays[i]
      if (d && d.connector === connector) {
        var copy = {}
        for (var key in d) copy[key] = d[key]
        for (var change in changes) copy[change] = changes[change]
        next.push(copy)
      } else {
        next.push(d)
      }
    }
    root.displays = next
  }

  function run(args, connector, optimistic) {
    if (optimistic && connector) root.patchDisplay(connector, optimistic)
    actionProc.command = ["omarchy-ddc"].concat(args)
    actionProc.running = true
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  function setInput(connector, code) {
    if (!connector || !code) return
    root.run(["input", connector, String(code)], connector, { input: String(code).toLowerCase() })
  }

  function setContrast(connector, percent) {
    if (!connector) return
    var value = Math.max(0, Math.min(100, Math.round(percent)))
    root.run(["contrast", connector, String(value)], connector, { contrast: value })
  }

  function blank(connector) {
    if (!connector) return
    root.run(["blank", connector], connector, { blanked: true })
  }

  function wake(connector) {
    if (!connector) return
    root.run(["wake", connector], connector, { blanked: false })
  }

  function toggleBlank(connector) {
    var display = root.displayFor(connector)
    if (!display) return
    if (display.blanked) root.wake(connector)
    else root.blank(connector)
  }

  // ------------------------------------------------------------- media guard
  //
  // Exposed for the idle side of OLED care. Blanking a panel that is in the
  // middle of playing something is the one blanking that is always wrong, and
  // an idle timer cannot see playback on its own: a video playing fullscreen
  // generates no input events at all.
  //
  // Two independent signals, because neither covers the other. A session idle
  // inhibitor catches video players and presentation tools that ask not to be
  // interrupted; MPRIS catches audio-only playback, which usually holds no
  // inhibitor because nobody minds the screen sleeping during music. The
  // screen-off plugin already respects inhibitors, so this adds the second.
  readonly property var players: Mpris.players ? Mpris.players.values : []

  readonly property bool mediaPlaying: {
    for (var i = 0; i < players.length; i++) {
      if (players[i] && players[i].isPlaying) return true
    }
    return false
  }

  // ------------------------------------------------------------------- poll
  //
  // Only while something is watching. DDC traffic is not free -- each read is
  // an i2c transaction the monitor's firmware has to service -- and a panel
  // nobody has open does not need fresh contrast values.
  property bool watching: false

  Timer {
    interval: 5000
    running: root.watching
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  IpcHandler {
    target: "ddc"

    function status(): string {
      return JSON.stringify({
        loaded: root.loaded,
        refreshing: root.refreshing,
        mediaPlaying: root.mediaPlaying,
        lastError: root.lastError,
        displays: root.displays
      })
    }

    function refresh(): string {
      root.refresh()
      return "refreshing"
    }

    function blank(connector: string): string {
      root.blank(connector)
      return "blanking " + connector
    }

    function wake(connector: string): string {
      root.wake(connector)
      return "waking " + connector
    }

    function input(connector: string, code: string): string {
      root.setInput(connector, code)
      return "switching " + connector + " to 0x" + code
    }
  }
}
