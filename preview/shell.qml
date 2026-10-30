import QtQuick
import Quickshell
import Quickshell.Io

// Touch preview: a live picture of what the Magic Mouse surface reports and what
// the daemon decides. Reads the daemon's probe socket
// ($XDG_RUNTIME_DIR/magic-mouse/probe.sock); run with `qs -p <this folder>`.
ShellRoot {
  id: shell

  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/magic-mouse/probe.sock"

  // geometry from the daemon's hello line
  property var rangeX: [-1100, 1258]
  property var rangeY: [-1589, 2047]
  property var rangeMajor: [0, 1020]
  property real unitsPerMm: 38
  property string model: ""
  property bool mouseConnected: false

  // live frame
  property var contacts: []
  property bool scrolling: false
  property bool coasting: false
  property bool moving: false
  property string axis: "y"
  property string why: ""
  property var log: []          // last decisions: [{t, why}]
  property real fps: 0
  property int frameCount: 0
  property real peakMajor: 0
  property real edgeMm: 6
  property real palmZone: 0.2

  function handle(line) {
    var o
    try { o = JSON.parse(line) } catch (err) { return }
    if (o.type === "hello") {
      if (o.x) rangeX = o.x
      if (o.y) rangeY = o.y
      if (o.major) rangeMajor = o.major
      if (o.res) unitsPerMm = o.res
      model = o.model || ""
      mouseConnected = true
      return
    }
    if (o.type === "disconnected") { mouseConnected = false; contacts = []; pending = null; return }
    frameCount++
    pending = o  // drawn by the 30 Hz timer; every decision still goes to the log below
    var cs = o.c || []
    for (var i = 0; i < cs.length; i++) peakMajor = Math.max(peakMajor, cs[i][3])
    if (o.why && o.why !== why) {
      var next = log.slice(-11)
      next.push({ t: new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss.zzz"), why: o.why })
      log = next
    }
    why = o.why || ""
  }

  property var pending: null
  Timer {  // the mouse reports up to ~90 Hz; redraw at 30 Hz
    interval: 33; repeat: true; running: true
    onTriggered: {
      var o = shell.pending
      if (!o) return
      shell.pending = null
      shell.contacts = o.c || []
      shell.scrolling = !!o.scroll
      shell.coasting = !!o.coast
      shell.moving = !!o.moving
      shell.axis = o.axis || "y"
      if (o.edge_mm !== undefined) shell.edgeMm = o.edge_mm
      if (o.palm !== undefined) shell.palmZone = o.palm
    }
  }

  Socket {
    id: probe
    path: shell.socketPath
    connected: true
    parser: SplitParser { onRead: function(data) { shell.handle(data) } }
    onConnectedChanged: if (!connected) { shell.mouseConnected = false; shell.contacts = [] }
  }
  Timer {  // reconnect while the daemon restarts
    interval: 1000; repeat: true; running: !probe.connected
    onTriggered: probe.connected = true
  }
  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: { shell.fps = shell.frameCount; shell.frameCount = 0 }
  }

  readonly property color bg: "#1e1e22"
  readonly property color fg: "#e8e6e3"
  readonly property color dim: "#8a8780"
  readonly property color surface: "#2c2c32"
  readonly property var roleColor: ({ grip: "#6b6b75", rest: "#5b8def", follow: "#e0a33a", palm: "#d0605a" })
  readonly property string mono: "JetBrainsMono Nerd Font"

  FloatingWindow {
    title: "Magic Mouse touch preview"
    implicitWidth: 720
    implicitHeight: 600
    color: shell.bg
    visible: true

    Row {
      anchors.fill: parent
      anchors.margins: 20
      spacing: 24

      // ---------- surface ----------
      Item {
        id: pad
        width: 300
        height: parent.height
        readonly property real spanX: shell.rangeX[1] - shell.rangeX[0]
        readonly property real spanY: shell.rangeY[1] - shell.rangeY[0]
        readonly property real scale: Math.min(width / spanX, (height - 30) / spanY)

        Rectangle {
          id: shellOutline
          width: pad.spanX * pad.scale
          height: pad.spanY * pad.scale
          anchors.horizontalCenter: parent.horizontalCenter
          radius: width * 0.4
          clip: true
          color: shell.surface
          border.color: shell.scrolling ? shell.roleColor.follow : "#44444c"
          border.width: shell.scrolling ? 3 : 1

          // edge zones (scroll.edge_mm from each side) and the palm zone at the back
          Rectangle { x: 0; width: shell.edgeMm * shell.unitsPerMm * pad.scale; height: parent.height; color: "#ffffff"; opacity: 0.05 }
          Rectangle { x: parent.width - width; width: shell.edgeMm * shell.unitsPerMm * pad.scale; height: parent.height; color: "#ffffff"; opacity: 0.05 }
          Rectangle { y: parent.height - height; width: parent.width; height: parent.height * shell.palmZone; color: shell.roleColor.palm; opacity: 0.10 }
          Text { anchors.top: parent.top; anchors.topMargin: 8; anchors.horizontalCenter: parent.horizontalCenter; text: "front"; color: shell.dim; font.family: shell.mono; font.pixelSize: 11 }
          Text { visible: shell.palmZone > 0; anchors.bottom: parent.bottom; anchors.bottomMargin: 8; anchors.horizontalCenter: parent.horizontalCenter; text: "palm zone"; color: shell.roleColor.palm; font.family: shell.mono; font.pixelSize: 11 }

          Repeater {
            model: shell.contacts
            delegate: Item {
              required property var modelData
              readonly property real major: modelData[3]
              readonly property real minor: modelData[4]
              // touch_major is a relative contact size (0..1020), not calibrated to position units;
              // the 0.25 factor only makes the circles roughly finger-sized on the drawing
              readonly property real dia: Math.max(10, major * pad.scale * 0.25)
              x: (modelData[1] - shell.rangeX[0]) * pad.scale - dia / 2
              y: (modelData[2] - shell.rangeY[0]) * pad.scale - dia / 2
              width: dia; height: dia
              Rectangle {
                anchors.centerIn: parent
                width: parent.dia
                height: Math.max(10, minor * pad.scale * 0.25)
                radius: width / 2
                color: shell.roleColor[modelData[5]] || shell.fg
                opacity: 0.35 + 0.65 * Math.min(1, major / Math.max(1, shell.rangeMajor[1] * 0.75))
              }
              Text {
                anchors.left: parent.right; anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(major)
                color: shell.fg; font.family: shell.mono; font.pixelSize: 12
              }
            }
          }
        }
        Text {
          anchors.top: shellOutline.bottom; anchors.topMargin: 6
          anchors.horizontalCenter: parent.horizontalCenter
          text: "y " + shell.rangeY[0] + " … " + shell.rangeY[1]
          color: shell.dim; font.family: shell.mono; font.pixelSize: 11
        }
      }

      // ---------- numbers ----------
      Column {
        width: parent.width - pad.width - 24
        spacing: 10

        Text {
          text: shell.probeState()
          color: shell.fg; font.family: shell.mono; font.pixelSize: 16; font.bold: true
          width: parent.width; elide: Text.ElideRight
        }
        Text {
          text: shell.fps + " frames/s   " + shell.contacts.length + " contact" + (shell.contacts.length === 1 ? "" : "s") + "   peak size " + Math.round(shell.peakMajor)
          color: shell.dim; font.family: shell.mono; font.pixelSize: 12
        }

        Rectangle {
          width: parent.width; height: 64; radius: 8
          color: shell.scrolling ? "#3a3020" : shell.surface
          Column {
            anchors.fill: parent; anchors.margins: 10; spacing: 4
            Text { text: shell.scrolling ? "SCROLLING (" + shell.axis + ")" : shell.coasting ? "GLIDING" : "NOT SCROLLING"; color: shell.scrolling ? shell.roleColor.follow : shell.fg; font.family: shell.mono; font.pixelSize: 14; font.bold: true }
            Text { text: shell.why || "–"; color: shell.fg; font.family: shell.mono; font.pixelSize: 12; width: parent.width; elide: Text.ElideRight }
          }
        }

        Text { text: "mouse moving: " + (shell.moving ? "yes" : "no"); color: shell.moving ? shell.roleColor.follow : shell.dim; font.family: shell.mono; font.pixelSize: 12 }

        Row {
          spacing: 14
          Repeater {
            model: [["follow", "followed"], ["rest", "resting"], ["grip", "edge"], ["palm", "palm"]]
            delegate: Row {
              required property var modelData
              spacing: 6
              Rectangle { width: 10; height: 10; radius: 5; color: shell.roleColor[modelData[0]]; anchors.verticalCenter: parent.verticalCenter }
              Text { text: modelData[1]; color: shell.dim; font.family: shell.mono; font.pixelSize: 11 }
            }
          }
        }

        Text { text: "SIZE PER CONTACT"; color: shell.dim; font.family: shell.mono; font.pixelSize: 11; font.bold: true; topPadding: 6 }
        Repeater {
          model: shell.contacts
          delegate: Item {
            required property var modelData
            width: parent.width; height: 16
            Rectangle {
              width: parent.width * Math.min(1, modelData[3] / Math.max(1, shell.rangeMajor[1]))
              height: 10; radius: 3; anchors.verticalCenter: parent.verticalCenter
              color: shell.roleColor[modelData[5]] || shell.fg
            }
            Text { anchors.right: parent.right; text: "#" + modelData[0] + "  " + modelData[3] + " × " + modelData[4]; color: shell.fg; font.family: shell.mono; font.pixelSize: 11 }
          }
        }

        Text { text: "DECISIONS"; color: shell.dim; font.family: shell.mono; font.pixelSize: 11; font.bold: true; topPadding: 6 }
        Repeater {
          model: shell.log.slice().reverse()
          delegate: Text {
            required property var modelData
            text: modelData.t + "  " + modelData.why
            color: shell.fg; font.family: shell.mono; font.pixelSize: 11
            width: parent.width; elide: Text.ElideRight
          }
        }
      }
    }
  }

  function probeState() {
    if (!probe.connected) return "Waiting for magic-mouse-daemon …"
    if (!mouseConnected) return "Daemon running, mouse not connected"
    return model || "Magic Mouse"
  }
}
