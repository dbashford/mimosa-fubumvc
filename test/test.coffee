rewire = require("rewire")
chai = require("chai")
fubuImport = rewire("../lib/fubu-import.js")
expect = chai.expect
_ = require("lodash")
path = require 'path'

describe "fubu-import module", ->
  rawFubuImport = require ("../lib/fubu-import.js")
  describe 'exports', ->
    functions = ["importAssets", "cleanAssets", "setupFileSystem"]
    ensureIsFunction = (functionName) ->
      it "should export #{functionName}", ->
        expect(typeof rawFubuImport[functionName]).to.equal("function")

    ensureIsFunction functionName for functionName in functions

    it "should not export anything else", ->
      #rewire puts extra properties on the module that won't be there when its 'required'
      _.each rawFubuImport, (value, key) ->
        expect(_.contains functions, key).to.equal true

describe "relative paths", ->
  relativeToThisFile = fubuImport.__get__ "relativeToThisFile"
  it "can be provided by directory", ->
    sep = path.sep
    fakeDirname = "path#{sep}to#{sep}file"
    fileName = "test.txt"
    expect(relativeToThisFile fileName, fakeDirname).to.equal "#{fakeDirname}#{sep}#{fileName}"

describe "initFiles", ->
  initFiles = fubuImport.__get__ "initFiles"

  writesFiles = (output, flags) ->
    writtenFiles = []
    fsMock =
      existsSync: (fileName) ->
        false
      writeFileSync: (fileName) -> writtenFiles.push fileName
    fubuImport.__set__ "fs", fsMock
    initFiles(flags)
    expect(writtenFiles).to.eql output

  it "writes files", ->
    writesFiles ["bower.json", "mimosa-config.js"]

  it "uses .coffee extension for files when -c flag is passed", ->
    writesFiles ["bower.json", "mimosa-config.coffee"], "coffee"

  it "only writes files if they don't exist already", ->
    fsMock =
      existsSync: (fileName) ->
        true
      writeFileSync: (args) -> chai.assert.fail(null, null, "should not write files")
    fubuImport.__set__ "fs", fsMock
    initFiles()

describe "makeFolders", ->
  makeFolders = fubuImport.__get__ "makeFolders"
  createdFolders = []
  mkdirpMock =
    sync: (fileName) ->
      createdFolders.push fileName
  fubuImport.__set__ "mkdirp", mkdirpMock

  it "creates assets/{scripts,styles} and public folder for you", ->
    makeFolders()
    expect(createdFolders).to.eql ['assets/scripts', 'assets/styles', 'public']

describe "parseXml", ->
  parseXml = fubuImport.__get__ "parseXml"
  it "can produce javascript object from xml", ->
    numbers = ["one","two"]
    input = "<tag><numbers>one</numbers><numbers>two</numbers></tag>"
    output = parseXml input
    expect(output).to.have.deep.property("tag.numbers", numbers)
