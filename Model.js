// Pure helpers for normalizing, sorting, and disambiguating Hyprland windows.

var MINIMIZED_WORKSPACE = "special:minimized"

function isMinimizedWorkspace(name) {
  return String(name || "") === MINIMIZED_WORKSPACE
}

function isSpecialWorkspace(name) {
  var s = String(name || "")
  return s.indexOf("special:") === 0 && s !== MINIMIZED_WORKSPACE
}

function specialWorkspaceShortName(name) {
  var s = String(name || "")
  if (s.indexOf("special:") === 0) return s.slice("special:".length)
  return s
}

function blockOf(workspaceId) {
  var id = Number(workspaceId)
  if (!(id >= 1)) return 0
  return Math.floor((id - 1) / 10)
}

function normalizeAddress(address) {
  var value = String(address || "").trim()
  if (!/^(0x)?[0-9a-fA-F]+$/.test(value)) return ""
  return value.indexOf("0x") === 0 ? value : "0x" + value
}

function minimizedOriginWorkspace(tags) {
  var list = tags || []
  for (var i = 0; i < list.length; i++) {
    var m = /^omarchy-minimized-from-([1-9][0-9]*)$/.exec(String(list[i] || ""))
    if (m) return parseInt(m[1], 10)
  }
  return -1
}

function slotOf(workspaceId) {
  var id = Number(workspaceId)
  if (!(id >= 1)) return -1
  return ((id - 1) % 10) + 1
}

function workspaceFilterId(workspaceId) {
  var id = Number(workspaceId)
  if (!(id >= 1)) return ""
  return "ws:" + Math.floor(id)
}

function parseWorkspaceFilterId(filterMode) {
  var m = /^ws:([1-9][0-9]*)$/.exec(String(filterMode || ""))
  return m ? parseInt(m[1], 10) : -1
}

function collectWorkspaceTabs(windows, activeWorkspaceId, ownBlock) {
  var counts = {}
  var list = windows || []
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    if (!w || w.minimized || w.special) continue
    var id = Number(w.workspaceId)
    if (!(id >= 1)) continue
    counts[id] = (counts[id] || 0) + 1
  }

  var activeId = Number(activeWorkspaceId)
  var ids = Object.keys(counts).map(function(k) { return parseInt(k, 10) })
  ids.sort(function(a, b) { return a - b })

  var activeBlock = (ownBlock !== undefined && ownBlock !== null && Number(ownBlock) >= 0)
    ? Number(ownBlock)
    : (activeId >= 1 ? blockOf(activeId) : 0)
  var tabs = []
  for (var j = 0; j < ids.length; j++) {
    var wsId = ids[j]
    var blk = blockOf(wsId)
    tabs.push({
      id: workspaceFilterId(wsId),
      workspaceId: wsId,
      slot: slotOf(wsId),
      block: blk,
      sameBlock: blk === activeBlock,
      count: counts[wsId]
    })
  }
  return tabs
}

function filterWindows(windows, filterMode) {
  var list = windows || []
  if (filterMode === "all") return list
  var targetWs = parseWorkspaceFilterId(filterMode)
  var out = []
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    if (filterMode === "minimized") {
      if (w.minimized) out.push(w)
    } else if (targetWs >= 1) {
      if (!w.minimized && !w.special && Number(w.workspaceId) === targetWs) out.push(w)
    } else {
      out.push(w)
    }
  }
  return out
}

function extractChromeWebappHost(appId) {
  var m = /^chrome-([A-Za-z0-9._-]+)__-[A-Za-z0-9._-]+$/.exec(String(appId || ""))
  return m ? m[1].toLowerCase() : ""
}

