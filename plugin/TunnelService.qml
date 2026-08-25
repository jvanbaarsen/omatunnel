import QtQuick
import Quickshell.Io

Item {
  id: root

  property var tunnels: []
  property var onDemand: ({})
  signal onDemandSaved()
  property string error: ""
  property bool busy: statusProcess.running || onDemandStatusProcess.running || reconcileProcess.running || configProcess.running
  readonly property int activeCount: tunnels.filter(function(tunnel) { return tunnel.state === "tunnel" }).length
  readonly property string statusText: {
    if (busy) return "OmaTunnel: checking configured ports"
    if (error !== "") return "OmaTunnel: " + error
    return "OmaTunnel: " + activeCount + " remote tunnel" + (activeCount === 1 ? "" : "s")
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
    if (!onDemandStatusProcess.running) onDemandStatusProcess.running = true
  }

  function reconcile() {
    if (!reconcileProcess.running) reconcileProcess.running = true
  }

  function saveMapping(localPort, destination, remoteHost, remotePort) {
    if (configProcess.running) return
    configAction = "save"
    configProcess.command = ["omatunnel", "set", localPort, destination, remoteHost, remotePort]
    configProcess.running = true
  }

  function removeMapping(localPort) {
    if (configProcess.running) return
    configAction = "remove"
    configProcess.command = ["omatunnel", "remove", localPort]
    configProcess.running = true
  }

  function saveOnDemand(destination, remoteHost, ports) {
    if (configProcess.running) return
    configAction = "save the Default destination"
    configProcess.command = ["omatunnel", "on-demand", "set", destination, remoteHost, ports]
    configProcess.running = true
  }


  function readStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      tunnels = parsed.tunnels || []
      error = parsed.error || ""
    } catch (parseError) {
      tunnels = []
      error = "The OmaTunnel helper did not return valid status"
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    command: ["omatunnel", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readStatus(text)
    }
    stderr: StdioCollector { id: statusError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = String(statusError.text || "OmaTunnel is not installed").trim()
    }
  }


  Process {
    id: reconcileProcess
    command: ["omatunnel", "reconcile"]
    stderr: StdioCollector { id: reconcileError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = String(reconcileError.text || "Could not refresh tunnels").trim()
      root.refresh()
    }
  }

  Process {
    id: onDemandStatusProcess
    command: ["omatunnel", "on-demand", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.onDemand = JSON.parse(String(text || "")) }
        catch (parseError) { root.onDemand = ({}) }
      }
    }
  }

  property string configAction: ""

  Process {
    id: configProcess
    command: []
    stdout: StdioCollector { id: configOutput; waitForEnd: true }
    stderr: StdioCollector { id: configError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.error = String(configError.text || configOutput.text || "Could not " + root.configAction + " this mapping").trim()
      } else {
        root.error = ""
        if (root.configAction === "save the Default destination") root.onDemandSaved()
        root.reconcile()
      }
      root.refresh()
    }
  }
}
