import * as icons from './lib/icons.coffee'
import * as dom from './lib/dom.coffee'
import * as remotes from './lib/remotes.coffee'
import * as throttle from './lib/throttle.coffee'
import * as timesync from './lib/timesync.coffee'

board = historyBoard = null # Board objects
gridDefault = true
selection = null # Selection object representing selected objects
undoStack = []
redoStack = []
eraseDist = 2   # require movement by this many pixels before erasing swipe
dragDist = 2    # require movement by this many pixels before select drags
remoteIconSize = 24
remoteIconOutside = 0.2  # fraction to render icons outside view
currentRoom = currentPage = null
currentGrid = null
allowTouch = true

Alt =
  if navigator?.platform.startsWith 'Mac'
    'Option'
  else
    'Alt'

distanceThreshold = (p, q, t) ->
  return false if not p or not q
  return true if p == true or q == true
  dx = p.clientX - q.clientX
  dy = p.clientY - q.clientY
  dx * dx + dy * dy >= t * t

pointers = {}   # maps pointerId to tool-specific data
tools =
  undo:
    icon: 'undo'
    help: 'Undo the last operation you did'
    hotkey: 'Ctrl-Z'
    once: ->
      undo()
  redo:
    icon: 'redo'
    help: 'Redo: Undo the last undo you did (if you did no operations since)'
    hotkey: ['Ctrl-Y', 'Ctrl-Shift-Z']
    once: ->
      redo()
  pan:
    icon: 'arrows-alt'
    hotspot: [0.5, 0.5]
    help: 'Pan around the page by dragging'
    hotkey: 'hold SPACE'
    down: (e) ->
      pointers[e.pointerId] = eventToRawPoint e
      pointers[e.pointerId].transform = Object.assign {}, board.transform
    up: (e) ->
      delete pointers[e.pointerId]
    move: (e) ->
      return unless start = pointers[e.pointerId]
      current = eventToRawPoint e
      board.transform.x = start.transform.x +
        (current.x - start.x) / board.transform.scale
      board.transform.y = start.transform.y +
        (current.y - start.y) / board.transform.scale
      board.retransform()
  select:
    icon: 'mouse-pointer'
    hotspot: [0.21875, 0.03515625]
    help: 'Select objects (multiple if holding <kbd>Shift</kbd>) and then change their color/width or drag to move them'
    hotkey: 's'
    start: ->
      pointers.objects = {}
    stop: selectHighlightReset = ->
      selection.clear()
      for key, highlighter of pointers
        if highlighter instanceof Highlighter
          highlighter.clear()
    down: (e) ->
      pointers[e.pointerId] ?= new Highlighter
      h = pointers[e.pointerId]
      return if h.down  # in case of repeat events
      h.down = e
      h.start = eventToRawPoint e
      h.moved = null
      ## Refresh previously selected objects, in particular so tx/ty up-to-date
      for id in selection.ids()
        pointers.objects[id] = Objects.findOne id
      unless h.id?  # see if we pressed on something
        target = h.findGroup e
        if target?
          h.highlight target
      toggle = e.shiftKey or e.ctrlKey or e.metaKey
      unless toggle or selection.has h.id
        ## Deselect existing selection unless requesting multiselect
        selection.clear()
        pointers.objects = {}
      if h.id?  # have something highlighted, possibly just now
        unless selection.has h.id
          pointers.objects[h.id] = Objects.findOne h.id
          selection.add h
        else
          if toggle
            selection.remove h.id
            delete pointers.objects[h.id]
          h.clear()
    up: (e) ->
      h = pointers[e.pointerId]
      if h?.moved
        undoableOp
          type: 'multi'
          ops:
            for id, obj of pointers.objects
              type: 'edit'
              id: id
              before:
                tx: obj.tx ? 0
                ty: obj.ty ? 0
              after: h.moved[id]
      h?.clear()
      delete pointers[e.pointerId]
    move: (e) ->
      pointers[e.pointerId] ?= new Highlighter
      h = pointers[e.pointerId]
      if h.down
        if distanceThreshold h.down, e, dragDist
          h.down = true
          here = eventToRawPoint e
          ## Don't set h.moved out here in case no objects selected
          for id, obj of pointers.objects
            h.moved ?= {}
            tx = (obj.tx ? 0) + (here.x - h.start.x) / board.transform.scale
            ty = (obj.ty ? 0) + (here.y - h.start.y) / board.transform.scale
            Meteor.call 'objectEdit', {id, tx, ty}
            h.moved[id] = {tx, ty}
      else
        target = h.findGroup e
        if target?
          h.highlight target
        else
          h.clear()
  pen:
    icon: 'pencil-alt'
    hotspot: [0, 1]
    help: 'Freehand drawing (with pen pressure adjusting width)'
    hotkey: 'p'
    down: (e) ->
      return if pointers[e.pointerId]
      pointers[e.pointerId] = Meteor.apply 'objectNew', [
        room: currentRoom
        page: currentPage
        type: 'pen'
        pts: [eventToPointW e]
        color: currentColor
        width: currentWidth
      ], returnStubValue: true
    up: (e) ->
      return unless pointers[e.pointerId]
      undoableOp
        type: 'new'
        obj: Objects.findOne pointers[e.pointerId]
      delete pointers[e.pointerId]
    move: (e) ->
      return unless pointers[e.pointerId]
      ## iPhone (iOS 13.4, Safari 13.1) sends zero pressure for touch events.
      #if e.pressure == 0
      #  stop e
      #else
      Meteor.call 'objectPush',
        id: pointers[e.pointerId]
        pts:
          for e2 in e.getCoalescedEvents?() ? [e]
            eventToPointW e2
  segment:
    icon: 'segment'
    hotspot: [0.0625, 0.9375]
    help: "Draw straight line segment between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to horizontal/vertical, <kbd>#{Alt}</kbd> to center at first point."
    hotkey: ['l', '\\']
    start: ->
      pointers.throttle = throttle.method 'objectEdit'
    down: (e) ->
      return if pointers[e.pointerId]
      origin = eventToPoint e
      pointers[e.pointerId] =
        origin: origin
        id: Meteor.apply 'objectNew', [
          room: currentRoom
          page: currentPage
          type: 'poly'
          pts: [origin, origin]
          color: currentColor
          width: currentWidth
        ], returnStubValue: true
    up: (e) ->
      return unless pointers[e.pointerId]
      undoableOp
        type: 'new'
        obj: Objects.findOne pointers[e.pointerId].id
      delete pointers[e.pointerId]
    move: (e) ->
      return unless pointers[e.pointerId]
      {origin, id, alt} = pointers[e.pointerId]
      pt = eventToPoint e
      ## Force horizontal/vertical line when holding shift
      if e.shiftKey
        dx = Math.abs pt.x - origin.x
        dy = Math.abs pt.y - origin.y
        if dx > dy
          pt.y = origin.y
        else
          pt.x = origin.x
      pts =
        1: pt
      ## When holding Alt/Option, make origin be the center.
      if e.altKey
        pts[0] = symmetricPoint pts[1], origin
      else if alt  # was holding down Alt, go back to original first point
        pts[0] = origin
      pointers[e.pointerId].alt = e.altKey
      pointers.throttle
        id: id
        pts: pts
  rect:
    icon: 'rect'
    iconFill: 'rect-fill'
    hotspot: [0.0625, 0.883]
    help: "Draw axis-aligned rectangle between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to square, <kbd>#{Alt}</kbd> to center at first point."
    hotkey: 'r'
    start: ->
      pointers.throttle = throttle.method 'objectEdit'
    down: (e) ->
      return if pointers[e.pointerId]
      origin = eventToPoint e
      object =
        room: currentRoom
        page: currentPage
        type: 'rect'
        pts: [origin, origin]
        color: currentColor
        width: currentWidth
      object.fill = currentFill if currentFillOn
      pointers[e.pointerId] =
        origin: origin
        id: Meteor.apply 'objectNew', [object], returnStubValue: true
    up: (e) ->
      return unless pointers[e.pointerId]
      undoableOp
        type: 'new'
        obj: Objects.findOne pointers[e.pointerId].id
      delete pointers[e.pointerId]
    move: rectMove = (e) ->
      return unless pointers[e.pointerId]
      {id, origin, alt} = pointers[e.pointerId]
      pts =
        1: eventToConstrainedPoint e, origin
      ## When holding Alt/Option, make origin be the center.
      if e.altKey
        pts[0] = symmetricPoint pts[1], origin
      else if alt  # was holding down Alt, go back to original first point
        pts[0] = origin
      pointers[e.pointerId].alt = e.altKey
      pointers.throttle
        id: id
        pts: pts
  ellipse:
    icon: 'ellipse'
    iconFill: 'ellipse-fill'
    hotspot: [0.201888, 0.75728]
    help: "Draw axis-aligned ellipsis inside rectangle between endpoints (drag). Hold <kbd>Shift</kbd> to constrain to circle, <kbd>#{Alt}</kbd> to center at first point."
    hotkey: 'o'
    start: ->
      pointers.throttle = throttle.method 'objectEdit'
    down: (e) ->
      return if pointers[e.pointerId]
      origin = eventToPoint e
      object =
        room: currentRoom
        page: currentPage
        type: 'ellipse'
        pts: [origin, origin]
        color: currentColor
        width: currentWidth
      object.fill = currentFill if currentFillOn
      pointers[e.pointerId] =
        origin: origin
        id: Meteor.apply 'objectNew', [object], returnStubValue: true
    up: (e) ->
      return unless pointers[e.pointerId]
      undoableOp
        type: 'new'
        obj: Objects.findOne pointers[e.pointerId].id
      delete pointers[e.pointerId]
    move: rectMove
  eraser:
    icon: 'eraser'
    hotspot: [0.4, 0.9]
    help: 'Erase entire objects: click for one object, drag for multiple objects'
    hotkey: 'x'
    stop: -> selectHighlightReset()
    down: (e) ->
      pointers[e.pointerId] ?= new Highlighter
      h = pointers[e.pointerId]
      return if h.down  # repeat events can happen because of erasure
      h.down = e
      h.deleted = []
      if h.id?  # already have something highlighted
        h.deleted.push Objects.findOne h.id
        Meteor.call 'objectDel', h.id
        h.clear()
      else  # see if we pressed on something
        target = h.findGroup e
        if target?
          h.deleted.push Objects.findOne target.dataset.id
          Meteor.call 'objectDel', target.dataset.id
    up: (e) ->
      h = pointers[e.pointerId]
      h?.clear()
      if h?.deleted?.length
        ## The following is similar to Selection.delete:
        undoableOp
          type: 'multi'
          ops:
            for obj in h.deleted
              type: 'del'
              obj: obj
      delete pointers[e.pointerId]
    move: (e) ->
      pointers[e.pointerId] ?= new Highlighter
      h = pointers[e.pointerId]
      target = h.findGroup e
      if target?
        if distanceThreshold h.down, e, eraseDist
          h.down = true
          h.deleted.push Objects.findOne target.dataset.id
          Meteor.call 'objectDel', target.dataset.id
          h.clear()
        else
          h.highlight target
      else
        h.clear()
  text:
    icon: 'text'
    hotspot: [.77, .89]
    help: 'Type text (click location or existing text, then type at bottom), including Markdown *italic*, **bold**, `code`, ~~strike~~, and LaTeX $math$, $$displaymath$$'
    hotkey: 't'
    init: ->
      input = document.getElementById 'textInput'
      updateCursor = (e) ->
        setTimeout ->
          return unless pointers.text?
          render.render Objects.findOne(pointers.text), text: true
        , 0
      dom.listen input,
        keydown: (e) ->
          e.stopPropagation() # avoid hotkeys
          e.target.blur() if e.key == 'Escape'
          updateCursor e
        click: updateCursor
        paste: updateCursor
        input: (e) ->
          return unless pointers.text?
          text = input.value
          if text != (oldText = Objects.findOne(pointers.text).text)
            Meteor.call 'objectEdit',
              id: pointers.text
              text: text
            unless pointers.undoable?
              undoableOp pointers.undoable =
                type: 'multi'
                ops: []
            pointers.undoable.ops.push
              type: 'edit'
              id: pointers.text
              before: text: oldText
              after: text: text
    start: ->
      pointers.highlight = new Highlighter 'text'
      textStop()
    stop: textStop = (keepHighlight) ->
      input = document.getElementById 'textInput'
      input.value = ''
      input.disabled = true
      selection.clear()
      pointers.highlight?.clear() unless keepHighlight
      pointers.cursor?.remove()
      pointers.cursor = null
      return unless (id = pointers.text)?
      if (object = Objects.findOne id)?
        unless object.text
          index = undoStack.indexOf pointers.undoable
          undoStack.splice index, 1 if index >= 0
          Meteor.call 'objectDel', id
      pointers.undoable = null
      pointers.text = null
    up: (e) ->
      return unless e.type == 'pointerup' # ignore pointerleave
      ## Stop editing any previous text object.
      textStop true
      ## In future, may support dragging a rectangular container for text,
      ## but maybe only after SVG 2's <text> flow support...
      h = pointers.highlight
      unless h.id?
        if (target = h.findGroup e)?
          h.highlight target
      if h.id?
        pointers.text = h.id
        selection.add h
        text = Objects.findOne(pointers.text)?.text ? ''
      else
        pointers.text = Meteor.apply 'objectNew', [
          room: currentRoom
          page: currentPage
          type: 'text'
          pts: [eventToPoint e]
          text: text = ''
          color: currentColor
          fontSize: currentFontSize
        ], returnStubValue: true
        selection.addId pointers.text
        undoableOp pointers.undoable =
          type: 'multi'
          ops: [
            type: 'new'
            obj: object = Objects.findOne pointers.text
          ]
      input = document.getElementById 'textInput'
      input.value = text
      input.disabled = false
      input.focus()
    move: (e) ->
      h = pointers.highlight
      target = h.findGroup e
      if target? and Objects.findOne(target.dataset.id).type == 'text'
        h.highlight target
      else
        h.clear()
  spacer: {}
  touch:
    icon: 'hand-pointer'
    help: 'Allow drawing with touch. Disable when using a pen-enabled device to ignore palm resting on screen; then touch will only work with pan and select tools.'
    init: touchUpdate = ->
      touchTool = document.querySelector '.tool[data-tool="touch"]'
      if allowTouch
        touchTool.classList.add 'active'
      else
        touchTool.classList.remove 'active'
    once: ->
      allowTouch = not allowTouch
      touchUpdate()
  grid:
    icon: 'grid'
    help: 'Toggle grid/graph paper'
    once: ->
      Meteor.call 'gridToggle', currentPage
  linkRoom:
    icon: 'clipboard-link'
    help: 'Copy a link to this room/board to clipboard (for sharing with others)'
    once: ->
      navigator.clipboard.writeText document.URL
  newRoom:
    icon: icons.stackIcons [
      'door-open'
      icons.modIcon 'circle',
        fill: 'var(--palette-color)'
        transform: "translate(300 256) scale(0.55) translate(-256 -256)"
      icons.modIcon 'plus-circle',
        transform: "translate(300 256) scale(0.45) translate(-256 -256)"
    ]
    help: 'Create a new room/board (with new URL) in a new browser tab/window'
    once: ->
      window.open '/'
  history:
    icon: 'history'
    hotspot: [0.5, 0.5]
    help: 'Time travel to the past (by dragging the bottom slider)'
    start: ->
      historyObjects = {}
      range = document.getElementById 'historyRange'
      range.value = 0
      query =
        room: currentRoom
        page: currentPage
      lastTarget = null
      historyRender = null
      range.addEventListener 'change', pointers.listen = (e) ->
        target = parseInt range.value
        if lastTarget? and target >= lastTarget
          options =
            skip: lastTarget
            limit: target - lastTarget
        else
          historyBoard.clear()
          historyBoard.retransform()
          historyRender = new Render historyBoard.root
          options =
            limit: target
        return if options.limit == 0
        lastTarget = target
        #count = 0
        for diff from ObjectsDiff.find query, options
          #count++
          #break if count > target
          switch diff.type
            when 'pen', 'poly', 'rect', 'ellipse', 'text'
              obj = diff
              historyObjects[obj.id] = obj
              historyRender.render obj
            when 'push'
              obj = historyObjects[diff.id]
              obj.pts.push ...diff.pts
              historyRender.render obj,
                start: obj.pts.length - diff.pts.length
                translate: false
            when 'edit'
              obj = historyObjects[diff.id]
              for key, value of diff when key not in ['id', 'type']
                switch key
                  when 'pts'
                    for subkey, subvalue of value
                      obj[key][subkey] = subvalue
                  else
                    obj[key] = value
              historyRender.render obj
            when 'del'
              historyRender.delete diff
              delete historyObjects[diff.id]
      pointers.sub = subscribe 'history', currentRoom, currentPage
      range.max = 0
      pointers.observe = ObjectsDiff.find query
      .observe
        addedAt: (doc, index) ->
          range.max++
          pointers.listen() if index <= range.value
        changedAt: (doc, index) ->
          pointers.listen() if index <= range.value
        removedAt: (doc, index) ->
          range.max--
          pointers.listen() if index <= range.value
    stop: ->
      document.getElementById('historyRange').removeEventListener 'change', pointers.listen
      historyBoard.clear()
      pointers.sub.stop()
      pointers.observe.stop()
    down: (e) ->
      pointers[e.pointerId] = eventToRawPoint e
      pointers[e.pointerId].transform =
        Object.assign {}, historyBoard.transform
    up: (e) ->
      delete pointers[e.pointerId]
    move: (e) ->
      return unless start = pointers[e.pointerId]
      current = eventToRawPoint e
      historyBoard.transform.x = start.transform.x +
        (current.x - start.x) / historyBoard.transform.scale
      historyBoard.transform.y = start.transform.y +
        (current.y - start.y) / historyBoard.transform.scale
      historyBoard.retransform()
  downloadSVG:
    icon: 'download-svg'
    help: 'Download/export entire drawing as an SVG file'
    once: ->
      ## Temporarily remove transform for export
      root = currentBoard().root # <g>
      oldTransform = root.getAttribute 'transform'
      root.removeAttribute 'transform'
      ## Compute bounding box using SVG's getBBox() and getCTM()
      min =
        x: Infinity
        y: Infinity
      max =
        x: -Infinity
        y: -Infinity
      for elt in root.childNodes
        continue if elt.classList.contains 'grid'
        ## Compute bounding box and incorporate transformation
        ## (assuming no rotation, so enough to look at two corners).
        bbox = elt.getBBox()
        transform = elt.getCTM()
        stroke = (parseFloat elt.getAttribute('stroke-width') ? 0) / 2
        minCorner = dom.svgPoint currentBoard().svg,
          bbox.x - stroke, bbox.y - stroke, transform
        maxCorner = dom.svgPoint currentBoard().svg,
          bbox.x + stroke + bbox.width, bbox.y + stroke + bbox.height, transform
        min.x = Math.min min.x, minCorner.x
        max.x = Math.max max.x, maxCorner.x
        min.y = Math.min min.y, minCorner.y
        max.y = Math.max max.y, maxCorner.y
      if min.x == Infinity
        min.x = min.y = max.x = max.y = 0
      ## Temporarily make grid space entire drawing
      currentBoard().grid?.update currentGrid, {min, max}
      ## Create SVG header
      svg = currentBoard().svg.innerHTML
      .replace /&nbsp;/g, '\u00a0' # SVG doesn't support &nbsp;
      fonts = ''
      if /<text/.test svg
        for styleSheet in document.styleSheets
          if /fonts/.test styleSheet.href
            for rule in styleSheet.rules
              fonts += (rule.cssText.replace /unicode-range:.*?;/g, '') + '\n'
        fonts += '''
          text { font-family: 'Roboto Slab', serif }
          tspan.code { font-family: 'Roboto Mono', monospace }
          tspan.emph { font-style: oblique }
          tspan.strong { font-weight: bold }
          tspan.strike { text-decoration: line-through }

        '''
      svg = """
        <?xml version="1.0" encoding="utf-8"?>
        <svg xmlns="#{dom.SVGNS}" viewBox="#{min.x} #{min.y} #{max.x - min.x} #{max.y - min.y}">
        <style>
        .grid { stroke-width: 0.96; stroke: #c4e3f4 }
        #{fonts}</style>
        #{svg}
        </svg>
      """
      ## Reset transform and grid
      root.setAttribute 'transform', oldTransform
      currentBoard().grid?.update()
      ## Download file
      download = document.getElementById 'download'
      download.href = URL.createObjectURL new Blob [svg], type: 'image/svg+xml'
      download.download = "cocreate-#{currentRoom}.svg"
      download.click()
  github:
    icon: 'github'
    help: 'Go to Github repository: source code, bug reports, and feature requests'
    once: ->
      import('/package.json').then (json) ->
        window.open json.homepage
  pagePrev:
    icon: 'chevron-left-square'
    help: 'Go to previous page'
    hotkey: 'Page Up'
    once: pageDelta = (delta = -1) ->
      index = currentPageIndex()
      return unless index?
      index += delta
      return unless 0 <= index < roomData.pages.length
      changePage roomData.pages[index]
  pageNext:
    icon: 'chevron-right-square'
    help: 'Go to next page'
    hotkey: 'Page Down'
    once: -> pageDelta +1
  pageNew:
    icon: 'plus-square'
    help: 'Add new blank page after the current page'
    once: ->
      index = currentPageIndex()
      return unless index?
      Meteor.call 'pageNew',
        room: currentRoom
        grid:
          if pageData?
            Boolean pageData.grid
          else
            gridDefault
      , index+1
      , (error, page) ->
        if error?
          return console.error "Failed to create new page on server: #{error}"
        changePage page
  pageDup:
    icon: 'clone'
    help: 'Duplicate current page'
    once: ->
      Meteor.call 'pageDup', currentPage, (error, page) ->
        if error?
          return console.error "Failed to duplicate page on server: #{error}"
        changePage page
  pageZoomOut:
    icon: 'search-minus'
    help: 'Zoom out 20%, relative to center'
    hotkey: '-'
    once: steppedZoom = (delta = -1) ->
      factor = 1.2
      transform = currentBoard().transform
      log = Math.round(Math.log(transform.scale) / Math.log(factor))
      log += delta
      currentBoard().setScale factor ** log
  pageZoomIn:
    icon: 'search-plus'
    help: 'Zoom in 20%, relative to center'
    hotkey: ['+', '=']
    once: -> steppedZoom +1
  pageZoomReset:
    icon: 'search-one'
    help: 'Reset zoom to 100%'
    hotkey: '0'
    once: ->
      currentBoard().setScale 1

