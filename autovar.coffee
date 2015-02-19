class J.AutoVar
    class @COMPUTING extends Error
        constructor: ->
            @name = "J.AutoVar.COMPUTING"
            @message = "Value will be available later in the computation."

    @makeComputingObject: ->
        # The commented-out lines are kinda helpful
        # for debugging but slow as hell.
        # e = Error()
        obj = new @COMPUTING
        obj.isServer = Meteor.isServer
        # obj.stack = e.stack
        obj

    @getFirstActiveAncestor = (comp) ->
        if comp is null
            null
        else if not comp.stopped
            comp
        else if comp.autoVar
            @getFirstActiveAncestor comp.creator
        else
            null


    constructor: (tag, valueFunc, onChange, options) ->
        ###
            AutoVars default to being "lazy", i.e. not calculated
            until .get().

            onChange:
                A function to call with (oldValue, newValue) when
                the value changes.
                May also pass onChange=true or null.
                If onChange is either a function or true, the
                AutoVar becomes non-lazy.

            options:
                creator: Set a different creator computation.
        ###

        unless @ instanceof J.AutoVar
            return new J.AutoVar tag, valueFunc, onChange, options

        if _.isFunction tag
            # Alternate signature: J.AutoVar(valueFunc, onChange, options)
            options = onChange
            onChange = valueFunc
            valueFunc = tag
            tag = undefined

        unless _.isFunction(valueFunc)
            throw new Meteor.Error "AutoVar must be constructed with valueFunc"

        unless not onChange? or _.isFunction(onChange) or onChange is true
            throw new Meteor.Error "AutoVar onChange must be either null or a function
                or true (true simply forces non-lazy first evaluation): #{onChange}"

        @_id = J.getNextId()
        if J.debugGraph then J.graph[@_id] = @

        @tag = tag
        @valueFunc = valueFunc
        @onChange = onChange ? null
        if options?.creator is undefined
            @creator = Tracker.currentComputation
        else
            @creator = options.creator

        # We can't use @_valueComp.invalidated because when @_valueComp
        # invalidates itself, it schedules it to happen at afterFlush time.
        @_invalidated = false

        @_invalidAncestors = {} # autoVarId: autoVar

        @_active = true
        @creator?.onInvalidate =>
            @stop()

        @_var = null
        @_valueComp = null
        if @onChange
            # Truthy onChange means do a non-lazy first run
            # of valueFunc.
            Tracker.afterFlush =>
                if @isActive() and not @_valueComp?
                    @_setupValueComp()


    _addInvalidAncestor: (autoVar) ->
        @_invalidAncestors[autoVar._id] = autoVar
        for compId, comp of @_var._getters
            comp.autoVar?._addInvalidAncestor autoVar


    _removeInvalidAncestor: (autoVar) ->
        delete @_invalidAncestors[autoVar._id]
        for compId, comp of @_var._getters
            comp.autoVar?._removeInvalidAncestor autoVar


    _setupValueComp: ->
        Tracker.nonreactive => Tracker.autorun (c) =>
            if c.firstRun
                # Important to do this here in case @stop() is called during the
                # first run of the computation.
                @_valueComp = c
                @_valueComp.autoVar = @
                @_valueComp.tag = "#{@toString()} valueComp"

                @_var = new J.Var J.makeValueNotReadyObject(),
                    tag:
                        autoVar: @
                        tag: "Var for AutoVar[#{@_id}](#{J.util.stringifyTag @tag})"
                    creator: @_valueComp
                    onChange: if _.isFunction @onChange then @onChange

            @_invalidated = false

            @_valueComp.onInvalidate =>
                # A different computation invalidated this one
                @_invalidated = true

                # console.log "invalidated", @toString()

                @_invalidAncestors = {}
                if @_active
                    @_addInvalidAncestor @

            # console.log "Recomputing ", @toString()
            try
                # ValueFunc may either return or throw J.Var.NOT_READY
                # or throw @COMPUTING. It may not return undefined.
                value = @valueFunc.call null, @

            catch e
                if e instanceof J.VALUE_NOT_READY
                    @_removeInvalidAncestor @
                    @_var.set e
                    return

                else if e instanceof @constructor.COMPUTING
                    # console.log "...", @toString(), "got COMPUTING"
                    # We want @_valueComp to invalidate itself, but we want
                    # the recalculation to happen at the end of the flush
                    # queue (FIFO flushing), not right away. That's why
                    # we're using afterFlush.
                    @_invalidated = true
                    Tracker.afterFlush =>
                        # Check if we're still invalidated because we might have
                        # been recomputed already.
                        if @_invalidated then @_valueComp.invalidate()
                    return

                else
                    throw e

            if value is undefined
                throw new Meteor.Error "#{@toString()}.valueFunc must not return undefined."

            # console.log "...", @toString(), "recomputed: ", value

            @_removeInvalidAncestor @
            if @_valueComp.stopped
                # It's kosher for a valueFunc to call stop() on its own AutoVar.
            else
                @_var.set value


    debug: ->
        console.log @toString()


    get: ->
        if arguments.length
            throw new Meteor.Error "Can't pass argument to AutoVar.get"

        if Meteor.isServer and J._inMethod.get()
            # We're just using the Var to wrap the value, e.g.
            # array becomes J.List.
            return J.Var(@valueFunc.call null, @).get()

        if not @isActive()
            ancestorComp = @constructor.getFirstActiveAncestor @creator
            if ancestorComp
                # There's an active ancestor, so there's a chance
                # that the function trying to get us will succeed
                # next time. That's why we can say we're "computing".
                if Tracker.active
                    throw @constructor.makeComputingObject()
                else
                    return undefined
            else
                console.error()
                throw new Meteor.Error "#{@constructor.name} ##{@_id} is stopped: #{@}."

        if not @_valueComp?
            # console.log "GET", @toString(), "[first time]"
            # Getting a lazy AutoVar for the first time
            @_setupValueComp()
            # if @_valueComp.invalidated then console.log "#{@toString()} invalidated during first get!"
        else
            # console.log J.util.stringifyTag(Tracker.currentComputation?.tag), "GET", @toString() + (if @_valueComp.invalidated then "(invalidated)" else '')

        if @currentValueMightChange()
            if Tracker.active
                throw @constructor.makeComputingObject()
            else
                return undefined

        @_var.get()


    isActive: ->
        @_active


    currentValueMightChange: ->
        # Returns true if @_var.value might change between now
        # and the end of the current flush (or the end of
        # hypothetically calling Tracker.flush() now).
        # Note that true doesn't mean the current value
        # *will* change. It's possible that all invalidated
        # dependency values will recompute themselves to have
        # the same value, and thereby stop @_valueComp from
        # ever invalidating.

        ret = not (@_valueComp? and _.isEmpty @_invalidAncestors)

        if ret
            J.inc 'cmvcTrue'
        else
            J.inc 'cmvcFalse'

        ret


    set: ->
        throw new Meteor.Error "There is no AutoVar.set"


    stop: ->
        if @_active
            @_active = false
            @_valueComp?.stop()


    toString: ->
        s = "AutoVar[#{J.util.stringifyTag @tag ? ''}##{@_id}]=#{J.util.stringify @_var?._value}"
        if not @isActive() then s += " (inactive)"
        s