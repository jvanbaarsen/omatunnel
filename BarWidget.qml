import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "jvb.omatunnel"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function injectPanel() {
    if (!panelLoader.item) return
    if ("bar" in panelLoader.item) panelLoader.item.bar = root.bar
    if ("anchorItem" in panelLoader.item) panelLoader.item.anchorItem = button
    if ("hostWidget" in panelLoader.item) panelLoader.item.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  onBarChanged: {
    injectPanel()
    Qt.callLater(injectPanel)
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("TunnelPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰅟"
    active: panelLoader.item && panelLoader.item.service.activeCount > 0
    tooltipText: panelLoader.item ? panelLoader.item.service.statusText : "OmaTunnel"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