currentTool = 'pan'
drawingTools =
  pen: true
  segment: true
  rect: true
  ellipse: true
lastDrawingTool = 'pen'
hotkeys = {}

currentBoard = ->
  if currentTool == 'history'
    historyBoard
  else
    board

colors = [
  'black'   # Windows Journal black
  '#666666' # Windows Journal grey
  '#989898' # medium grey
  '#bbbbbb' # lighter grey
  'white'
  '#333399' # Windows Journal dark blue
  '#3366ff' # Windows Journal light blue
  '#00c7c7' # custom light cyan
  '#008000' # Windows Journal green
  '#00c000' # lighter green
  '#800080' # Windows Journal purple
  '#d000d0' # lighter magenta
  '#a00000' # darker red
  '#ff0000' # Windows Journal red
  '#855723' # custom brown
  #'#ff9900' # Windows Journal orange
  '#ed8e00' # custom orange
  '#eced00' # custom yellow
]
currentColor = 'black'
currentFill = 'white'
currentFillOn = false

widths = [
  1
  2
  3
  4
  5
  6
  7
]
for width in widths
  hotkeys[width] = do (width) -> -> selectWidth width
currentWidth = 5

## These numbers are based on powers of 1.2 starting from 16
## (the site's default font size)
fontSizes = [
  12
  16
  19
  23
  28
  33
  40
]
currentFontSize = 19

