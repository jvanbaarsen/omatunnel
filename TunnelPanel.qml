import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "jvb.omatunnel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property alias service: serviceImpl
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property string localPort: ""
  property string sshDestination: ""
  property string remoteHost: "127.0.0.1"
  property string remotePort: ""
  property string defaultDestination: ""
  property string defaultRemoteHost: "127.0.0.1"
  property string defaultPorts: "3000-3999,5173"
  property bool defaultDirty: false

  Connections {
    target: serviceImpl
    function onOnDemandChanged() {
      if (root.defaultDirty) return
      if (serviceImpl.onDemand.ssh_destination !== undefined) root.defaultDestination = serviceImpl.onDemand.ssh_destination
      if (serviceImpl.onDemand.remote_host !== undefined) root.defaultRemoteHost = serviceImpl.onDemand.remote_host
      if (serviceImpl.onDemand.ports !== undefined) root.defaultPorts = serviceImpl.onDemand.ports
    }
    function onOnDemandSaved() { root.defaultDirty = false }
  }

  function selectMapping(mapping) {
    localPort = String(mapping.local_port)
    sshDestination = mapping.ssh_destination
    remoteHost = mapping.remote_host
    remotePort = String(mapping.remote_port)
  }

  function clearMapping() {
    localPort = ""
    sshDestination = ""
    remoteHost = "127.0.0.1"
    remotePort = ""
  }

  function open() {
    controller.show()
    service.refresh()
  }

  function close() { controller.hide() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(hostWidget || root, direction)
    return false
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  TunnelService { id: serviceImpl }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      width: parent.width
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "OmaTunnel"
        meta: service.statusText
        detail: service.tunnels.length + " CONFIGURED PORT" + (service.tunnels.length === 1 ? "" : "S")
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Text { text: "󰅟"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display }
        }
        trailingControl: Component {
          Text {
            text: "󰑐"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: service.reconcile()
            }
          }
        }
      }

      Text {
        visible: service.error !== ""
        width: parent.width
        text: service.error
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: service.tunnels
        delegate: BorderSurface {
          required property var modelData
          width: parent.width
          implicitHeight: tunnelRow.implicitHeight + Style.space(18)
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          radius: Style.cornerRadius

          RowLayout {
            id: tunnelRow
            anchors.fill: parent
            anchors.margins: Style.space(9)
            spacing: Style.space(10)

            Text {
              text: modelData.state === "tunnel" ? "󰅟" : (modelData.state === "local" ? "󰛪" : "󰅙")
              color: modelData.state === "unavailable" ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text { text: "localhost:" + modelData.local_port; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
              Text { text: modelData.ssh_destination + " → " + modelData.remote_host + ":" + modelData.remote_port; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Text { text: modelData.state; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.capitalization: Font.AllUppercase }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.selectMapping(modelData)
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(7)
        Text { text: "DEFAULT ON-DEMAND DESTINATION"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
        Text { width: parent.width; text: "Used only when an allowed localhost port has no manual mapping or local listener."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        ConfigField { width: parent.width; label: "SSH HOSTNAME OR IP"; placeholder: "hermes.local or 192.168.1.20"; value: root.defaultDestination; onEdited: function(text) { root.defaultDirty = true; root.defaultDestination = text } }
        ConfigField { width: parent.width; label: "REMOTE HOST"; placeholder: "127.0.0.1"; value: root.defaultRemoteHost; onEdited: function(text) { root.defaultDirty = true; root.defaultRemoteHost = text } }
        ConfigField { width: parent.width; label: "ALLOWED PORTS"; placeholder: "3000-3999,5173"; value: root.defaultPorts; onEdited: function(text) { root.defaultDirty = true; root.defaultPorts = text } }
        ActionButton { text: service.busy ? "Saving…" : "Save Default"; enabled: !service.busy && root.defaultDestination !== "" && root.defaultRemoteHost !== "" && root.defaultPorts !== ""; onClicked: service.saveOnDemand(root.defaultDestination, root.defaultRemoteHost, root.defaultPorts) }
        Text { width: parent.width; text: "Saving automatically reloads the on-demand service."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
      }

      Text {
        visible: (service.onDemand.automatic || []).length > 0
        width: parent.width
        text: "AUTOMATIC ROUTES THIS SESSION"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }

      Repeater {
        model: service.onDemand.automatic || []
        delegate: BorderSurface {
          required property var modelData
          width: parent.width
          implicitHeight: automaticRow.implicitHeight + Style.space(18)
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          radius: Style.cornerRadius
          RowLayout {
            id: automaticRow
            anchors.fill: parent
            anchors.margins: Style.space(9)
            spacing: Style.space(10)
            Text { text: "󰅟"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text { text: "localhost:" + modelData.local_port; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
              Text { text: "Default → " + service.onDemand.ssh_destination + " → " + service.onDemand.remote_host + ":" + modelData.local_port; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Text { text: modelData.connections > 0 ? modelData.connections + " active" : "recent"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(7)

        Row {
          width: parent.width
          Text { text: "MANUAL TUNNEL OVERRIDE"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
          Item { width: parent.width - newMapping.implicitWidth - parent.children[0].implicitWidth; height: 1 }
          Text {
            id: newMapping
            text: "New mapping"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.clearMapping() }
          }
        }

        ConfigField { width: parent.width; label: "LOCAL URL / PORT"; placeholder: "3000"; value: root.localPort; onEdited: function(text) { root.localPort = text } }
        ConfigField { width: parent.width; label: "SSH DESTINATION"; placeholder: "development-server"; value: root.sshDestination; onEdited: function(text) { root.sshDestination = text } }
        ConfigField { width: parent.width; label: "REMOTE HOST"; placeholder: "127.0.0.1"; value: root.remoteHost; onEdited: function(text) { root.remoteHost = text } }
        ConfigField { width: parent.width; label: "REMOTE PORT"; placeholder: "3000"; value: root.remotePort; onEdited: function(text) { root.remotePort = text } }

        Row {
          spacing: Style.space(8)
          ActionButton {
            text: service.busy ? "Saving…" : "Save mapping"
            enabled: !service.busy && root.localPort !== "" && root.sshDestination !== "" && root.remoteHost !== "" && root.remotePort !== ""
            onClicked: service.saveMapping(root.localPort, root.sshDestination, root.remoteHost, root.remotePort)
          }
          ActionButton {
            visible: root.localPort !== ""
            text: "Remove"
            enabled: !service.busy
            onClicked: service.removeMapping(root.localPort)
          }
        }
      }

      Text {
        visible: service.tunnels.length === 0 && service.error === ""
        width: parent.width
        text: "Add your first mapping with the fields above, then press Save mapping."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        text: "Local apps always win. An unavailable remote service is deliberately left unbound, so localhost returns its normal connection error."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  component ConfigField: BorderSurface {
    id: field
    required property string label
    required property string placeholder
    property string value: ""
    signal edited(string text)
    onValueChanged: if (input.text !== value) input.text = value
    implicitHeight: fieldContent.implicitHeight + Style.space(12)
    color: Style.normalFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius

    Column {
      id: fieldContent
      anchors.fill: parent
      anchors.margins: Style.space(6)
      spacing: Style.space(2)
      Text { text: parent.parent.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
      TextInput {
        id: input
        width: parent.width
        color: root.foreground
        selectionColor: Color.accent
        selectedTextColor: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        selectByMouse: true
        clip: true
        onTextEdited: field.edited(text)
        Text { anchors.fill: parent; text: parent.text === "" ? parent.parent.parent.placeholder : ""; color: root.dim; font: parent.font; visible: parent.text === "" }
      }
    }
  }

  component ActionButton: BorderSurface {
    required property string text
    property bool enabled: true
    signal clicked()
    implicitWidth: buttonText.implicitWidth + Style.space(20)
    implicitHeight: buttonText.implicitHeight + Style.space(12)
    color: enabled ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.5
    Text { id: buttonText; anchors.centerIn: parent; text: parent.text; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
    MouseArea { anchors.fill: parent; cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; enabled: parent.enabled; onClicked: parent.clicked() }
  }
}
