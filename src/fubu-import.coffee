"use strict"

{log, printObj} = require './util'
color = require('ansi-color').set
fs = require 'fs'
path = require 'path'
watch = require 'chokidar'
wrench = require 'wrench'
_ = require 'lodash'
parseString = require('xml2js').parseString
workingDir = process.cwd()
Rx = require "rx"

findSourceFiles = (from, extensions, excludes, baseDir) ->
  wrench.readdirSyncRecursive(from)
    .filter (f) ->
      originalFile = path.join from, f
      isFile = fs.statSync(originalFile).isFile()
      isIncluded = shouldInclude f, isFile, extensions, excludes, baseDir
      isIncluded and isFile
    .map (f) -> path.join from, f

shouldInclude = (f, isFile, extensions, excludes, baseDir) ->
  #TODO: only adds the . to you for extensions if its left off
  extensions = extensions.map (ext) -> ".#{ext}"
  ext = path.extname f
  matchesExtension = not isFile or _.contains extensions, ext
  atRoot = isFile and f.indexOf(path.sep) == -1
  excluded = isExcludedByConfig f, excludes, baseDir
  matchesExtension and not excluded and not atRoot

withoutPath = (fromPath) ->
  (input) -> input.replace "#{fromPath}#{path.sep}", ''

prepareFileWatcher = (from, extensions, excludes, isBuild, fileWatcherSettings, baseDir) ->
  #TODO: no more sync calls
  files  = findSourceFiles from, extensions, excludes, baseDir
  numberOfFiles  = files.length
  fixPath = withoutPath from

  settings =
    ignored: (file) ->
      isFile = fs.statSync(file).isFile()
      f = fixPath file
      not (shouldInclude f, isFile, extensions, excludes, baseDir)
    persistent: not isBuild

  watchSettings = _.extend settings, fileWatcherSettings

  observableFor = (event) ->
    Rx.Observable.fromEvent watcher, event

  log "debug", "starting file watcher on [[ #{from} ]] usePolling: #{watchSettings.usePolling}"

  watcher = watch.watch from, watchSettings
  adds = observableFor "add"
  changes = observableFor "change"
  unlinks = observableFor "unlink"
  errors = (observableFor "error").selectMany (e) -> Rx.Observable.throw e
  {numberOfFiles, adds, changes, unlinks, errors}

startWatching = (
  from,
  {numberOfFiles, adds, changes, unlinks, errors},
  options,
  cb) ->

  fromSource = (obs) ->
    obs.merge(errors)

  initialCopy = fromSource(adds).take(numberOfFiles)

  initialCopy.subscribe(
    (f) ->
      copyFile f, from, options
    (e) ->
      log "warn", "File watching error: #{e}"
      cb() if cb
    () ->
      ongoingCopy = fromSource(adds.merge changes)
      ongoingCopy.subscribe(
        (f) -> copyFile f, from, options
        (e) -> log "warn", "File watching error: #{e}"
      )
      log "info", "finished initial copy for: #{from}"
      cb() if cb
  )

  deletes = fromSource(unlinks)

  deletes.subscribe(
    (f) ->
      outFile = transformPath f, from, options
      deleteFile outFile
    (e) -> log "warn", "File watching errors: #{e}"
  )

copyFile = (file, from, options) ->
  fs.readFile file, (err, data) ->
    if err
      log "error", "Error reading file [[ #{file} ]], #{err}"
      return

    outFile = transformPath file, from, options

    dirname = path.dirname outFile
    unless fs.existsSync dirname
      wrench.mkdirSyncRecursive dirname, 0o0777

    fs.writeFile outFile, data, (err) ->
      if err
        log "error", "Error reading file [[ #{file} ]], #{err}"
      else
        log "success", "File copied to destination [[ #{outFile} ]] from [[ #{file} ]]"

deleteFileSync = (file) ->
  if fs.existsSync file
    fs.unlinkSync file
    log "success", "File [[ #{file} ]] deleted."

deleteFile = (file) ->
  fs.exists file, (exists) ->
    if exists
      fs.unlink file, (err) ->
        if err
          log "error", "Error deleting file [[ #{file} ]], #{err}"
        else
          log "success", "File [[ #{file} ]] deleted."

deleteDirectory = (dir, cb) ->
  if fs.existsSync dir
    fs.rmdir dir, (err) ->
      if err?.code is not "ENOTEMPTY"
        log "error", "Unable to delete directory [[ #{dir} ]]"
        log "error", err
      else
        log "info", "Deleted empty directory [[ #{dir} ]]"
      cb() if cb
  else cb() if cb

withoutBaseDir = (testPath, baseDir) ->
  baseDir = if (baseDir and baseDir.length) then path.join(baseDir, "/") else baseDir
  cwd = process.cwd()
  newPath = testPath.replace(cwd, "")
  start = Math.max(newPath.indexOf(baseDir), 0)
  newPath = newPath.substring(start)
  returnVal = newPath.replace(baseDir or "", "").replace(/^\/|^\\/, "")
  return returnVal

