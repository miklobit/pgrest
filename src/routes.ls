
export function route (path, fn)
  (req, resp) ->
    # TODO: Content-Negotiate into CSV
    return resp.send 200 if req.method is \OPTION
    resp.setHeader \Content-Type 'application/json; charset=UTF-8'
    done = -> switch typeof it
      | \number => resp.send it
      | \object => resp.send 200 JSON.stringify it
      | \string => resp.send "#it"
    handle-error = ->
      it.=message if it instanceof Error
      it -= /^Error: / if \string is typeof it
      switch typeof it
      | \number => resp.send it, { error: it }
      | \object => resp.send 500 it
      | \string => (if it is /^\d\d\d$/
        then resp.send it, { error: it }
        else resp.send 500 { error: "#it" })
      | _       => resp.send 500 { error: "#it" }
    require! trycatch
    trycatch do
      -> fn.call req, ->
        if it?error
          handle-error that
        else
          done it
      handle-error

export function with-prefix (prefix, cb)
  (path, fn) ->
    fullpath = if path? then "#{
        switch path.0
        | void => prefix
        | '/'  => ''
        | _    => "#prefix/"
      }#path" else prefix - //[^/]+/?$//
    cb fullpath, route path, fn

export function derive-type (content, type)
  TypeMap = Boolean: \boolean, Number: \numeric, String: \text, Array: 'text[]', Object: \plv8x.json
  if \Array is typeof! content
    # XXX plv8x.json[] does not work
    return ((TypeMap[typeof! content.0] || \plv8x.json) + '[]') - /^plv8x\./
  TypeMap[typeof! content] || \plv8x.json

export function mount-auth (plx, app, middleware, config, cb_after_auth, cb_logout)
  require! passport
  passport.serializeUser (user, done) -> done null, user
  passport.deserializeUser (id, done) -> done null, id

  default_cb_logout = (req, res) ->
    console.log "user logout"
    req.logout!
    res.redirect config.auth.logout_redirect

  default_cb_after_auth = (token, tokenSecret, profile, done) ->
    <- plx.query """
      CREATE TABLE IF NOT EXISTS users (
        _id SERIAL UNIQUE,
        provider_name TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        username TEXT,
        name JSON,
        display_name TEXT,
        emails JSON,
        photos JSON,
        tokens JSON
    );
    """
    user = do
      provider_name: profile.provider
      provider_id: profile.id
      username: profile.username
      name: profile.name
      emails: profile.emails
      photos: profile.photos
    console.log "user #{user.username} authzed by #{user.provider_name}.#{user.provider_id}"
    #@FIXME: need to merge multiple authoziation profiles
    param = [collection: \users, q:{provider_id:user.provider_id, provider_name:user.provider_name}]
    [pgrest_select:res] <- plx.query "select pgrest_select($1)", param
    if res.paging.count == 0
      [pgrest_insert:res] <- plx.query "select pgrest_insert($1)", [collection: \users, $: [user]]
    [pgrest_select:res] <- plx.query "select pgrest_select($1)", param
    user.auth_id = res.entries[0]['_id']
    console.log user
    done null, user

  for provider_name in config.auth.plugins
    provider_cfg = config.auth.providers_settings[provider_name]
    throw "#{provider_name} settings is required" unless provider_cfg
    console.log "enable auth #{provider_name}"
    # passport settings
    provider_cfg['callbackURL'] = "http://#{config.host}:#{config.port}/auth/#{provider_name}/callback"
    console.log provider_cfg
    module_name = switch provider_name
                  case \google then "passport-google-oauth"
                  default "passport-#{provider_name}"
    _Strategy = require(module_name).Strategy
    passport.use new _Strategy provider_cfg, if cb_after_auth? then cb_after_auth else default_cb_after_auth
    # register auth endpoint
    app.get "/auth/#{provider_name}", (passport.authenticate "#{provider_name}", provider_cfg.scope)
    _auth = passport.authenticate "#{provider_name}", do
      successRedirect: config.auth.success_redirect or '/'
      failureRedirect: "/auth/#{provider_name}"
    app.get "/auth/#{provider_name}/callback", _auth

  app.get "/loggedin", middleware, (req, res) ->
    if req.pgparam.auth? then res.send true else res.send false
  app.get "/logout", middleware, if cb_logout? then cb_logout else default_cb_logout
  app

