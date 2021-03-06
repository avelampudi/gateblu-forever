util = require 'util'
{EventEmitter} = require 'events'
fs = require 'fs-extra'
path = require 'path'
forever = require 'forever-monitor'
{exec} = require 'child_process'
_ = require 'lodash'
async = require 'async'
debug = require('debug')('gateblu:deviceManager')
url = require 'url'
MeshbluHttp = require 'meshblu-http'

class DeviceManager extends EventEmitter
  constructor: (@config, dependencies={}) ->
    @deviceProcesses = {}
    @runningDevices = []
    @connectorsInstalled = {}

  addDevice: (device, callback=->) =>
    debug 'addDevice', device
    async.series [
      (callback) => @installConnector device.connector, callback
      (callback) => @setupDevice device, callback
    ], callback

  removeDevice: (device, callback=->) =>
    debug 'removeDevice', device
    async.series [
      (callback) => @stopDevice device, callback
      (callback) => @removeDeletedDeviceDirectory device, callback
    ], callback

  getDevicePath: (device) =>
    path.join @config.devicePath, device.uuid

  startDevice : (device, callback=->) =>
    debug 'startDevice', { name: device.name, uuid: device.uuid}
    devicePath = @getDevicePath device
    @writeMeshbluJSON devicePath, device

    pathSep = ':'
    pathSep = ';' if process.platform == 'win32'

    foreverOptions =
      max: 1
      silent: true
      options: []
      cwd: devicePath
      logFile: path.join devicePath, 'forever.log'
      outFile: path.join devicePath, 'forever.stdout'
      errFile: path.join devicePath, 'forever.stderr'
      command: 'node'
      checkFile: false

    child = new (forever.Monitor)('command.js', foreverOptions)
    child.on 'stderr', (data) =>
      debug 'stderr', device.uuid, data.toString()
      @emit 'stderr', data.toString(), device

    child.on 'stdout', (data) =>
      debug 'stdout', device.uuid, data.toString()
      @emit 'stdout', data.toString(), device

    child.on 'stop', =>
      debug "process for #{device.uuid} stopped."
      delete @deviceProcesses[device.uuid]

    debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
    child.start()
    @deviceProcesses[device.uuid] = child
    @emit 'start', device
    callback()

  installConnector : (connector, callback=->) =>
    debug 'installConnector', connector
    if _.isEmpty(connector)
      return callback()

    connector = _.last connector.split(':')

    if @connectorsInstalled[connector]
      debug "installConnector: #{connector} already installed this session. skipping."
      return callback()

    nodeModulesDir = path.join @config.tmpPath, 'node_modules'
    fs.mkdirpSync @config.tmpPath unless fs.existsSync @config.tmpPath
    connectorPath = path.join nodeModulesDir, connector
    npmMethod = "install"
    npmMethod = "update" if fs.existsSync "#{connectorPath}/package.json"
    prefix = ''
    prefix = 'cmd.exe /c ' if process.platform == 'win32'
    npm_command = "#{prefix} npm --prefix=. #{npmMethod} #{connector}"
    debug "npm install: #{npm_command}, cwd: #{@config.tmpPath}"
    exec(npm_command,
      cwd: @config.tmpPath
      (error, stdout, stderr) =>
        if error?
          debug 'npm install error:', error
          console.error 'Error: ', error
          @emit 'stderr', error
          return callback()

        if stderr?
          @emit 'npm:stderr', stderr.toString()
          debug 'npm:stderr', stderr.toString()

        if stdout?
          @emit 'npm:stdout', stdout.toString()
          debug 'npm:stdout', stdout.toString()

        debug 'connector installed', connector
        @connectorsInstalled[connector] = true
        callback()
    )

  setupDevice: (device, callback) =>
    debug 'setupDevice', uuid: device.uuid, name: device.name

    devicePath = @getDevicePath device
    connectorPath = path.join @config.tmpPath, 'node_modules', device.connector

    debug 'path', devicePath
    debug 'connectorPath', connectorPath

    try
      debug 'copying files', devicePath
      fs.removeSync devicePath
      fs.copy connectorPath, devicePath, =>
        debug 'done copying', devicePath
        callback()

    catch error
      console.error error
      @emit 'stderr', error
      debug 'forever error:', error
      _.defer -> callback new Error('copy error')

  writeMeshbluJSON: (devicePath, device) =>
    meshbluFilename = path.join devicePath, 'meshblu.json'
    deviceConfig = _.extend {},
      device,
      server: @config.server, port: @config.port

    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFileSync meshbluFilename, meshbluConfig

  shutdown: (callback=->) =>
    async.eachSeries _.keys(@deviceProcesses), (uuid, callback) =>
      @stopDevice uuid: uuid, callback
    , callback

  stopDevice: (device, callback=->) =>
    debug 'stopDevice', device.uuid
    deviceProcess = @deviceProcesses[device.uuid]
    return callback null, device.uuid unless deviceProcess?

    if deviceProcess.running
      debug 'killing process for', device.uuid
      deviceProcess.killSignal = 'SIGINT'
      deviceProcess.stop()
      callback null, device.uuid

    debug "process for #{device.uuid} wasn't running. Removing record."
    delete @deviceProcesses[device.uuid]
    callback null, device.uuid

  removeDeletedDeviceDirectory: (device, callback) =>
    fs.remove @getDevicePath(device), (error) ->
      console.error error if error?
      callback()

module.exports = DeviceManager