transformPath = (file, from, {sourceDir, conventions, baseDir}) ->
  newFilePath = withoutBaseDir file, baseDir
  newSourceDir = withoutBaseDir sourceDir, baseDir
  fixPath = withoutPath from
  newFile = fixPath newFilePath
  result = _.reduce(conventions, (acc, {match, transform}) ->
    ext = path.extname acc
    if match acc, ext, log then transform acc, path, log else acc
  , newFile)
  result = result.replace(newSourceDir, "")
  finalPath = path.join baseDir or "", newSourceDir, result
  finalPath

matchesWithoutBaseDir = (testPath, baseDir, predicate) ->
  newTest = withoutBaseDir testPath, baseDir
  shouldExclude = predicate(newTest)
  return shouldExclude

excludeStrategies =
  string:
    identity: _.isString
    predicate: (ex, testPath, baseDir) ->  matchesWithoutBaseDir testPath, baseDir, (newPath) -> newPath.indexOf(ex) == 0
  regex:
    identity: _.isRegExp
    predicate: (ex, testPath, baseDir) -> matchesWithoutBaseDir testPath, baseDir, (newPath) -> ex.test newPath

isExcludedByConfig = (testPath, excludes, baseDir) ->
  ofType = (method) ->
    excludes.filter (f) -> method(f)

  _.any excludeStrategies, ({identity, predicate}) ->
    _.any (ofType identity), (ex) -> predicate ex, testPath, baseDir

parseXml = (content) ->
  result = {}
  parseString content, (err, output) ->
    result = output
  result

findBottles = (sourceDir) ->
  linksFile = path.join sourceDir, ".links"
  if fs.existsSync linksFile
    encoding = "utf8"
    data = fs.readFileSync linksFile, {encoding}
    linksXml = parseXml data
    bottles = linksXml?.links?.include || []
    unless bottles and _.isArray bottles
      log "error", ".links file not valid"
      return
    bottles = _.map(bottles, (bottle)-> bottle.replace(/\\|\//, path.sep))
    bottles
  else
    []

buildExtensions = (config) ->
  {copy, javascript, css} = config.extensions
  extensions = _.union copy, javascript, css

setWorkingDir = (val) ->
  workingDir = val or process.cwd()

importAssets = (mimosaConfig, options, next) ->
  log "info", "importing assets"
  {excludePaths, sourceDir, compiledDir, isBuild, conventions, usePolling, interval, binaryInterval, baseDir} =
    mimosaConfig.fubumvc

  extensions = buildExtensions mimosaConfig
  setWorkingDir baseDir

  log "debug", "allowed extensions [[ #{extensions} ]]"
  log "debug", "excludePaths [[ #{excludePaths} ]]"

  fileWatcherSettings = {usePolling, interval, binaryInterval}

  importFrom = (target, callback) ->
    log "info", "watching #{target}"
    fileWatcher = prepareFileWatcher target, extensions, excludePaths, isBuild, fileWatcherSettings, mimosaConfig.fubumvc.baseDir
    startWatching target, fileWatcher, {sourceDir, conventions, baseDir}, callback

  targets = getTargets workingDir

  finish = trackCompletion "importAssets", targets, next

  _.each targets, (target) ->
    importFrom target, () -> finish(target)
  return

getTargets = (dir) ->
  bottles = _.map (findBottles dir), (bottle) -> path.resolve dir, bottle
  targets = [].concat bottles, [dir]

cleanAssets = (mimosaConfig, options, next) ->
  log "info", "cleaning assets"
  {extensions, excludePaths, sourceDir, compiledDir, isBuild, conventions, baseDir} =
    mimosaConfig.fubumvc
  extensions = buildExtensions mimosaConfig
  options = {sourceDir, conventions, baseDir}
  setWorkingDir baseDir

  filesFor = (target) ->
    log "debug", "finding files for: #{target} with extensions: #{extensions} and excludePaths: #{excludePaths}"
    files  = findSourceFiles target, extensions, excludePaths, baseDir
    outputFiles = _.map files, (f) -> transformPath f, target, options
    [target, files, outputFiles]

  targets = getTargets workingDir

  allTargetFiles = _.map targets, filesFor

  finish = trackCompletion "cleanAssets", targets, next

  _.each allTargetFiles, ([target, files, outputFiles]) ->
    clean [target, files, outputFiles], () -> finish(target)
  return

trackCompletion = (title, initial, cb) ->
  remaining = [].concat initial
  done = (dir) ->
    remaining = _.without remaining, dir
    if remaining.length == 0
      log "info", "finished #{title}"
      cb()
  done

clean = ([target, files, outputFiles], cb) ->
  _.each outputFiles, (f) -> deleteFileSync f

  dirs = _ outputFiles
    .map (f) -> path.dirname f
    .unique()
    .sortBy "length"
    .reverse()
    .value()

  if dirs.length > 0
    finish = trackCompletion "clean", dirs, cb

    _ dirs
      .map (dir) -> [dir, () -> finish(dir)]
      .each ([dir, cb]) ->
        deleteDirectory dir, cb
  else
    cb()

module.exports = {importAssets, cleanAssets}