locate_record = (plx, schema, name, id) ->
  collection = "#schema.#name"
  primary = plx.config?meta?[collection]?.primary
  q = if primary
    if \function is typeof primary
      primary id
    else
      "#primary": id
  else
    # XXX: derive
    _id: id
  {collection, q, +fo}

export function mount-model (plx, schema, name, _route=route)
  _route "#name" !->
    param = @query{ l, sk, c, s, q, fo, f, u, delay } <<< collection: "#schema.#name"
    method = switch @method
    | \GET    => \select
    | \POST   => \insert
    | \PUT    => (if param.u then \upsert else \replace)
    | \DELETE => \remove
    | _       => throw 405
    param.$ = @body # TODO: Accept CSV as PUT/POST Content-Type
    param.pgparam = @pgparam
    # text/csv;header=present
    # text/csv;header=absent
    plx[method].call plx, param, it, (error) ->
      if error is /Stream unexpectedly ended/
        console.log \TODOreconnect
      it { error }
  _route "#name/:_id" !->
    param = locate_record plx, schema, name, @params._id
    method = switch @method
    | \GET    => \select
    | \PUT    => \upsert
    | \DELETE => \remove
    | _       => throw 405
    param.$ = @body
    param.pgparam = @pgparam
    plx[method].call plx, param, it, (error) -> it { error }
  _route "#name/:_id/:column" !(send)->
    param = locate_record plx, schema, name, @params._id
    method = switch @method
    | \GET    => \select
    | _       => throw 405
    param.f = "#{@params.column}": 1
    param.pgparam = @pgparam
    record <~ plx[method].call plx, param, _, (error) -> send { error }
    send record[@params.column]
  return name

export function mount-default (plx, schema, _route=route, cb)
  schema-cond = if schema
      "IN ('#{schema}')"
  else
      "NOT IN ( 'information_schema', 'pg_catalog', 'plv8x')"

  # Generic JSON routing helper

  rows <- plx.query """
    SELECT t.table_schema scm, t.table_name tbl FROM INFORMATION_SCHEMA.TABLES t WHERE t.table_schema #schema-cond;
  """
  seen = {}
  default-schema = null
  cols = for {scm, tbl} in rows
    schema ||= scm
    if seen[tbl]
      console.log "#scm.#tbl not loaded, #tbl already in use"
    else
      seen[tbl] = true
      mount-model plx, scm, tbl, _route
  default-schema ?= \public

  _route null, -> it <[ collections runCommand ]>
  _route "", !(done) -> done cols
  _route ":name", !(done) ->
    throw 404 if @method in <[ GET DELETE ]> # TODO: If not exist, remount
    throw 405 if @method not in <[ POST PUT ]>
    { name } = @params
    # Non-existing collection - Autovivify it
    # Strategy: Enumerate all unique columns & data types, and CREATE TABLE accordingly.
    $ = if Array.isArray @body then @body else [@body]
    param = { $, collection: "#default-schema.#name" }
    cols = {}
    if Array.isArray $.0
      [insert-cols, ...entries] = $
      for row in entries
        for key, idx in insert-cols | row[idx]?
          cols[key] = derive-type row[idx], cols[key]
    else for row in $
      for key in Object.keys row | row[key]?
        cols[key] = derive-type row[key], cols[key]
    do-insert = ~>
      mount-model plx, schema, name, _route
      plx.insert param, done, (error) -> done { error }
    if @method is \POST
      cols_defs = [ "\"#col\" #typ" for col, typ of cols ]
      if (@get "x-pgrest-create-identity-key") is \yes
        cols_defs = [ "\"_id\" SERIAL UNIQUE" ] ++ cols_defs

      plx.query """
        CREATE TABLE "#name" (#{
          cols_defs * ",\n"
        })
      """ do-insert
    else
      do-insert!

  _route '/runCommand' -> throw "Not implemented yet"

  cb cols