## Maps a PointerEvent with `pressure` attribute to a `w` multiplier to
## multiply with the "natural" width of the pen.
pressureW = (e) -> 0.5 + e.pressure
#pressureW = (e) -> 2 * e.pressure
#pressureW = (e) ->
#  t = e.pressure ** 3
#  0.5 + (1.5 - 0.5) * t

eventToPoint = (e) ->
  {x, y} = dom.svgPoint board.svg, e.clientX, e.clientY, board.root
  {x, y}

eventToConstrainedPoint = (e, origin) ->
  pt = eventToPoint e
  ## When holding Shift, constrain 1:1 aspect ratio from origin, following
  ## the largest delta and maintaining their signs (like Illustrator).
  if e.shiftKey
    dx = pt.x - origin.x
    dy = pt.y - origin.y
    adx = Math.abs dx
    ady = Math.abs dy
    if adx > ady
      pt.y = origin.y + adx * Math.sign dy
    else if adx < ady
      pt.x = origin.x + ady * Math.sign dx
  pt

eventToPointW = (e) ->
  pt = eventToPoint e
  pt.w =
    ## iPhone (iOS 13.4, Safari 13.1) sends pressure 0 for touch events.
    ## Android Chrome (Samsung Note 8) sends pressure 1 for touch events.
    ## Just ignore pressure on touch and mouse events; could they make sense?
    if e.pointerType == 'pen'
      w = pressureW e
    else
      w = 1
  pt

