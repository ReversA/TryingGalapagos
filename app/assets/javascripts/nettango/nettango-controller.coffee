class window.NetTangoController

  constructor: (element, localStorage, @overlay, @playMode, @theOutsideWorld) ->
    @storage = new NetTangoStorage(localStorage)
    Mousetrap.bind(['ctrl+shift+e', 'command+shift+e'], () => @exportNetTango('json'))

    @ractive = @createRactive(element, @theOutsideWorld, @playMode)

    # If you have custom components that will be needed inside partial templates loaded dynamically at runtime
    # such as with the `RactiveArrayView`, you can specify them here.  -Jeremy B August 2019
    Ractive.components.attribute = RactiveNetTangoAttribute

    @ractive.on('*.ntb-save',         (_, code)        => @exportNetTango('storage'))
    @ractive.on('*.ntb-recompile',    (_, code)        => @setNetTangoCode(code))
    @ractive.on('*.ntb-model-change', (_, title, code) => @setNetLogoCode(title, code))
    @ractive.on('*.ntb-code-dirty',   (_)              => @markCodeDirty())
    @ractive.on('*.ntb-export-page',  (_)              => @exportNetTango('standalone'))
    @ractive.on('*.ntb-export-json',  (_)              => @exportNetTango('json'))
    @ractive.on('*.ntb-import-json',  (local)          => @importNetTango(local.node.files))
    @ractive.on('*.ntb-load-data',    (_, data)        => @builder.load(data))
    @ractive.on('*.ntb-run',          (_, command)     =>
      @theOutsideWorld.getWidgetController().ractive.fire("run", command))

  getTestingDefaults: () ->
    if (@playMode)
      Ractive.extend({ })
    else
      RactiveNetTangoTestingDefaults

  createRactive: (element, theOutsideWorld, playMode) ->

    new Ractive({

      el: element,

      data: () -> {
        findElement:   theOutsideWorld.getElementById, # (String) => Element
        createElement: theOutsideWorld.createElement,  # (String) => Element
        appendElement: theOutsideWorld.appendElement,  # (Element) => Unit
        newModel:      theOutsideWorld.newModel,       # () => String
        playMode:      playMode,                       # Boolean
        popupMenu:     undefined                       # RactivePopupMenu
      }

      on: {

        'complete': (_) ->
          popupMenu = @findComponent('popupmenu')
          @set('popupMenu', popupMenu)

          theOutsideWorld.addEventListener('click', (event) ->
            if event?.button isnt 2
              popupMenu.unpop()
          )

          return
      }

      components: {
          popupmenu:       RactivePopupMenu
        , tangoBuilder:    RactiveNetTangoBuilder
        , testingDefaults: @getTestingDefaults()
      },

      template:
        """
        <popupmenu></popupmenu>
        <tangoBuilder
          playMode='{{ playMode }}'
          findElement='{{ findElement }}'
          createElement='{{ createElement }}'
          appendElement='{{ appendElement }}'
          newModel='{{ newModel }}'
          popupMenu='{{ popupMenu }}'
          />
          {{# !playMode }}
            <testingDefaults />
          {{/}}
        """

    })

  getNetTangoCode: () ->
    defs = @ractive.findComponent('tangoDefs')
    defs.assembleCode()

  createBlockVariables: (spaceId, block) ->
    childVariables     = (block.children ? []).flatMap( (child)  => @createBlockVariables(spaceId, child) )
    clauseVariables    = (block.clauses  ? []).flatMap( (clause) => @createBlockVariables(spaceId, clause) )
    attributeVariables = (block.params   ? []).concat(block.properties ? []).map( (p) ->
      "nt:set \"__#{spaceId}-canvas_#{block.id}_#{block.instanceId}_#{p.id}\" (#{p.value})"
    )
    attributeVariables.concat(childVariables).concat(clauseVariables)

  createSpaceVariables: (spaces) ->
    spaces.flatMap( (space) =>
      if (not space.defs.program? or not space.defs.program.chains?)
        return []
      space.defs.program.chains.flatMap( (chain) =>
        chain.flatMap( (block) => @createBlockVariables(space.spaceId, block) )
      )
    )

  addNetTangoExtension: (code) ->
    declarationCheck = /([\s\S]*^\s*extensions(?:\s|;.*\n)*\[)([\s\S]*)/mgi
    declaration = declarationCheck.exec(code)
    if (not declaration?)
      return "extensions [ nt ]\n#{code}"

    extensionCheck = /^\s*extensions(?:\s|;.*\n)*\[(?:\s|;.*\n|\w+)*\bnt\b/mgi
    extension = extensionCheck.test(code)
    if (extension)
      return code

    return "#{declaration[1]} nt #{declaration[2]}"

  rewriteNetLogoCode: (code) ->
    alteredCode  = @addNetTangoExtension(code)
    netTangoCode = @getNetTangoCode()
    "#{alteredCode}\n\n#{netTangoCode}\n"

  getNetLogoRewriter: () ->
    {
      compileComplete: ()      => @updateAttributeValues(),
      injectCode:      (code)  => @rewriteNetLogoCode(code),
      injectNlogo:     (nlogo) =>
        sections    = Tortoise.nlogoToSections(nlogo)
        sections[0] = @rewriteNetLogoCode(sections[0])
        Tortoise.sectionsToNlogo(sections)
    }

  # This is a debugging method to get a view of the altered code output that
  # NetLogo will compile
  getRewrittenCode: () ->
    code = @theOutsideWorld.getWidgetController().code()
    @rewriteNetLogoCode(code)

  # () => Unit
  recompile: () =>
    defs = @ractive.findComponent('tangoDefs')
    defs.recompile()
    return

  # Runs any updates needed for old versions, then loads the model normally.
  # If this starts to get more complicated, it should be split out into
  # separate version updates. -Jeremy B October 2019
  loadExternalModel: (netTangoModel) =>
    if (netTangoModel.code?)
      netTangoModel.code = NetTangoController.removeOldNetTangoCode(netTangoModel.code)
    @builder.load(netTangoModel)
    return

  # () => Unit
  onModelLoad: (modelUrl) =>
    @builder = @ractive.findComponent('tangoBuilder')
    progress = @storage.inProgress

    # first try to load from the inline code element
    netTangoCodeElement = @theOutsideWorld.getElementById("ntango-code")
    if (netTangoCodeElement? and netTangoCodeElement.textContent? and netTangoCodeElement.textContent isnt "")
      data = JSON.parse(netTangoCodeElement.textContent)
      @storageId = data.storageId
      if (@playMode and @storageId? and progress? and progress.playProgress? and progress.playProgress[@storageId]?)
        progress    = progress.playProgress[@storageId]
        data.spaces = progress.spaces
      @loadExternalModel(data)
      return

    # next check the URL parameter
    if (modelUrl?)
      fetch(modelUrl)
      .then( (response) ->
        if (not response.ok)
          throw new Error("#{response.status} - #{response.statusText}")
        response.json()
      )
      .then( (netTangoModel) =>
        @loadExternalModel(netTangoModel)
      ).catch( (error) =>
        netLogoLoading = @theOutsideWorld.getElementById("loading-overlay")
        netLogoLoading.style.display = "none"
        @showErrors([
          "Error: Unable to load NetTango model from the given URL."
          "Make sure the URL is correct, that there are no network issues, and that CORS access is permitted.",
          "",
          "URL: #{modelUrl}",
          "",
          error
        ])
      )
      return

    # finally local storage
    if (progress?)
      @loadExternalModel(progress)
      return

    # nothing to load, so just refresh and be done
    @builder.refreshCss()
    return

  # () => Unit
  markCodeDirty: () ->
    @enableRecompileOverlay()
    widgetController = @theOutsideWorld.getWidgetController()
    widgets = widgetController.ractive.get('widgetObj')
    @pauseForevers(widgets)
    @spaceChangeListener?()
    return

  # (String) => Unit
  setNetTangoCode: (_) ->
    widgetController = @theOutsideWorld.getWidgetController()
    @hideRecompileOverlay()
    widgetController.ractive.fire('recompile', () =>
      widgets = widgetController.ractive.get('widgetObj')
      @rerunForevers(widgets)
    )
    return

  updateAttributeValues: () ->
    widgetController  = @theOutsideWorld.getWidgetController()
    defs              = @ractive.findComponent('tangoDefs')
    attributeCommands = @createSpaceVariables(defs.get("spaces")).join(" ")
    widgetController.ractive.fire("run", attributeCommands)
    return

  setNetLogoCode: (title, code) ->
    @theOutsideWorld.setModelCode(code, title)
    return

  # (Array[File]) => Unit
  importNetTango: (files) ->
    if (not files? or files.length is 0)
      return
    reader = new FileReader()
    reader.onload = (e) =>
      ntData = JSON.parse(e.target.result)
      @loadExternalModel(ntData)
      return
    reader.readAsText(files[0])
    return

  # (String) => Unit
  exportNetTango: (target) ->
    title = @theOutsideWorld.getModelTitle()

    modelCodeMaybe = @theOutsideWorld.getModelCode()
    if(not modelCodeMaybe.success)
      throw new Error("Unable to get existing NetLogo code for export")

    netTangoData       = @builder.getNetTangoBuilderData()
    netTangoData.code  = modelCodeMaybe.result
    netTangoData.title = title

    # Always store for 'storage' target - JMB August 2018
    @storeNetTangoData(netTangoData)

    if (target is 'storage')
      return

    if (target is 'json')
      @exportJSON(title, netTangoData)
      return

    # Else target is 'standalone' - JMB August 2018
    parser      = new DOMParser()
    ntPlayer    = new Request('./ntango-play-standalone')
    playerFetch = fetch(ntPlayer).then( (ntResp) ->
      if (not ntResp.ok)
        throw Error(ntResp)
      ntResp.text()
    ).then( (text) ->
      parser.parseFromString(text, 'text/html')
    ).then( (exportDom) =>
      @exportStandalone(title, exportDom, netTangoData)
    ).catch((error) =>
      @showErrors([ "Unexpected error:  Unable to generate the stand-alone NetTango page." ])
    )
    return

  # () => String
  @generateStorageId: () ->
    "ntb-#{Math.random().toString().slice(2).slice(0, 10)}"

  # (String, Document, NetTangoBuilderData) => Unit
  exportStandalone: (title, exportDom, netTangoData) ->
    netTangoData.storageId = NetTangoController.generateStorageId()

    netTangoCodeElement = exportDom.getElementById('ntango-code')
    netTangoCodeElement.textContent = JSON.stringify(netTangoData)

    styleElement = @theOutsideWorld.getElementById('ntb-injected-style')
    if (styleElement?)
      newElement = exportDom.createElement('style')
      newElement.id = 'ntb-injected-style'
      newElement.innerHTML = @builder.compileCss(true, @builder.get('extraCss'))
      exportDom.head.appendChild(newElement)

    exportWrapper = @theOutsideWorld.createElement('div')
    exportWrapper.appendChild(exportDom.documentElement)
    exportBlob = new Blob([exportWrapper.innerHTML], { type: 'text/html:charset=utf-8' })
    @theOutsideWorld.saveAs(exportBlob, "#{title}.html")
    return

  # (String, NetTangoBuilderData) => Unit
  exportJSON: (title, netTangoData) ->
    filter = (k, v) -> if (k is 'defsJson') then undefined else v
    jsonBlob = new Blob([JSON.stringify(netTangoData, filter)], { type: 'text/json:charset=utf-8' })
    @theOutsideWorld.saveAs(jsonBlob, "#{title}.ntjson")
    return

  # (NetTangoBuilderData) => Unit
  storeNetTangoData: (netTangoData) ->
    set = (prop) => @storage.set(prop, netTangoData[prop])
    [ 'code', 'title', 'extraCss', 'spaces', 'tabOptions', 'netTangoToggles' ].forEach(set)
    return

  # () => Unit
  storePlayProgress: () ->
    netTangoData             = @builder.getNetTangoBuilderData()
    playProgress             = @storage.get('playProgress') ? { }
    builderCode              = @getNetTangoCode()
    progress                 = { spaces: netTangoData.spaces, code: builderCode }
    playProgress[@storageId] = progress
    @storage.set('playProgress', playProgress)
    return

  # (() => Unit) => Unit
  setSpaceChangeListener: (f) ->
    @spaceChangeListener = f
    return

  # () => Unit
  enableRecompileOverlay: () ->
    @overlay.style.display = "flex"
    return

  # () => Unit
  hideRecompileOverlay: () ->
    @overlay.style.display = ""
    return

  # (Array[Widget]) => Unit
  pauseForevers: (widgets) ->
    if not @runningIndices? or @runningIndices.length is 0
      @runningIndices = Object.getOwnPropertyNames(widgets)
        .filter( (index) ->
          widget = widgets[index]
          widget.type is "button" and widget.forever and widget.running
        )
      @runningIndices.forEach( (index) -> widgets[index].running = false )
    return

  # (Array[Widget]) => Unit
  rerunForevers: (widgets) ->
    if @runningIndices? and @runningIndices.length > 0
      @runningIndices.forEach( (index) -> widgets[index].running = true )
    @runningIndices = []
    return

  # (String) => Unit
  showErrors: (messages) ->
    display = @ractive.findComponent('errorDisplay')
    display.show(messages.join("<br/>"))

  # (String) => String
  @removeOldNetTangoCode: (code) ->
    BEGIN = "; --- NETTANGO BEGIN ---"
    END   = "; --- NETTANGO END ---"
    code.replace(new RegExp("((?:^|\n)#{BEGIN}\n)([^]*)(\n#{END})"), "")
