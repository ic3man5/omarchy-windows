import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Top-bar widget and keyboard/mouse window switcher that tracks running,
// minimized, and special-workspace windows across all workspace layouts.
Panel {
  id: root
  moduleName: "drebbe.windows"
  ipcTarget: "drebbe.windows"

  // Forward WidgetButton size so Bar.qml's WidgetHost never collapses this slot to 0x0.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  property int selectedIndex: 0
  property bool cursorActive: true
  property string filterMode: "all" // "all" | "ws:<id>" | "minimized"
  readonly property int rowHeight: Style.space(46)
  readonly property int rowSpacing: Style.space(4)

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(Commons.Color.popups.text, Commons.Color.accent)
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null

  // Resolve this bar's own monitor rather than always Hyprland.focusedMonitor.
  readonly property var monitor: {
    var monitorsRev = Hyprland.monitors.values.length
    var win = root.QsWindow.window
    var screen = win ? win.screen : null
    return (screen && Hyprland.monitorFor(screen)) || Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : ""
  readonly property int activeWorkspaceId: monitor && monitor.activeWorkspace
    ? monitor.activeWorkspace.id
    : (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1)

  property var blocks: ({})

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
    }
    root.blocks = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  readonly property int ownBlock: {
    var b = root.blocks[root.monitorName]
    if (b !== undefined) return b
    return root.activeWorkspaceId >= 1 ? Model.blockOf(root.activeWorkspaceId) : 0
  }

  // Self-contained disk icon index so desktop icons (e.g. Telegram) resolve even
  // when PluginShellApi withholds shell.appLibrary.
  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons ${XDG_DATA_HOME:-$HOME/.local/share}/icons $HOME/.local/share/flatpak/exports/share/icons /var/lib/flatpak/exports/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      '{',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null;',
      '  done;',
      '  [[ -d /usr/share/pixmaps ]] && find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null;',
      '} | awk \'/\\.svg$/ { print; next } { png[++n] = $0 } END { for (i = 1; i <= n; i++) print png[i] }\''
    ].join(" ")
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (!value) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined) root.pendingIconIndex[name] = value
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: if (!iconIndexScan.running) iconIndexScan.running = true
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { iconIndexDebounce.restart() }
  }

  readonly property var matchableEntries: {
    var values = DesktopEntries.applications.values || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      var exec = String(entry.execString || "")
      if (entry.runInTerminal || exec.indexOf("--app-id=") >= 0 || exec.indexOf("://") >= 0 || exec.indexOf("webapp") >= 0) {
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
      }
    }
    return out
  }

  property var entryCache: ({})
  onMatchableEntriesChanged: entryCache = ({})

  function entryForAppId(appId) {
    var id = String(appId || "").trim()
    if (!id) return null
    if (entryCache[id] !== undefined) return entryCache[id] ? DesktopEntries.byId(entryCache[id]) : null
    var entry = DesktopEntries.heuristicLookup(id)
    if (!entry) {
      var claimed = Model.claimingEntryId(id, root.matchableEntries)
      if (claimed) entry = DesktopEntries.byId(claimed)
    }
    if (!entry && id.indexOf("steam_app_") === 0) {
      entry = DesktopEntries.heuristicLookup(id.slice("steam_app_".length))
    }
    entryCache[id] = entry ? String(entry.id) : ""
    return entry || null
  }

  function resolveIconPath(icon) {
    var value = String(icon || "").trim()
    if (!value) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var found = root.iconIndex[value]
    if (found) return Util.fileUrl(found)
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : ""
  }

  function iconSourceFor(entry, appId) {
    var icon = ""
    if (entry && entry.icon) icon = entry.icon
    else if (appId === "org.omarchy.agent") icon = "foot"
    else if (String(appId).indexOf("steam_app_") === 0) icon = String(appId).slice("steam_app_".length)
    else icon = String(appId || "")
    var resolved = resolveIconPath(icon)
    if (resolved) return resolved
    if (appId === "org.omarchy.agent") return resolveIconPath("utilities-terminal")
    return ""
  }

  function appNameFor(entry, appId, title) {
    if (entry && entry.name) return String(entry.name)
    if (appId === "org.omarchy.agent") return strings.t("app.agentTerminal")
    if (String(appId).indexOf("steam_app_") === 0) return String(title || String(appId).slice("steam_app_".length))
    return String(title || appId || strings.t("app.unknownWindow"))
  }

  // Batched terminal process + cwd inspection when opened so identical `foot` rows
  // show distinct commands/directories without triggering a reactive loop.
  property var pidInfo: ({})
  property string activePidSignature: ""

  function terminalPidListFromToplevels() {
    var toplevels = Hyprland.toplevels.values || []
    var pids = []
    for (var i = 0; i < toplevels.length; i++) {
      var item = toplevels[i]
      var wl = item.wayland
      if (wl && wl.parent) continue
      var ipc = item.lastIpcObject || ({})
      var cls = String((wl && wl.appId) ? wl.appId : (ipc.class || ipc.initialClass || "")).toLowerCase()
      if (cls !== "org.omarchy.agent" && cls !== "foot" && cls !== "kitty" && cls !== "alacritty" && cls.indexOf("ghostty") < 0) continue
      var pid = ipc.pid !== undefined ? Number(ipc.pid) : 0
      if (pid > 0 && pids.indexOf(pid) === -1) pids.push(pid)
    }
    pids.sort(function(a, b) { return a - b })
    return pids
  }

  function pidInspectScript(pids) {
    if (!pids || pids.length === 0) return "true"
    return [
      'ps_out=$(ps -eo pid=,ppid=,args= 2>/dev/null);',
      'for p in ' + pids.join(" ") + '; do',
      '  child=$(printf "%s\\n" "$ps_out" | awk -v pp="$p" \'$2 == pp { print $1; exit }\');',
      '  [[ -z $child ]] && child=$p;',
      '  args=$(printf "%s\\n" "$ps_out" | awk -v id="$child" \'$1 == id { $1=""; $2=""; sub(/^ +/, ""); print; exit }\');',
      '  cwd=$(readlink -f "/proc/$child/cwd" 2>/dev/null || true);',
      '  printf "%s\\t%s\\t%s\\n" "$p" "$cwd" "$args";',
      'done'
    ].join(" ")
  }

  function parsePidOutput(rawText) {
    var next = ({})
    var lines = String(rawText || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 3) continue
      var pid = String(parts[0] || "").trim()
      var cwd = String(parts[1] || "").trim()
      var args = String(parts[2] || "").trim()
      if (!pid) continue
      var cwdBase = cwd ? (cwd === root.homeDir ? "~" : cwd.split("/").pop()) : ""
      var prog = args ? args.split(/\s+/)[0].split("/").pop() : ""
      var promptMatch = /--prompt-interactive\s+(.+)$/.exec(args)
      var hint = promptMatch ? promptMatch[1].replace(/^['"]|['"]$/g, "") : ""
      next[pid] = { prog: prog, cwd: cwdBase, hint: hint }
    }
    if (JSON.stringify(next) !== JSON.stringify(root.pidInfo)) {
      root.pidInfo = next
    }
  }

  Process {
    id: pidProc
    property string buffer: ""
    stdout: SplitParser { onRead: function(line) { pidProc.buffer += line + "\n" } }
    onStarted: buffer = ""
    onExited: {
      root.parsePidOutput(buffer)
      if (root.opened && root.terminalPidListFromToplevels().join(",") !== root.activePidSignature) {
        pidDebounce.restart()
      }
    }
  }

  Timer {
    id: pidDebounce
    interval: 150
    onTriggered: root.refreshTerminalPids(false)
  }

  function refreshTerminalPids(force) {
    if (!root.opened) return
    var pids = root.terminalPidListFromToplevels()
    var sig = pids.join(",")
    if (pids.length === 0) {
      root.activePidSignature = ""
      return
    }
    if (!force && sig === root.activePidSignature) return
    if (!pidProc.running) {
      root.activePidSignature = sig
      pidProc.command = ["bash", "-c", root.pidInspectScript(pids)]
      pidProc.running = true
    }
  }

  function inspectToplevel(item) {
    if (!item) return null
    var wl = item.wayland
    var ipc = item.lastIpcObject || ({})
    var appId = (wl && wl.appId) ? String(wl.appId) : String(ipc.class || ipc.initialClass || "")
    var itemWs = item.workspace
    var ipcWs = ipc.workspace
    var ws = itemWs || ipcWs
    var wsId = ws && ws.id !== undefined ? Number(ws.id) : -1
    var wsName = String((itemWs && itemWs.name) || (ipcWs && ipcWs.name) || "")
    var minimized = Model.isMinimizedWorkspace(wsName)
    var special = Model.isSpecialWorkspace(wsName)
    if (!minimized && !special && !(wsId >= 1)) return null
    if (wl && wl.parent && !minimized) return null
    var title = (wl && wl.title) ? String(wl.title) : String(ipc.title || ipc.initialTitle || appId)
    var address = Model.normalizeAddress(item.address || ipc.address)
    if (!appId && !title && !address) return null
    return {
      wl: wl,
      ipc: ipc,
      appId: appId,
      title: title,
      address: address,
      wsId: wsId,
      wsName: wsName,
      minimized: minimized,
      special: special
    }
  }

  // Lightweight bar counters evaluated continuously without rebuilding Repeater rows.
  readonly property var barCounts: {
    var toplevels = Hyprland.toplevels.values || []
    var total = 0
    var min = 0
    for (var i = 0; i < toplevels.length; i++) {
      var info = inspectToplevel(toplevels[i])
      if (!info) continue
      total++
      if (info.minimized) min++
    }
    return { total: total, minimized: min }
  }
  readonly property int totalCount: barCounts.total
  readonly property int minimizedCount: barCounts.minimized

  // Full window entries built while the panel is open (or fading out) to prevent background churn.
  readonly property var allWindows: {
    if (!root.opened && !panel.visible) return []
    var appsRev = DesktopEntries.applications.values.length
    var iconsRev = Object.keys(root.iconIndex).length
    var toplevels = Hyprland.toplevels.values || []
    var list = []
    for (var i = 0; i < toplevels.length; i++) {
      var info = inspectToplevel(toplevels[i])
      if (!info) continue
      var wl = info.wl
      var ipc = info.ipc
      var focusId = ipc.focusHistoryID !== undefined ? Number(ipc.focusHistoryID) : 9999
      var entry = info.appId ? root.entryForAppId(info.appId) : null
      list.push({
        address: info.address,
        appId: info.appId,
        appName: root.appNameFor(entry, info.appId, info.title),
        iconSource: root.iconSourceFor(entry, info.appId),
        title: info.title,
        workspaceId: info.wsId,
        workspaceName: info.wsName,
        minimized: info.minimized,
        special: info.special,
        activated: wl ? !!wl.activated : (focusId === 0),
        focusHistoryID: focusId,
        pid: ipc.pid !== undefined ? Number(ipc.pid) : 0,
        tags: Array.isArray(ipc.tags) ? ipc.tags : [],
        toplevel: wl || null
      })
    }
    return Model.disambiguateWindows(Model.sortWindows(list, root.activeWorkspaceId), root.pidInfo)
  }

  readonly property var workspaceTabs: (root.opened || panel.visible)
    ? Model.collectWorkspaceTabs(root.allWindows, root.activeWorkspaceId, root.ownBlock)
    : []

  readonly property var filterTabs: {
    if (!root.opened && !panel.visible) return []
    var windows = root.allWindows
    var minCount = 0
    for (var j = 0; j < windows.length; j++) {
      if (windows[j].minimized) minCount++
    }
    var tabs = [
      { id: "all", label: strings.t("tab.all").arg(Commons.I18n.formatNumber(windows.length)) }
    ]
    var wsTabs = root.workspaceTabs
    for (var i = 0; i < wsTabs.length; i++) {
      var wt = wsTabs[i]
      var wsNum = Commons.I18n.formatNumber(wt.slot >= 1 ? wt.slot : wt.workspaceId)
      var countNum = Commons.I18n.formatNumber(wt.count)
      var label = wt.sameBlock
        ? strings.t("tab.ws").arg(wsNum).arg(countNum)
        : strings.t("tab.wsMonitor").arg(Commons.I18n.formatNumber(wt.block + 1)).arg(wsNum).arg(countNum)
      tabs.push({ id: wt.id, label: label })
    }
    if (minCount > 0) {
      tabs.push({ id: "minimized", label: strings.t("tab.minimized").arg(Commons.I18n.formatNumber(minCount)) })
    }
    return tabs
  }

  readonly property var visibleWindows: (root.opened || panel.visible)
    ? Model.filterWindows(root.allWindows, root.filterMode)
    : []

  function hasFilterTab(modeId) {
    var tabs = root.filterTabs
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id === modeId) return true
    }
    return false
  }

  function ensureValidFilterMode() {
    if (!root.opened) return
    if (!root.hasFilterTab(root.filterMode)) root.filterMode = "all"
  }

  onAllWindowsChanged: {
    if (root.opened) pidDebounce.restart()
  }

  onMinimizedCountChanged: {
    if (minimizedCount === 0 && filterMode === "minimized") filterMode = "all"
  }

  onFilterTabsChanged: ensureValidFilterMode()

  onOpenedChanged: {
    if (opened) {
      Hyprland.refreshMonitors()
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
      cursorActive = true
      selectedIndex = 0
      refreshTerminalPids(true)
      Qt.callLater(function() {
        if (!root.opened) return
        root.ensureValidFilterMode()
        var flick = panel.loadedContent ? panel.loadedContent.listFlick : null
        if (flick) flick.contentY = 0
        root.ensureRowVisible(root.selectedIndex)
      })
    }
  }

  onVisibleWindowsChanged: {
    if (visibleWindows.length === 0) selectedIndex = 0
    else if (selectedIndex >= visibleWindows.length) selectedIndex = visibleWindows.length - 1
  }

  Timer {
    id: hyprRefreshDebounce
    interval: 50
    onTriggered: {
      Hyprland.refreshMonitors()
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
      if (root.opened) root.refreshTerminalPids(false)
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (
        name === "openwindow" ||
        name === "closewindow" ||
        name === "movewindow" ||
        name === "movewindowv2" ||
        name === "workspacev2" ||
        name === "moveworkspacev2" ||
        name === "changeworkspaceid" ||
        name === "focusedmon" ||
        name === "focusedmonv2" ||
        name === "activespecial" ||
        name === "activespecialv2" ||
        name === "fullscreen"
      ) {
        hyprRefreshDebounce.restart()
      } else if (root.opened && (name === "activewindow" || name === "activewindowv2" || name === "windowtitlev2")) {
        hyprRefreshDebounce.restart()
      }
    }
  }

  Component.onCompleted: iconIndexScan.running = true
  Component.onDestruction: {
    if (root.opened) root.close()
    iconIndexScan.running = false
    pidProc.running = false
  }

  function runCommand(cmd) {
    if (root.bar) root.bar.run(cmd)
    else Quickshell.execDetached(["bash", "-lc", cmd])
  }

  function focusOrRestoreWindow(win) {
    if (!win) return
    var address = Model.normalizeAddress(win.address)
    if (!address) {
      if (win.toplevel && typeof win.toplevel.activate === "function") win.toplevel.activate()
      root.close()
      return
    }
    var target = 'window = "address:' + address + '"'
    var steps = []
    var after = []

    if (win.special) {
      var specialName = Model.specialWorkspaceShortName(win.workspaceName)
      if (/^[A-Za-z0-9_-]+$/.test(specialName)) {
        steps.push('hl.dsp.workspace.toggle_special("' + specialName + '")')
      }
    } else if (win.minimized) {
      var targetWs = root.activeWorkspaceId >= 1
        ? root.activeWorkspaceId
        : Model.minimizedOriginWorkspace(win.tags)
      if (!(targetWs >= 1)) {
        root.close()
        return
      }
      steps.push('hl.dsp.window.set_prop({ prop = "no_anim", value = "1", ' + target + ' })')
      var tags = win.tags || []
      for (var i = 0; i < tags.length; i++) {
        var t = String(tags[i] || "")
        if (/^omarchy-minimized-from-[0-9]+$/.test(t)) {
          steps.push('hl.dsp.window.tag({ tag = "-' + t + '", ' + target + ' })')
        }
      }
      steps.push('hl.dsp.window.move({ workspace = "' + targetWs + '", ' + target + ' })')
      after.push('hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", ' + target + ' })')
    }

    steps.push('hl.dsp.focus({ ' + target + ' })')
    steps.push('hl.dsp.window.alter_zorder({ mode = "top", ' + target + ' })')

    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var cmd = steps.map(dispatch).join(" && ")
    if (after.length > 0) cmd += "; sleep 0.4; " + after.map(dispatch).join("; ")
    runCommand(cmd)
    hyprRefreshDebounce.restart()
    root.close()
  }

  function restoreAllMinimized() {
    var steps = []
    var after = []
    var firstTarget = ""
    for (var i = 0; i < allWindows.length; i++) {
      var w = allWindows[i]
      if (!w.minimized) continue
      var targetWs = root.activeWorkspaceId >= 1
        ? root.activeWorkspaceId
        : Model.minimizedOriginWorkspace(w.tags)
      if (!(targetWs >= 1)) continue
      var address = Model.normalizeAddress(w.address)
      if (!address) continue
      var target = 'window = "address:' + address + '"'
      if (!firstTarget) firstTarget = target
      steps.push('hl.dsp.window.set_prop({ prop = "no_anim", value = "1", ' + target + ' })')
      var tags = w.tags || []
      for (var j = 0; j < tags.length; j++) {
        var t = String(tags[j] || "")
        if (/^omarchy-minimized-from-[0-9]+$/.test(t)) {
          steps.push('hl.dsp.window.tag({ tag = "-' + t + '", ' + target + ' })')
        }
      }
      steps.push('hl.dsp.window.move({ workspace = "' + targetWs + '", ' + target + ' })')
      after.push('hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", ' + target + ' })')
    }
    if (steps.length > 0) {
      if (firstTarget) steps.push('hl.dsp.focus({ ' + firstTarget + ' })')
      var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
      var cmd = steps.map(dispatch).join("; ") + "; sleep 0.4; " + after.map(dispatch).join("; ")
      runCommand(cmd)
      hyprRefreshDebounce.restart()
    }
    root.close()
  }

  function closeWindow(win) {
    if (!win) return
    if (win.toplevel && typeof win.toplevel.close === "function") {
      win.toplevel.close()
    } else {
      var address = Model.normalizeAddress(win.address)
      if (address) runCommand("hyprctl dispatch " + Util.shellQuote('hl.dsp.window.close({ window = "address:' + address + '" })'))
    }
    hyprRefreshDebounce.restart()
  }

  function ensureRowVisible(idx) {
    var flick = panel.loadedContent ? panel.loadedContent.listFlick : null
    if (!flick || idx < 0 || idx >= root.visibleWindows.length || flick.height <= 0) return
    var rowTop = idx * (root.rowHeight + root.rowSpacing)
    var rowBottom = rowTop + root.rowHeight
    if (rowTop < flick.contentY) flick.contentY = rowTop
    else if (rowBottom > flick.contentY + flick.height) flick.contentY = rowBottom - flick.height
  }

  function moveCursor(delta) {
    var count = visibleWindows.length
    if (count === 0) return
    cursorActive = true
    selectedIndex = (selectedIndex + delta + count) % count
    ensureRowVisible(selectedIndex)
  }

  function cycleFilter(delta) {
    var tabs = root.filterTabs
    if (tabs.length === 0) return
    var idx = -1
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].id === filterMode) {
        idx = i
        break
      }
    }
    if (idx < 0) idx = 0
    filterMode = tabs[(idx + delta + tabs.length) % tabs.length].id
    selectedIndex = 0
    ensureRowVisible(0)
  }

  function activateSelected() {
    if (!cursorActive || selectedIndex < 0 || selectedIndex >= visibleWindows.length) return
    focusOrRestoreWindow(visibleWindows[selectedIndex])
  }

  function deleteSelected() {
    if (!cursorActive || selectedIndex < 0 || selectedIndex >= visibleWindows.length) return
    closeWindow(visibleWindows[selectedIndex])
  }

  TextMetrics {
    id: buttonLabelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: button.labelText
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fontSize: Style.bar.iconFont
    readonly property string labelText: !button.vertical && root.totalCount > 0
      ? (root.minimizedCount > 0
          ? (Commons.I18n.formatNumber(root.totalCount) + " (" + Commons.I18n.formatNumber(root.minimizedCount) + "↓)")
          : Commons.I18n.formatNumber(root.totalCount))
      : ""
    readonly property real slotSize: !button.vertical && labelText !== ""
      ? Math.max(Style.bar.iconSlot, Math.ceil(Style.bar.iconCanvas + Style.space(4) + buttonLabelMetrics.advanceWidth + Style.space(14)))
      : Style.bar.iconSlot
    fixedWidth: vertical ? -1 : slotSize
    fixedHeight: vertical ? slotSize : -1
    active: root.opened
    useActiveColor: root.opened
    tooltipText: {
      var totalLabel = strings.tn("tooltip.summary", root.totalCount).arg(Commons.I18n.formatNumber(root.totalCount))
      if (root.minimizedCount > 0) {
        var minLabel = strings.tn("summary.minimizedCount", root.minimizedCount).arg(Commons.I18n.formatNumber(root.minimizedCount))
        return strings.t("tooltip.summaryMin").arg(totalLabel).arg(minLabel)
      }
      return totalLabel
    }
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }

    Item {
      id: buttonContent
      x: (button.width - width) / 2
      y: (button.height - height) / 2
      scale: button.pressScale
      width: Style.bar.iconCanvas + (buttonCountLabel.visible ? buttonCountLabel.implicitWidth + Style.space(4) : 0)
      height: Style.bar.iconCanvas

      OpticalGlyph {
        x: buttonContent.LayoutMirroring.enabled && buttonCountLabel.visible
          ? buttonCountLabel.implicitWidth + Style.space(4)
          : 0
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: "󱂬"
        fontFamily: button.fontFamily
        fontSize: button.fontSize
        paintedSize: Style.bar.iconSize
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        rotation: button.textRotation
      }

      Text {
        id: buttonCountLabel
        visible: button.labelText !== ""
        x: buttonContent.LayoutMirroring.enabled ? 0 : Style.bar.iconCanvas + Style.space(4)
        y: (parent.height - height) / 2
          + (buttonLabelFontMetrics.descent - buttonLabelFontMetrics.ascent + buttonLabelFontMetrics.tightBoundingRect("0").height) / 2
        textFormat: Text.PlainText
        text: button.labelText
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        renderType: Text.NativeRendering
      }

      FontMetrics {
        id: buttonLabelFontMetrics
        font: buttonCountLabel.font
      }
    }

    Rectangle {
      visible: root.minimizedCount > 0 && !root.opened
      width: Style.space(6)
      height: Style.space(6)
      radius: Style.space(3)
      color: Commons.Color.accent
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(5)
      anchors.rightMargin: Style.space(4)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias listFlick: listFlick
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.cycleFilter(dx)
      }
      onActivateRequested: root.activateSelected()
      onDeleteRequested: root.deleteSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Item {
          id: headerRow
          width: parent.width
          implicitHeight: Math.max(headerLabels.implicitHeight, restoreBtn.implicitHeight)

          Column {
            id: headerLabels
            anchors.left: parent.left
            anchors.right: restoreBtn.visible ? restoreBtn.left : parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: strings.t("title")
              color: Commons.Color.popups.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: {
                var runningLabel = strings.tn("summary.running", root.totalCount).arg(Commons.I18n.formatNumber(root.totalCount))
                if (root.minimizedCount > 0) {
                  var minLabel = strings.tn("summary.minimizedCount", root.minimizedCount).arg(Commons.I18n.formatNumber(root.minimizedCount))
                  return strings.t("summary.runningAndMinimized").arg(runningLabel).arg(minLabel)
                }
                return runningLabel
              }
              color: root.minimizedCount > 0 ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.65)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            id: restoreBtn
            visible: root.minimizedCount > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: restoreLabel.implicitHeight + Style.space(8)
            width: restoreLabel.implicitWidth + Style.space(16)
            radius: Style.cornerRadius
            color: restoreMouse.containsMouse ? root.selectedFill : root.hoverFill
            border.width: 1
            border.color: Commons.Color.accent

            Text {
              id: restoreLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: strings.t("action.restoreAll")
              color: Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: restoreMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.restoreAllMinimized()
            }
          }
        }

        Flow {
          id: filterFlow
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.filterTabs

            delegate: Rectangle {
              required property var modelData
              readonly property bool isCurrent: root.filterMode === modelData.id
              height: tabLabel.implicitHeight + Style.space(8)
              width: tabLabel.implicitWidth + Style.space(16)
              radius: Style.cornerRadius
              color: isCurrent ? root.selectedFill : (tabMouse.containsMouse ? root.hoverFill : "transparent")
              border.width: 1
              border.color: isCurrent ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.2)

              Text {
                id: tabLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData.label
                color: isCurrent ? Commons.Color.accent : Commons.Color.popups.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: isCurrent
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.filterMode = modelData.id
                  root.selectedIndex = 0
                  root.ensureRowVisible(0)
                }
              }
            }
          }
        }

        PanelSeparator {
          id: listSeparator
          width: parent.width
        }

        Text {
          visible: root.visibleWindows.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: root.filterMode === "minimized"
            ? strings.t("empty.minimized")
            : (Model.parseWorkspaceFilterId(root.filterMode) >= 1 ? strings.t("empty.ws") : strings.t("empty.all"))
          color: Util.alpha(Commons.Color.popups.text, 0.65)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(14)
          bottomPadding: Style.space(14)
        }

        Flickable {
          id: listFlick
          visible: root.visibleWindows.length > 0
          width: parent.width
          readonly property real maxCardContentHeight: panel.availableCardHeight > 0
            ? Math.max(Style.space(120), panel.availableCardHeight - panel.verticalContentInset)
            : 9999
          readonly property real chromeHeight: headerRow.implicitHeight
            + filterFlow.implicitHeight + column.spacing
            + listSeparator.implicitHeight + column.spacing
            + footerHint.implicitHeight + column.spacing * 2
          readonly property real maxListHeight: Math.max(
            Style.space(80),
            Math.min(
              Math.round((panel.screen ? panel.screen.height : 900) * 0.62),
              Math.floor(maxCardContentHeight - chromeHeight)
            )
          )
          height: Math.min(listColumn.implicitHeight, maxListHeight)
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar {
            id: listScroll
            policy: listFlick.contentHeight > listFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
          }

          Column {
            id: listColumn
            width: listFlick.width - (listFlick.contentHeight > listFlick.height ? listScroll.width + Style.space(4) : 0)
            spacing: root.rowSpacing

            Repeater {
              model: (root.opened || panel.visible) ? root.visibleWindows : []

              delegate: Rectangle {
                required property var modelData
                required property int index

                readonly property bool isSelected: root.cursorActive && root.selectedIndex === index
                readonly property bool isHovered: rowMouse.containsMouse || closeMouse.containsMouse
                readonly property bool sameTitleAndApp: String(modelData.displayTitle || "") === String(modelData.appName || "")
                readonly property int originWs: modelData.minimized ? Model.minimizedOriginWorkspace(modelData.tags) : -1
                readonly property string wsBadge: {
                  if (modelData.minimized) {
                    if (originWs < 1) return strings.t("badge.minimized")
                    var originSlot = Model.slotOf(originWs)
                    var originBlk = Model.blockOf(originWs)
                    if (originBlk !== root.ownBlock) {
                      return strings.t("badge.minimizedFromMonitor")
                        .arg(Commons.I18n.formatNumber(originBlk + 1))
                        .arg(Commons.I18n.formatNumber(originSlot))
                    }
                    return strings.t("badge.minimizedFrom").arg(Commons.I18n.formatNumber(originSlot))
                  }
                  if (modelData.special) {
                    var sn = Model.specialWorkspaceShortName(modelData.workspaceName)
                    if (sn === "scratchpad") return strings.t("badge.specialScratchpad")
                    if (sn === "qconsole") return strings.t("badge.specialQconsole")
                    return sn.toUpperCase()
                  }
                  var slot = Model.slotOf(modelData.workspaceId)
                  var blk = Model.blockOf(modelData.workspaceId)
                  if (slot >= 1 && blk !== root.ownBlock) {
                    return strings.t("badge.wsMonitor").arg(Commons.I18n.formatNumber(blk + 1)).arg(Commons.I18n.formatNumber(slot))
                  }
                  return strings.t("badge.ws").arg(Commons.I18n.formatNumber(slot >= 1 ? slot : modelData.workspaceId))
                }

                width: listColumn.width
                height: root.rowHeight
                radius: Style.cornerRadius
                color: isSelected ? root.selectedFill : (isHovered ? root.hoverFill : "transparent")
                border.width: modelData.activated ? 1 : 0
                border.color: Util.alpha(Commons.Color.accent, 0.55)

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.focusOrRestoreWindow(modelData)
                }

                Item {
                  id: iconBox
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(26)
                  height: Style.space(26)

                  Image {
                    id: rowIcon
                    anchors.fill: parent
                    sourceSize: Qt.size(width * 2, height * 2)
                    source: modelData.iconSource
                    fillMode: Image.PreserveAspectFit
                    asynchronous: false
                    smooth: true
                    mipmap: true
                  }

                  Rectangle {
                    visible: rowIcon.status !== Image.Ready || String(rowIcon.source || "") === "" || rowIcon.implicitWidth <= 0
                    anchors.fill: parent
                    radius: Math.max(Style.cornerRadius, Style.space(5))
                    color: Util.alpha(Commons.Color.popups.text, 0.12)
                    border.width: 1
                    border.color: Util.alpha(Commons.Color.popups.text, 0.28)

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: modelData.appId === "org.omarchy.agent" ? ">_" : String(modelData.appName || "?").slice(0, 2).toUpperCase()
                      color: Commons.Color.popups.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }

                Column {
                  anchors.left: iconBox.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: wsBadgeRect.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: modelData.displayTitle || modelData.appName
                    color: Commons.Color.popups.text
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: modelData.activated
                  }

                  Text {
                    visible: !sameTitleAndApp || modelData.activated
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: sameTitleAndApp
                      ? strings.t("status.active")
                      : (modelData.activated
                          ? strings.t("status.appActive").arg(modelData.appName).arg(strings.t("status.active"))
                          : modelData.appName)
                    color: modelData.activated ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.65)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  id: wsBadgeRect
                  anchors.right: closeBtn.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  height: wsText.implicitHeight + Style.space(4)
                  width: wsText.implicitWidth + Style.space(10)
                  radius: Math.max(Style.cornerRadius, Style.space(4))
                  color: modelData.minimized ? Util.alpha(Commons.Color.accent, 0.2) : Util.alpha(Commons.Color.popups.text, 0.1)

                  Text {
                    id: wsText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: wsBadge
                    color: modelData.minimized ? Commons.Color.accent : Util.alpha(Commons.Color.popups.text, 0.8)
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(9, Style.font.caption - 1)
                    font.bold: modelData.minimized
                  }
                }

                Rectangle {
                  id: closeBtn
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(22)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: closeMouse.containsMouse ? Util.alpha(Commons.Color.urgent, 0.25) : "transparent"

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "×"
                    color: closeMouse.containsMouse ? Commons.Color.urgent : Util.alpha(Commons.Color.popups.text, 0.65)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.closeWindow(modelData)
                  }
                }
              }
            }
          }
        }

        Text {
          id: footerHint
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("hint.footer")
          color: Util.alpha(Commons.Color.popups.text, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Math.max(9, Style.font.caption - 1)
          elide: Text.ElideRight
        }
      }
    }
  }
}