eventToRawPoint = (e) ->
  x: e.clientX
  y: e.clientY

symmetricPoint = (pt, origin) ->
  x: 2*origin.x - pt.x
  y: 2*origin.y - pt.y

restrictTouch = (e) ->
  not allowTouch and \
  e.pointerType == 'touch' and \
  currentTool of drawingTools

pointerEvents = ->
  dom.listen [board.svg, historyBoard.svg],
    pointerdown: (e) ->
      e.preventDefault()
      return if restrictTouch e
      tools[currentTool].down? e
    pointerenter: (e) ->
      e.preventDefault()
      return if restrictTouch e
      tools[currentTool].down? e if e.buttons
    pointerup: stop = (e) ->
      e.preventDefault()
      return if restrictTouch e
      tools[currentTool].up? e
    pointerleave: stop
    pointermove: (e) ->
      e.preventDefault()
      return if restrictTouch e
      tools[currentTool].move? e
    contextmenu: (e) ->
      ## Prevent right click from bringing up context menu, as it interferes
      ## with e.g. drawing.
      e.preventDefault()
  dom.listen board.svg,
    pointermove: (e) ->
      return unless currentRoom?
      return if restrictTouch e
      remote =
        room: currentRoom
        page: currentPage
        tool: currentTool
        color: currentColor
        cursor: eventToPointW e
      remote.fill = currentFill if currentFillOn
      remotes.update remote