export function mount-socket (plx, schema, io, cb)
  schema-cond = if schema
      "IN ('#{schema}')"
  else
      "NOT IN ( 'information_schema', 'pg_catalog', 'plv8x')"

  # Generic JSON routing helper

  rows <- plx.query """
    SELECT t.table_schema scm, t.table_name tbl FROM INFORMATION_SCHEMA.TABLES t WHERE t.table_schema #schema-cond;
  """
  seen = {}
  default-schema = null
  cols = for {scm, tbl} in rows
    schema ||= scm
    if seen[tbl]
      console.log "#scm.#tbl not loaded, #tbl already in use"
    else
      seen[tbl] = true
      tbl
  mount-model-socket-event plx, scm, cols, io
  default-schema ?= \public

  cb cols

export function mount-model-socket-event (plx, schema, names, io)
  do
    # TODO: need refactoring
    socket <- io.sockets.on('connection')
    cb_complete = ->
      socket.emit "complete", it
    cb_err = ->
      socket.emit "error", it
    for name in names
      ((name) ->
        socket.on "GET:#name" !->
          it ?= {}
          if it._id
            param = locate_record plx, schema, name, it._id
            if it._column
              param.f = "#{it._column}": 1
          else
            param = it{ l, sk, c, s, q, fo, f, u, delay, body } <<< collection: "#schema.#name"
          param.$ = it.body || ""
          if it._column
            cb = (record) ->
              cb_complete record[it._column]
            plx[\select].call plx, param, cb, cb_err
          else
            plx[\select].call plx, param, cb_complete, cb_err
        socket.on "POST:#name" !->
          it ?= {}
          param = it{ l, sk, c, s, q, fo, f, u, delay, body } <<< collection: "#schema.#name"
          param.$ = it.body || ""
          plx[\insert].call plx, param, cb_complete, cb_err
        socket.on "DELETE:#name" !->
          it ?= {}
          if it._id
            param = locate_record plx, schema, name, it._id
          else
            param = it{ l, sk, c, s, q, fo, f, u, delay, body } <<< collection: "#schema.#name"
          param.$ = it.body || ""
          plx[\remove].call plx, param, cb_complete, cb_err
        socket.on "PUT:#name" !->
          it ?= {}
          if it._id
            param = locate_record plx, schema, name, it._id
          else
            param = it{ l, sk, c, s, q, fo, f, u, delay, body } <<< collection: "#schema.#name"
          param.$ = it.body || ""
          if param.u
            plx[\upsert].call plx, param, cb_complete, cb_err
          else if it._id
            plx[\upsert].call plx, param, cb_complete, cb_err
          else
            plx[\replace].call plx, param, cb_complete, cb_err
        socket.on "SUBSCRIBE:#name" !->
          q = """
            CREATE FUNCTION pgrest_subscription_trigger_#name() RETURNS trigger AS $$
            DECLARE
            BEGIN
              PERFORM pg_notify('pgrest_subscription_#name', '' || row_to_json(NEW) );
              RETURN new;
            END;
          $$ LANGUAGE plpgsql;
          """
          t = """
            CREATE TRIGGER pgrest_subscription_trigger
            AFTER INSERT
            ON #name FOR EACH ROW
            EXECUTE PROCEDURE pgrest_subscription_trigger_#name();
          """
          plx.conn.query "LISTEN pgrest_subscription_#name"
          plx.conn.on \notification ~>
            tbl = it.channel.split("_")[2]
            socket.emit "CHANNEL:#tbl", JSON.parse it.payload
          do
            err, rec <-plx.conn.query q
            #TODO: only ignore err if it's about trigger alread exists
            err, rec <- plx.conn.query t
            cb_complete "OK"
      )(name)
  return names