function claimingEntryId(appId, entries) {
  var id = String(appId || "")
  if (!id) return ""
  var list = entries || []
  var flag = "--app-id=" + id
  for (var i = 0; i < list.length; i++) {
    var exec = String(list[i].execString || "")
    if (exec.indexOf(flag) >= 0) {
      var words = exec.split(/\s+/)
      for (var w = 0; w < words.length; w++) {
        var clean = words[w].replace(/^['"]|['"]$/g, "")
        if (clean === flag) return list[i].id
      }
    }
  }
  if (id.indexOf("org.omarchy.") === 0) {
    var command = id.slice("org.omarchy.".length)
    for (var j = 0; j < list.length; j++) {
      var program = String((list[j].command || [])[0] || "")
      if (list[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command) return list[j].id
    }
  }
  var host = extractChromeWebappHost(id)
  if (host) {
    for (var k = 0; k < list.length; k++) {
      var cmdText = String(list[k].execString || "") + " " + String((list[k].command || []).join(" "))
      var lower = cmdText.toLowerCase()
      if (lower.indexOf("://" + host) >= 0 || lower.indexOf("." + host) >= 0) return list[k].id
    }
  }
  return ""
}

function sortWindows(windows, activeWorkspaceId) {
  var list = (windows || []).slice()
  function rank(w) {
    if (activeWorkspaceId >= 1 && !w.minimized && !w.special && w.workspaceId === activeWorkspaceId) return 0
    if (!w.minimized && !w.special && w.workspaceId >= 1) return 1
    if (w.minimized) return 2
    return 3
  }
  list.sort(function(a, b) {
    var ra = rank(a)
    var rb = rank(b)
    if (ra !== rb) return ra - rb
    if (ra === 1 && a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
    var fa = isFinite(a.focusHistoryID) ? a.focusHistoryID : 9999
    var fb = isFinite(b.focusHistoryID) ? b.focusHistoryID : 9999
    if (fa !== fb) return fa - fb
    return String(a.appName || "").localeCompare(String(b.appName || ""))
  })
  return list
}

function disambiguateWindows(windows, pidInfo) {
  var list = (windows || []).slice()
  var infoMap = pidInfo || ({})
  var enriched = list.map(function(w) {
    var copy = Object.assign({}, w)
    var info = w.pid > 0 ? infoMap[String(w.pid)] : null
    if (info) {
      var parts = []
      if (info.prog) parts.push(info.prog)
      if (info.cwd) parts.push(info.cwd)
      if (info.hint) {
        var h = String(info.hint)
        parts.push(h.length > 24 ? (h.slice(0, 23) + "…") : h)
      }
      var sub = parts.join(" · ")
      if (sub && String(copy.title || "").toLowerCase() === "foot") copy.displayTitle = sub
      else if (sub) copy.displayTitle = copy.title + " — " + sub
      else copy.displayTitle = copy.title
    } else {
      copy.displayTitle = copy.title
    }
    return copy
  })

  // Number any remaining identical primary titles within the same app (prefixing
  // #N when long so Text.ElideRight never hides the disambiguating index).
  var counts = {}
  for (var i = 0; i < enriched.length; i++) {
    var key = enriched[i].appId + "::" + enriched[i].displayTitle
    counts[key] = (counts[key] || 0) + 1
  }
  var seen = {}
  for (var j = 0; j < enriched.length; j++) {
    var k = enriched[j].appId + "::" + enriched[j].displayTitle
    if (counts[k] > 1) {
      seen[k] = (seen[k] || 0) + 1
      enriched[j].displayTitle = enriched[j].displayTitle.length > 20
        ? ("#" + seen[k] + " · " + enriched[j].displayTitle)
        : (enriched[j].displayTitle + " #" + seen[k])
    }
  }
  return enriched
}

if (typeof module !== "undefined") {
  module.exports = {
    isMinimizedWorkspace: isMinimizedWorkspace,
    isSpecialWorkspace: isSpecialWorkspace,
    specialWorkspaceShortName: specialWorkspaceShortName,
    blockOf: blockOf,
    normalizeAddress: normalizeAddress,
    minimizedOriginWorkspace: minimizedOriginWorkspace,
    slotOf: slotOf,
    workspaceFilterId: workspaceFilterId,
    parseWorkspaceFilterId: parseWorkspaceFilterId,
    collectWorkspaceTabs: collectWorkspaceTabs,
    filterWindows: filterWindows,
    extractChromeWebappHost: extractChromeWebappHost,
    claimingEntryId: claimingEntryId,
    sortWindows: sortWindows,
    disambiguateWindows: disambiguateWindows
  }
}