class Highlighter
  constructor: (@type) ->
    @target = null       # <g/polyline/rect/ellipse/text>
    @highlighted = null  # <g/polyline/rect/ellipse/text class="highlight">
    @id = null           # highlighted object ID
  findGroup: (e) ->
    ## Pen and touch devices don't always seem to set `e.target` correctly;
    ## use `document.elementFromPoint` instead.
    #target = e.target
    #if target.tagName.toLowerCase() == 'svg'
    target = document.elementFromPoint e.clientX, e.clientY
    while target? and not target.dataset?.id?
      return if target.classList?.contains 'board'
      target = target.parentNode
    return unless target?
    #return if target == @highlighted
    ## Shouldn't get pointer events on highlighted or selected overlays thanks
    ## to `pointer-events: none`, but check for them just in case:
    for elt in [target, target.parentNode]
      return if elt?.getAttribute('class') in ['highlight', 'selected']
    ## Check for specific match type
    if @type?
      return unless Objects.findOne(target.dataset.id)?.type == @type
    target
  highlight: (target) ->
    ## `target` should be the result of `findGroup`,
    ## so satisfies all above conditions.
    @clear()
    @target = target
    @id = target.dataset.id
    @highlighted ?= dom.create 'g', class: 'highlight'
    board.root.appendChild @highlighted  # ensure on top
    doubler = (match, left, number, right) -> "#{left}#{2 * number}#{right}"
    html = target.outerHTML
    #.replace /\bdata-id=["'][^'"]*["']/g, ''
    .replace /(\bstroke-width=["'])([\d.]+)(["'])/g, doubler
    .replace /(\br=["'])([\d.]+)(["'])/g, doubler
    if /<text\b/.test html
      width = 1.5 # for text
      html = html.replace /\bfill=(["'][^"']+["'])/g, (match, fill) ->
        out = "#{match} stroke=#{fill} stroke-width=\"#{width}\""
        width = 100 # for LaTeX SVGs
        out
      .replace /<svg\b/, '$& overflow="visible"'
    @highlighted.innerHTML = html
    true
  select: (target) ->
    if target?
      @highlight target
    selected = @highlighted
    selected?.setAttribute 'class', 'selected'
    @target = @highlighted = @id = null
    selected
  clear: ->
    if @highlighted?
      board.root.removeChild @highlighted
      @target = @highlighted = @id = null

class Selection
  constructor: ->
    @selected = {}  # mapping from object ID to .selected DOM element
    @rehighlighter = new Highlighter  # used in redraw()
  add: (highlighter) ->
    id = highlighter.id
    return unless id?
    @selected[id] = highlighter.select()
  addId: (id) ->
    ## Add an object to the selection before it's been rendered
    ## (triggering redraw when it gets rendered).
    @selected[id] = true
  redraw: (id, target) ->
    unless @selected[id] == true  # added via `addId`
      board.root.removeChild @selected[id]
    @rehighlighter.highlight target
    @selected[id] = @rehighlighter.select()
  remove: (id) ->
    unless @selected[id] == true  # added via `addId`
      board.root.removeChild @selected[id]
    delete @selected[id]
  clear: ->
    @remove id for id of @selected
  ids: ->
    id for id of @selected
  has: (id) ->
    id of @selected
  count: ->
    @ids().length
  nonempty: ->
    for id of @selected
      return true
    false
  delete: ->
    return unless @nonempty()
    ## The following is similar to eraser.up:
    undoableOp
      type: 'multi'
      ops:
        for id in @ids()
          obj = Objects.findOne id
          Meteor.call 'objectDel', id
          type: 'del'
          obj: obj
    @clear()
  edit: (attrib, value) ->
    undoableOp
      type: 'multi'
      ops:
        for id in @ids()
          obj = Objects.findOne id
          unless obj?[attrib]
            console.warn "Object #{id} has no #{attrib} attribute"
            continue
          type: 'edit'
          id: id
          before: "#{attrib}": obj[attrib]
          after: "#{attrib}": value
    , true

selection = new Selection

undoableOp = (op, now) ->
  redoStack = []
  undoStack.push op
  doOp op if now
doOp = (op, reverse) ->
  switch op.type
    when 'multi'
      ops = op.ops
      ops = ops[..].reverse() if reverse
      for sub in ops
        doOp sub, reverse
    when 'new', 'del'
      if (op.type == 'new') == reverse
        Meteor.call 'objectDel', op.obj._id
      else
        #obj = {}
        #for key, value of op.obj
        #  obj[key] = value unless key of skipKeys
        #op.obj._id = Meteor.apply 'objectNew', [obj], returnStubValue: true
        Meteor.call 'objectNew', op.obj
    when 'edit'
      Meteor.call 'objectEdit', Object.assign
        id: op.id
      ,
        if reverse
          op.before
        else
          op.after
    else
      console.error "Unknown op type #{op.type} for undo/redo"
undo = ->
  if currentTool == 'history'
    return historyAdvance -1
  return unless undoStack.length
  op = undoStack.pop()
  doOp op, true
  redoStack.push op
  selectHighlightReset()
redo = ->
  if currentTool == 'history'
    return historyAdvance +1
  return unless redoStack.length
  op = redoStack.pop()
  doOp op, false
  undoStack.push op
  selectHighlightReset()
historyAdvance = (delta) ->
  range = document.getElementById 'historyRange'
  value = parseInt range.value
  range.value = value + delta
  event = document.createEvent 'HTMLEvents'
  event.initEvent 'change', false, true
  range.dispatchEvent event

class Board
  constructor: (domId) ->
    @svg = document.getElementById domId
    @svg.appendChild @root = dom.create 'g'
    @transform =
      x: 0
      y: 0
      scale: 1
    @resize()
  resize: ->
    ## @bbox maintains client bounding box (top/left/bottom/right) of board
    @bbox = @svg.getBoundingClientRect()
    @remotesRender?.resize()
    @grid?.update()
  setScale: (newScale) ->
    ###
    Maintain center point (x,y):
      bbox.width/2 = (x + transform.x) * transform.scale
        => x = bbox.width/2 / transform.scale - transform.x
      bbox.width/2 = (x + newX) * newScale
        => newX = bbox.width/2 / newScale - x
         = bbox.width/2 / newScale - bbox.width/2 / transform.scale + transform.x
         = bbox.width/2 * (1 / newScale - 1 / transform.scale) + transform.x
    ###
    @transform.x += @bbox.width/2 * (1/newScale - 1/@transform.scale)
    @transform.y += @bbox.height/2 * (1/newScale - 1/@transform.scale)
    @transform.scale = newScale
    @retransform()
  retransform: ->
    @root.setAttribute 'transform',
      "scale(#{@transform.scale}) translate(#{@transform.x} #{@transform.y})"
    @remotesRender?.retransform()
    ## Update grid after `transform` attribute gets rendered.
    Meteor.setTimeout =>
      @grid?.update()
    , 0
  clear: ->
    @root.innerHTML = ''

dot = (obj, p) ->
  dom.create 'circle',
    cx: p.x
    cy: p.y
    r: obj.width * p.w / 2
    fill: obj.color
edge = (obj, p1, p2) ->
  dom.create 'line',
    x1: p1.x
    y1: p1.y
    x2: p2.x
    y2: p2.y
    stroke: obj.color
    'stroke-width': obj.width * (p1.w + p2.w) / 2
    #'stroke-linecap': 'round' # alternative to dot
    ## Dots mode:
    #'stroke-width': 1

class Render
  constructor: (@root) ->
    @dom = {}
    @tex = {}
    @texQueue = []
    @texById = {}
  id: (obj) ->
    ###
    `obj` can be an `ObjectDiff` object, in which case `id` is the object ID
    (and `_id` is the diff ID); or a regular `Object` object, in which case
    `_id` is the object ID.  Also allow raw ID string for `delete`.
    ###
    obj.id ? obj._id ? obj
  renderPen: (obj, options) ->
    ## Redraw from scratch if no `start` specified, or if color or width changed
    start = 0
    if options?.start?
      start = options.start unless options.color or options.width
    id = @id obj
    if exists = @dom[id]
      ## Destroy existing drawing if starting over
      exists.innerHTML = '' if start == 0
      frag = document.createDocumentFragment()
    else
      frag = dom.create 'g', null, dataset: id: id
    ## Draw a `dot` at each point, and an `edge` between consecutive dots
    if start == 0
      frag.appendChild dot obj, obj.pts[0]
      start = 1
    for i in [start...obj.pts.length]
      pt = obj.pts[i]
      frag.appendChild edge obj, obj.pts[i-1], pt
      frag.appendChild dot obj, pt  # alternative to linecap: round
    if exists
      exists.appendChild frag
    else
      @root.appendChild @dom[id] = frag
    @dom[id]
  renderPoly: (obj) ->
    id = @id obj
    unless (poly = @dom[id])?
      @root.appendChild @dom[id] = poly =
        dom.create 'polyline', null, dataset: id: id
    dom.attr poly,
      points: ("#{x},#{y}" for {x, y} in obj.pts).join ' '
      stroke: obj.color
      'stroke-width': obj.width
      'stroke-linecap': 'round'
      'stroke-linejoin': 'round'
      fill: 'none'
    poly
  renderRect: (obj) ->
    id = @id obj
    unless (rect = @dom[id])?
      @root.appendChild @dom[id] = rect =
        dom.create 'rect', null, dataset: id: id
    xMin = Math.min obj.pts[0].x, obj.pts[1].x
    xMax = Math.max obj.pts[0].x, obj.pts[1].x
    yMin = Math.min obj.pts[0].y, obj.pts[1].y
    yMax = Math.max obj.pts[0].y, obj.pts[1].y
    dom.attr rect,
      x: xMin
      y: yMin
      width: xMax - xMin
      height: yMax - yMin
      stroke: obj.color
      'stroke-width': obj.width
      'stroke-linejoin': 'round'
      fill: obj.fill or 'none'
    rect
  renderEllipse: (obj) ->
    id = @id obj
    unless (ellipse = @dom[id])?
      @root.appendChild @dom[id] = ellipse =
        dom.create 'ellipse', null, dataset: id: id
    xMin = Math.min obj.pts[0].x, obj.pts[1].x
    xMax = Math.max obj.pts[0].x, obj.pts[1].x
    yMin = Math.min obj.pts[0].y, obj.pts[1].y
    yMax = Math.max obj.pts[0].y, obj.pts[1].y
    dom.attr ellipse,
      cx: (xMin + xMax) / 2
      cy: (yMin + yMax) / 2
      rx: (xMax - xMin) / 2
      ry: (yMax - yMin) / 2
      stroke: obj.color
      'stroke-width': obj.width
      fill: obj.fill or 'none'
    ellipse
  renderText: (obj, options) ->
    id = @id obj
    unless (wrapper = @dom[id])?
      @root.appendChild @dom[id] = wrapper =
        dom.create 'g', null,
          dataset: id: id
      wrapper.appendChild g = dom.create 'g'
      g.appendChild text = dom.create 'text'
    else
      g = wrapper.firstChild
      text = g.firstChild
    dom.attr g,
      transform: "translate(#{obj.pts[0].x},#{obj.pts[0].y})"
    dom.attr text,
      fill: obj.color
      style: "font-size:#{obj.fontSize}px"
    if options?.text != false or options?.fontSize != false
      ## Remove any leftover TeX expressions
      svgG.remove() while (svgG = g.lastChild) != text
      @texDelete id if @texById[id]?
      content = obj.text
      input = document.getElementById 'textInput'
      ## Extract $math$ and $$display math$$ expressions.
      ## Based loosely on Coauthor's `replaceMathBlocks`.
      maths = []
      latex = (text) =>
        cursorRE = '<tspan\\s+class="cursor">[^<>]*<\\/tspan>'
        mathRE = /// \$(#{cursorRE})\$ | \$\$? | \\. | [{}] ///g
        math = null
        while match = mathRE.exec text
          if math?
            switch match[0]
              when '{'
                math.brace++
              when '}'
                math.brace--
                math.brace = 0 if math.brace < 0  # ignore extra }s
              #when '$', '$$'
              else
                if match[0].startsWith('$') and math.brace <= 0
                  math.formulaEnd = match.index
                  math.end = match.index + match[0].length
                  math.suffix = match[1]
                  maths.push math
                  math = null
          else if match[0].startsWith '$'
            math =
              display: match[0].length > 1
              start: match.index
              formulaStart: match.index + match[0].length
              brace: 0
              prefix: match[1]
        if maths.length
          @texById[id] = jobs = []
          out = [text[...maths[0].start]]
          for math, i in maths
            math.formula = text[math.formulaStart...math.formulaEnd]
            .replace ///#{cursorRE}///, (match) ->
              out.push match
              ''
            .replace /\u00a0/g, ' '  # undo dom.escape
            math.formula = dom.unescape math.formula
            out.push math.prefix if math.prefix?
            out.push "$MATH#{i}$"
            out.push math.suffix if math.suffix?
            math.out = """<tspan data-tex="#{dom.escapeQuote math.formula}" data-display="#{math.display}">&VeryThinSpace;</tspan>"""
            if i < maths.length-1
              out.push text[math.end...maths[i+1].start]
            else
              out.push text[math.end..]
            if job = @tex[[math.formula, math.display]]
              job.texts[id] = true
              if job.svg? # already computed
                do (job) =>
                  setTimeout (=> @texRender job, id), 0
            else
              job = @tex[[math.formula, math.display]] =
                formula: math.formula
                display: math.display
                texts: "#{id}": true
              @texQueue.push job
            jobs.push job
            if @texQueue.length == 1  # added job while idle
              @texInit()
              @texJob()
          out.join ''
        else
          text
      ## Basic Markdown support based on CommonMark and loosely on Slimdown:
      ## https://gist.github.com/jbroadway/2836900
      markdown = (text) ->
        text = text
        .replace /(^|[^\\])(`+)([^]*?)\2/g, (m, pre, left, inner) ->
          "#{pre}<tspan class='code'>#{inner.replace /[`*_~$]/g, '\\$&'}</tspan>"
        text = latex text
        .replace ///
          (^|[\s!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~])  # omitting \\
          (\*+|_+)(\S(?:[^]*?\S)?)\2
          (?=$|[\s!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])
        ///g, (m, pre, left, inner) ->
          "#{pre}<tspan class='#{if left.length > 1 then 'strong' else 'emph'}'>#{inner}</tspan>"
        .replace ///
          (^|[\s!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~])  # omitting \\
          (~~)(\S(?:[^]*?\S)?)\2
          (?=$|[\s!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])
        ///g, (m, pre, left, inner) ->
          "#{pre}<tspan class='strike'>#{inner}</tspan>"
        .replace /\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])/g, "$1"
        .replace /\$MATH(\d+)\$/g, (match, i) ->
          maths[i].out
      if id == pointers.text
        input = document.getElementById 'textInput'
        cursor = input.selectionStart
        if input.value != content  # newer text from server (parallel editing)
          ## If suffix starting at current cursor matches new text, then move
          ## cursor to start at new version of suffix.  Otherwise leave as is.
          suffix = input.value[cursor..]
          if suffix == content[-suffix.length..]
            cursor = content.length - suffix.length
          input.value = content
          setTimeout ->
            input.selectionStart = input.selectionEnd = cursor
          , 0
        content = dom.escape(content[...cursor]) +
                  '<tspan class="cursor">&VeryThinSpace;</tspan>' +
                  dom.escape(content[cursor..])
        g.appendChild pointers.cursor = dom.create 'line',
          class: 'cursor'
          ## 0.05555 is actual size of &VeryThinSpace;, 2 is to exaggerate
          'stroke-width': 2 * 0.05555 * obj.fontSize
          ## 1.2 is to exaggerate
          y1: -0.5 * 1.2 * obj.fontSize
          y2:  0.5 * 1.2 * obj.fontSize
        setTimeout pointers.cursorUpdate = ->
          return unless pointers.cursor?
          bbox = text.querySelector('tspan.cursor').getBBox()
          x = bbox.x + 0.5 * bbox.width
          y = bbox.y + 0.5 * bbox.height
          dom.attr pointers.cursor, transform: "translate(#{x} #{y})"
        , 0
      else
        content = dom.escape content
      content = markdown content
      text.innerHTML = content
    text
    wrapper
  texInit: ->
    return if @tex2svg?
    @tex2svg = new Worker '/tex2svg.js'
    @tex2svg.onmessage = (e) =>
      {formula, display, svg} = e.data
      job = @tex[[formula,display]]
      unless job?
        return console.warn "No job for #{formula},#{display}"
      unless formula == job.formula and display == job.display
        console.warn "Mismatch between #{formula},#{display} and #{job.formula},#{job.display}"
      exScale = 0.523
      exScaler = (match, dimen, value) ->
        "#{dimen}=\"#{job[dimen] = exScale * parseFloat value}\""
      svg = svg
      .replace /\b(width)="([\-\.\d]+)ex"/, exScaler
      .replace /\b(height)="([\-\.\d]+)ex"/, exScaler
      .replace /\bvertical-align:\s*([\-\.\d]+)ex/, (match, depth) ->
        job.depth = -parseFloat depth
        ''
      .replace /<rect\s+data-background="true"/g, "$& fill=\"#f88\""
      job.svg = svg
      for id of job.texts
        @texRender job, id
      @texJob()
  texRender: (job, id) ->
    g = @dom[id].firstChild
    for tspan in g.querySelectorAll """tspan[data-tex="#{CSS.escape job.formula}"][data-display="#{job.display}"]"""
      object = Objects.findOne id
      continue unless object
      fontSize = object.fontSize
      dom.attr tspan, dx: dx = job.width * fontSize
      tspanBBox = tspan.getBBox()
      g.appendChild svgG = dom.create 'g'
      svgG.innerHTML = job.svg
      .replace /currentColor/g, object.color
      x = tspanBBox.x - dx + tspanBBox.width/2  # divvy up &VeryThinSpace;
      ## Roboto Slab in https://opentype.js.org/font-inspector.html:
      unitsPerEm = 1000 # Font Header table
      descender = 271   # Horizontal Header table
      ascender = 1048   # Horizontal Header table
      y = tspanBBox.y + tspanBBox.height * (1 - descender/(descender+ascender))\
        - job.height * fontSize + job.depth * fontSize / 2
        # not sure where the /2 comes from... exFactor?
      dom.attr svgG,
        transform: "translate(#{x} #{y}) scale(#{fontSize})"
    selection.redraw id, @dom[id] if selection.has id
    pointers.cursorUpdate?() if id == pointers.text
  texJob: ->
    return unless @texQueue.length
    @tex2svg.postMessage @texQueue.shift()
  render: (obj, options = {}) ->
    elt =
      switch obj.type
        when 'pen'
          @renderPen obj, options
        when 'poly'
          @renderPoly obj, options
        when 'rect'
          @renderRect obj, options
        when 'ellipse'
          @renderEllipse obj, options
        when 'text'
          @renderText obj, options
        else
          console.warn "No renderer for object of type #{obj.type}"
    if options.translate != false and elt?
      if obj.tx? or obj.ty?
        elt.setAttribute 'transform', "translate(#{obj.tx ? 0} #{obj.ty ? 0})"
      else
        elt.removeAttribute 'transform'
    selection.redraw obj._id, elt if selection.has obj._id
  delete: (obj) ->
    id = @id obj
    unless @dom[id]?
      return console.warn "Attempt to delete unknown object ID #{id}?!"
    @root.removeChild @dom[id]
    delete @dom[id]
    textStop() if id == pointers.text
    @texDelete id if @texById[id]?
  texDelete: (id) ->
    for job in check = @texById[id]
      delete job.texts[id]
    delete @texById[id]
    ## After we potentially rerender text, check for expired cache jobs
    setTimeout =>
      for job in check
        unless (t for t of job.texts).length
          delete @tex[[job.formula, job.display]]
    , 0
  #has: (obj) ->
  #  (id obj) of @dom
  shouldNotExist: (obj) ->
    ###
    Call before rendering a should-be-new object.  If already exists, log a
    warning and clear the object from the map so a new one will get created.
    Currently the old object stays in the DOM, though.
    ###
    id = @id obj
    if id of @dom
      console.warn "Duplicate object with ID #{id}?!"
      delete @dom[id]

render = null
observeRender = ->
  board.clear()
  render = new Render board.root
  board.grid = new Grid board.root
  Objects.find
    room: currentRoom
    page: currentPage
  .observe
    added: (obj) ->
      render.shouldNotExist obj
      render.render obj
    changed: (obj, old) ->
      ## Assuming that pen's `pts` field changes only by appending
      render.render obj,
        start: old.pts.length
        translate: obj.tx != old.tx or obj.ty != old.ty
        color: obj.color != old.color
        width: obj.width != old.width
        text: obj.text != old.text
        fontSize: obj.fontSize != old.fontSize
    removed: (obj) ->
      render.delete obj

class RemotesRender
  constructor: ->
    @elts = {}
    @updated = {}
    @transforms = {}
    @svg = document.getElementById 'remotes'
    @svg.innerHTML = ''
    @svg.appendChild @root = dom.create 'g'
    @resize()
  render: (remote, oldRemote = {}) ->
    id = remote._id
    return if id == remotes.id  # don't show own cursor
    @updated[id] = remote.updated
    ## Omit this in case remoteNow() is inaccurate at startup:
    #return if (timesync.remoteNow() - @updated[id]) / 1000 > remotes.fade
    unless elt = @elts[id]
      @elts[id] = elt = dom.create 'g'
      @root.appendChild elt
    unless remote.tool == oldRemote.tool and remote.color == oldRemote.color
      if icon = tools[remote.tool]?.icon
        if remote.tool of drawingTools
          icon = drawingToolIcon remote.tool,
            (remote.color ? colors[0]), remote.fill
        elt.innerHTML = icons.cursorIcon icon, ...tools[remote.tool].hotspot
      else
        elt.innerHTML = ''
        return  # don't set transform or opacity
    elt.style.visibility =
      if remote.page == currentPage
        'visible'
      else
        'hidden'
    elt.style.opacity = 1 -
      (timesync.remoteNow() - @updated[id]) / 1000 / remotes.fade
    hotspot = tools[remote.tool]?.hotspot ? [0,0]
    minX = (hotspot[0] - remoteIconOutside) * remoteIconSize
    minY = (hotspot[1] - remoteIconOutside) * remoteIconSize
    do @transforms[id] = ->
      maxX = board.bbox.width - (1 - hotspot[0] - remoteIconOutside) * remoteIconSize
      maxY = board.bbox.height - (1 - hotspot[1] - remoteIconOutside) * remoteIconSize
      x = (remote.cursor.x + board.transform.x) * board.transform.scale
      y = (remote.cursor.y + board.transform.y) * board.transform.scale
      unless goodX = (minX <= x <= maxX) and
             goodY = (minY <= y <= maxY)
        x1 = board.bbox.width / 2
        y1 = board.bbox.height / 2
        x2 = x
        y2 = y
        unless goodX
          if x < minX
            x3 = minX
          else if x > maxX
            x3 = maxX
          ## https://mathworld.wolfram.com/Two-PointForm.html
          y3 = y1 + (y2 - y1) / (x2 - x1) * (x3 - x1)
        unless goodY
          if y < minY
            y4 = minY
          else if y > maxY
            y4 = maxY
          x4 = x1 + (x2 - x1) / (y2 - y1) * (y4 - y1)
        if goodX or minX <= x4 <= maxX
          x = x4
          y = y4
        else if goodY or minY <= y3 <= maxY
          x = x3
          y = y3
        else
          x = x3
          y = y3
          if x < minX
            x = minX
          else if x > maxX
            x = maxX
          if y < minY
            y = minY
          else if y > maxY
            y = maxY
      elt.setAttribute 'transform', """
        translate(#{x} #{y})
        scale(#{remoteIconSize})
        translate(#{-hotspot[0]} #{-hotspot[1]})
        scale(#{1/icons.cursorSize})
      """
  delete: (remote) ->
    id = remote._id ? remote
    if elt = @elts[id]
      @root.removeChild elt
      delete @elts[id]
      delete @transforms[id]
  resize: ->
    @svg.setAttribute 'viewBox', "0 0 #{board.bbox.width} #{board.bbox.height}"
    @retransform()
  retransform: ->
    for id, transform of @transforms
      transform()
  timer: (elt, id) ->
    now = timesync.remoteNow()
    for id, elt of @elts
      elt.style.opacity = 1 - (now - @updated[id]) / 1000 / remotes.fade

observeRemotes = ->
  board.remotesRender = new RemotesRender
  Remotes.find
    room: currentRoom
  .observe
    added: (remote) -> board.remotesRender.render remote
    changed: (remote, oldRemote) -> board.remotesRender.render remote, oldRemote
    removed: (remote) -> board.remotesRender.delete remote
setInterval ->
  board.remotesRender?.timer()
, 1000

class Grid
  constructor: (root) ->
    @svg = root.parentNode
    root.appendChild @grid = dom.create 'g', class: 'grid'
    @update()
  update: (mode = currentGrid, bounds) ->
    gridSize = 37.76
    @grid.innerHTML = ''
    bounds ?=
      min: dom.svgPoint @svg, board.bbox.left, board.bbox.top, @grid
      max: dom.svgPoint @svg, board.bbox.right, board.bbox.bottom, @grid
    margin = gridSize
    switch mode
      when true
        far = 10 * gridSize
        range = (xy) ->
          [Math.floor(bounds.min[xy] / gridSize) .. \
           Math.ceil bounds.max[xy] / gridSize]
        for i in range 'x'
          x = i * gridSize
          @grid.appendChild dom.create 'line',
            x1: x
            x2: x
            y1: bounds.min.y - margin
            y2: bounds.max.y + margin
        for j in range 'y'
          y = j * gridSize
          @grid.appendChild dom.create 'line',
            y1: y
            y2: y
            x1: bounds.min.x - margin
            x2: bounds.max.x + margin
      #else

loadingCount = 0
loadingUpdate = (delta) ->
  loadingCount += delta
  loading = document.getElementById 'loading'
  if loadingCount > 0
    loading.classList.add 'loading'
  else
    loading.classList.remove 'loading'
    updateBadRoom()

updateBadRoom = ->
  badRoom = document.getElementById 'badRoom'
  if currentRoom? and Rooms.findOne currentRoom
    badRoom.classList.remove 'show'
  else
    badRoom.classList.add 'show'
    currentRoom = null
    changePage null

subscribe = (...args) ->
  delta = 1
  loadingUpdate delta
  done = ->
    loadingUpdate -delta
    delta = 0
  Meteor.subscribe ...args,
    onReady: done
    onStop: done

roomSub = null
roomObserveObjects = null
roomObserveRemotes = null
roomAuto = null
roomData = null
changeRoom = (room) ->
  return if room == currentRoom
  roomAuto?.stop()
  roomObserve?.stop()
  roomSub?.stop()
  currentRoom = room
  changePage null
  if room?
    roomSub = subscribe 'room', room
  else
    updateBadRoom()
  roomAuto = Tracker.autorun ->
    roomData = Rooms.findOne currentRoom
    unless currentPage?
      changePage roomData?.pages?[0]
    document.getElementById('numPages').innerHTML =
      roomData?.pages?.length ? '?'

pageAuto = null
pageData = null
changePage = (page) ->
  pageAuto?.stop()
  currentPage = page if page?
  tools[currentTool]?.stop?()
  roomObserveObjects?.stop()
  roomObserveRemotes?.stop()
  if currentPage?
    roomObserveObjects = observeRender()
    roomObserveRemotes = observeRemotes()
    document.body.classList.remove 'nopage'
  else
    board.clear()
    document.body.classList.add 'nopage' # in particular, disable pointer events
  updatePageNum()
  selectTool null
  currentGrid = null
  pageAuto = Tracker.autorun ->
    pageData = Pages.findOne currentPage
    if currentGrid != pageData?.grid
      currentGrid = pageData?.grid
      gridTool = document.querySelector '.tool[data-tool="grid"]'
      if currentGrid
        gridTool.classList.add 'active'
      else
        gridTool.classList.remove 'active'
      board.grid?.update()
updatePageNum = ->
  pageNumber = currentPageIndex()
  pageNumber++ if pageNumber?
  document.getElementById('pageNum').value = pageNumber ? '?'
currentPageIndex = ->
  return unless roomData?.pages?
  index = roomData.pages.indexOf currentPage
  return if index < 0
  index

urlChange = ->
  if document.location.pathname == '/'
    Meteor.call 'roomNew',
      grid: gridDefault
    , (error, data) ->
      if error?
        updateBadRoom() # should display visible error message
        return console.error "Failed to create new room on server: #{error}"
      history.replaceState null, 'new room', "/r/#{data.room}"
      urlChange()
  else if match = document.location.pathname.match /^\/r\/(\w*)$/
    changeRoom match[1]
  else
    changeRoom null

paletteTools = ->
  tooltip = null  # currently open tooltip
  removeTooltip = ->
    tooltip?.remove()
    tooltip = null
  toolsDiv = document.getElementById 'tools'
  pagesDiv = document.getElementById 'pages'
  align = 'top'
  for tool, {icon, help, hotkey, init} of tools
    container = if tool.startsWith 'page' then pagesDiv else toolsDiv
    orientation = ''
    if container.classList.contains 'horizontal'
      orientation = 'horizontal'
    else if container.classList.contains 'vertical'
      orientation = 'vertical'
    if tool.startsWith 'spacer'
      container.appendChild dom.create 'div', class: 'spacer'
      align = 'bottom'
    else
      container.appendChild div = dom.create 'div', null,
        className: 'tool'
        dataset: tool: tool
        innerHTML: icons.svgIcon icon
      ,
        click: (e) ->
          removeTooltip()
          selectTool e.currentTarget.dataset.tool
      if help
        if hotkey
          hotkey = [hotkey] unless Array.isArray hotkey
          help += """<span class="hotkeys">"""
          for key in hotkey
            help += """<kbd class="hotkey">#{key}</kbd>"""
            key = key.replace /\s/g, ''
            hotkeys[key] = do (tool) -> -> selectTool tool
          help += """</span>"""
        do (div, align, orientation, help) ->
          dom.listen div,
            pointerenter: ->
              removeTooltip()
              divBBox = div.getBoundingClientRect()
              document.body.appendChild tooltip = dom.create 'div', null,
                className: "tooltip #{align} #{orientation}"
                innerHTML: help
                style:
                  if orientation == 'vertical'
                    if align == 'top'
                      top: "#{divBBox.top}px"
                    else # bottom
                      bottom: "calc(100% - #{divBBox.bottom}px)"
                  else # horizontal
                    left: "calc(#{divBBox.left + 0.5 * divBBox.width}px - 0.5 * var(--tooltip-width))"
              ,
                pointerenter: removeTooltip
            pointerleave: removeTooltip
      init?()

lastTool = null
selectTool = (tool) ->
  if tools[tool]?.once?
    return tools[tool].once?()
  tools[currentTool]?.stop?()
  document.body.classList.remove "tool-#{currentTool}" if currentTool
  if tool == currentTool == 'history'  # treat history as a toggle
    tool = lastTool
  if tool?  # tool == null means initialize already set currentTool
    lastTool = currentTool
    currentTool = tool
  dom.select '.tool', "[data-tool='#{currentTool}']"
  if currentTool of drawingTools
    selectColor() # set color-specific icon
  else if currentTool == 'history'
    icons.setCursor document.getElementById('historyRange'),
      tools['history'].icon, ...tools['history'].hotspot
    icons.setCursor document.getElementById('historyBoard'),
      tools['pan'].icon, ...tools['pan'].hotspot
  else
    # Deselect color and width if not in pen mode
    #dom.select '.color'
    #dom.select '.width'
    icons.setCursor board.svg, tools[currentTool].icon,
      ...tools[currentTool].hotspot
  pointers = {}  # tool-specific data
  tools[currentTool]?.start?()
  document.body.classList.add "tool-#{currentTool}" if currentTool
  lastDrawingTool = currentTool if currentTool of drawingTools
selectDrawingTool = ->
  unless currentTool of drawingTools
    selectTool lastDrawingTool

paletteFill = ->
  document.getElementById('fillOn').innerHTML =
    icons.svgIcon icons.modIcon 'tint', fill: 'currentColor'
  document.getElementById('fillOff').innerHTML =
    icons.svgIcon icons.modIcon 'tint-slash', fill: 'currentColor'
  dom.listen document.getElementById('fillTool'),
    click: (e) ->
      currentFillOn = not currentFillOn
      updateFill()
  updateFill()
updateFill = ->
  document.getElementById('fillOn').style.display =
    if currentFillOn then 'block' else 'none'
  document.getElementById('fillOff').style.display =
    if currentFillOn then 'none' else 'block'
  document.getElementById('fillTool').style.color = currentFill
  colorIcon()

paletteColors = ->
  colorsDiv = document.getElementById 'colors'
  for color in colors
    colorsDiv.appendChild dom.create 'div', null,
      className: 'color attrib'
      style: backgroundColor: color
      dataset: color: color
    ,
      click: (e) ->
        (if e.shiftKey then selectFill else selectColor) \
          e.currentTarget.dataset.color

widthSize = 22
paletteWidths = ->
  widthsDiv = document.getElementById 'widths'
  for width in widths
    widthsDiv.appendChild dom.create 'div', null,
      className: 'width attrib'
      dataset: width: width
    ,
      click: (e) -> selectWidth e.currentTarget.dataset.width
    , [
      dom.create 'svg',
        viewBox: "0 #{-widthSize/3} #{widthSize} #{widthSize}"
        width: widthSize
        height: widthSize
      , null, null
      , [
        dom.create 'line',
          x2: widthSize
          'stroke-width': width
        dom.create 'text',
          class: 'label'
          x: widthSize/2
          y: widthSize*2/3
        , null, null, [
          document.createTextNode "#{width}"
        ]
      ]
    ]

fontSizeSize = 28
paletteFontSizes = ->
  fontSizesDiv = document.getElementById 'fontSizes'
  for fontSize in fontSizes
    fontSizesDiv.appendChild dom.create 'div', null,
      className: 'fontSize attrib'
      dataset: fontSize: fontSize
    ,
      click: (e) -> selectFontSize e.currentTarget.dataset.fontSize
    , [
      dom.create 'svg',
        viewBox: "#{-fontSizeSize/2} 0 #{fontSizeSize} #{fontSizeSize}"
        width: fontSizeSize
        height: fontSizeSize
      , null, null
      , [
        dom.create 'text',
          y: fontSizeSize*0.5
          style: "font-size:#{fontSize}px"
        , null, null, [
          document.createTextNode 'A'
        ]
        dom.create 'text',
          class: 'label'
          y: fontSizeSize*0.875
        , null, null, [
          document.createTextNode "#{fontSize}"
        ]
      ]
    ]

drawingToolIcon = (tool, color, fill) ->
  icon = tools[tool]?.icon
  return icon unless icon?
  attr = fill: color
  if tool == 'pen' or color == 'white'
    Object.assign attr,
      stroke: 'black'
      'stroke-width': '15'
      'stroke-linecap': 'round'
      'stroke-linejoin': 'round'
  icon = icons.modIcon icon, attr
  if fill and iconFill = tools[tool].iconFill
    icon = icons.stackIcons [icon, icons.modIcon iconFill, fill: fill]
  icon

selectColor = (color, keepTool) ->
  currentColor = color if color?
  dom.select '.color', "[data-color='#{currentColor}']"
  document.documentElement.style.setProperty '--currentColor', currentColor
  if selection.nonempty()
    selection.edit 'color', currentColor
    keepTool = true
  selectDrawingTool() unless keepTool
  colorIcon()

colorIcon = ->
  ## Drawing tools' cursors depend on the current color
  if currentTool of drawingTools
    icons.setCursor board.svg,
      drawingToolIcon(currentTool, currentColor,
        if currentFillOn then currentFill),
      ...tools[currentTool].hotspot

selectFill = (color) ->
  currentFill = color
  currentFillOn = true
  updateFill()
  if selection.nonempty()
    selection.edit 'fill', currentFill
  else
    selectDrawingTool()

selectWidth = (width, keepTool) ->
  currentWidth = parseFloat width if width?
  if selection.nonempty()
    selection.edit 'width', currentWidth
    keepTool = true
  selectDrawingTool() unless keepTool
  dom.select '.width', "[data-width='#{currentWidth}']"

selectFontSize = (fontSize) ->
  currentFontSize = parseFloat fontSize if fontSize?
  if selection.nonempty()
    selection.edit 'fontSize', currentFontSize
  dom.select '.fontSize', "[data-font-size='#{currentFontSize}']"

paletteSize = ->
  parseFloat (getComputedStyle document.documentElement
  .getPropertyValue '--palette-size')

resize = (reps = 1) ->
  tooltip?.remove()
  for [id, attrib, dimen] in [
    ['tools', '--palette-left-width', 'Width']
    ['attribs', '--palette-bottom-height', 'Height']
    ['pages', '--palette-top-height', 'Height']
  ]
    div = document.getElementById id
    if 0 <= attrib.indexOf 'width'
      scrollbar = div.offsetWidth - div.clientWidth
    else if 0 <= attrib.indexOf 'height'
      scrollbar = div.offsetHeight - div.clientHeight
    document.documentElement.style.setProperty attrib,
      "#{scrollbar + paletteSize()}px"
  board.resize()
  setTimeout (-> resize reps-1), 0 if reps

Meteor.startup ->
  document.getElementById('loading').innerHTML = icons.svgIcon 'spinner'
  board = new Board 'board'
  historyBoard = new Board 'historyBoard'
  paletteTools()
  paletteWidths()
  paletteFontSizes()
  paletteFill()
  paletteColors()
  selectTool()
  selectColor null, true
  selectWidth null, true
  selectFontSize null
  pointerEvents()
  dom.listen window,
    resize: resize
    popstate: urlChange
  , true # call now
  spaceDown = false
  dom.listen window,
    keydown: (e) ->
      switch e.key
        when 'z', 'Z'
          if e.ctrlKey or e.metaKey
            if e.shiftKey
              redo()
            else
              undo()
        when 'y', 'Y'
          if e.ctrlKey or e.metaKey
            redo()
        when 'Delete', 'Backspace'
          selection.delete()
        when ' '
          if currentTool not in ['pan', 'history']
            spaceDown = true
            selectTool 'pan'
        else
          if e.key of hotkeys
            hotkeys[e.key]()
          else
            hotkeys[e.key.toLowerCase()]?()
    keyup: (e) ->
      switch e.key
        when ' '
          if spaceDown
            selectTool lastTool
            spaceDown = false
  dom.listen pageNum = document.getElementById('pageNum'),
    keydown: (e) ->
      e.stopPropagation() # avoid width setting hotkey
    change: (e) ->
      return unless roomData?.pages?.length
      page = parseInt pageNum.value
      if isNaN page
        updatePageNum()
      else
        page = Math.min roomData.pages.length, Math.max 1, page
        changePage roomData.pages[page-1]
  document.getElementById('roomLinkStyle').innerHTML =
    Meteor.absoluteUrl 'r/ABCD23456789vwxyz'
  document.getElementById('newRoomLink').setAttribute 'href',
    Meteor.absoluteUrl()

## Cocreate doesn't perform great in combination with Meteor DevTools;
## prevent it from applying its hooks.
window.__devtools = true
