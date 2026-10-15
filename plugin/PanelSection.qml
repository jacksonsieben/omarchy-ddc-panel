import QtQuick
import QtQuick.Layouts
import qs.Ui
import qs.Commons

// DDC/CI controls, mounted into the Display panel by the cloned Panel.qml.
//
// One block per DDC-capable monitor: input source, contrast, and -- for panels
// identified as OLED -- a blank action. Monitors that do not speak DDC (laptop
// eDP, most of the time) never appear here, because offering controls that
// silently do nothing is worse than offering none.
//
// Mouse-driven by design. The Display panel's j/k cursor model lives in
// Panel.qml's visibleSections/sectionCount/activateCursor trio; teaching it
// about this section would mean editing all three, and the whole point of
// keeping the logic out here is that the clone stays a handful of lines that
// survive an Omarchy update. Clicking works; j/k walks past it.
Column {
  id: root

  // Set by the Loader in the cloned Panel.qml.
  property var panel: null

  readonly property var bar: panel ? panel.bar : null

  // The service id carries the install prefix, so it is stamped in at install
  // time rather than guessed here.
  readonly property string serviceId: "__PLUGIN_ID__"
  readonly property var ddc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(serviceId)
    : null

  readonly property var displays: ddc && ddc.displays ? ddc.displays : []

  spacing: Style.space(14)
  visible: displays.length > 0

  // Poll only while the panel is actually open, and refresh the moment it
  // opens so the values are not whatever they were minutes ago.
  Connections {
    target: root.panel
    ignoreUnknownSignals: true
    function onOpenedChanged() {
      if (!root.ddc) return
      root.ddc.watching = root.panel.opened === true
      if (root.panel.opened) root.ddc.refresh()
    }
  }

  Repeater {
    model: root.displays

    Column {
      id: block
      required property var modelData
      required property int index

      readonly property var display: modelData
      readonly property bool isOled: display && display.oled === true
      readonly property bool hasAssumedInputs: display && display.inputs
        ? display.inputs.some(function(i) { return i && i.assumed === true })
        : false

      width: root.width
      spacing: Style.space(10)

      PanelSeparator {
        foreground: root.bar.foreground
      }

      // ---------- Heading: model name, and whether we think it is OLED ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(ddcHeader.implicitHeight, oledTag.implicitHeight)

        PanelSectionHeader {
          id: ddcHeader
          text: (block.display.model || block.display.connector || "DISPLAY").toUpperCase()
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: oledTag
          textFormat: Text.PlainText
          visible: block.isOled
          text: "OLED"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // ---------- Input source ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: block.display.inputs && block.display.inputs.length > 0

        PanelSectionHeader {
          text: "INPUT"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // Wraps, because a monitor that reports its full capability string can
        // easily list more inputs than fit on one row.
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: block.display.inputs

            Button {
              required property var modelData

              text: modelData.label
              fontSize: Style.font.caption
              // Dimmed when the input is a guess rather than something the
              // monitor confirmed, so the ports that certainly exist read as
              // the primary choices.
              foreground: modelData.assumed === true
                ? Qt.darker(root.bar.foreground, 1.5)
                : root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              active: String(block.display.input || "").toLowerCase() === String(modelData.code).toLowerCase()

              onClicked: root.ddc.setInput(block.display.connector, modelData.code)
            }
          }
        }

        // Worth saying, because the failure is not recoverable from here.
        // Switching to a port the monitor does not actually have leaves it on
        // "no signal", and with the input switched away the monitor stops
        // answering DDC too -- so the way back is the monitor's own buttons,
        // not this panel.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          visible: block.hasAssumedInputs
          text: "Dimmed inputs are guesses: this monitor's firmware does not report a usable input list, so these are the standard set. Picking one it does not have leaves it on \"no signal\", recoverable only with the monitor's own buttons."
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---------- Contrast ----------
      //
      // Brightness is deliberately absent: Omarchy's own brightness slider
      // already drives VCP 10 through omarchy-brightness-display-ddc, and two
      // sliders writing the same feature would fight each other.
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: block.display.contrast !== null && block.display.contrast !== undefined

        Item {
          width: parent.width
          implicitHeight: Math.max(contrastHeader.implicitHeight, contrastValue.implicitHeight)

          PanelSectionHeader {
            id: contrastHeader
            text: "CONTRAST"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: contrastValue
            textFormat: Text.PlainText
            text: Math.round(contrastSlider.dragging ? contrastSlider.liveValue : (block.display.contrast || 0)) + "%"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: contrastSlider.implicitHeight + Style.spacing.controlGap

          PanelSlider {
            id: contrastSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: block.display.contrast || 0
            // Applied on release only. Every drag frame would otherwise be an
            // i2c write, and monitors answer those slowly enough that the
            // slider would lag behind the pointer.
            onReleased: function(v) { root.ddc.setContrast(block.display.connector, v) }
          }
        }
      }

      // ---------- OLED care ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: block.isOled

        PanelSectionHeader {
          text: "OLED CARE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Button {
          width: parent.width
          text: block.display.blanked ? "󰌵  Wake this display" : "󰹏  Blank this display"
          fontSize: Style.font.body
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.sm
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: block.display.blanked === true

          onClicked: root.ddc.toggleBlank(block.display.connector)
        }

        // Said plainly, because the alternative is a button that looks broken.
        // Hyprland's misc:key_press_enables_dpms and misc:mouse_move_enables_dpms
        // are on by default, and they wake every blanked monitor, not just the
        // one the input was meant for.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Turns this panel off. Your next keypress or mouse movement brings it straight back, so this is for stepping away rather than for keeping one screen dark while you work on another."
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
