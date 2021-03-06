#!/usr/bin/env coffee

###
History bot for Martini IRC
- remember when a user logs out
- then when they re-join, invite them to 'catchup'
- user can also 'catchup N' an arbitrary # of lines
- saves max-sized buffer to memory
- ONE CHANNEL AT A TIME - to run multiple channels, run multiple bots
###

irc = require 'irc'
require 'sugar'  # for dates
async = require 'async'

argv = require('optimist')
  .demand('server').alias('server', 's').describe('server', 'Server')
  .demand('channel').alias('channel', 'c').describe('channel', 'Channel')
  .demand('botname').alias('botname', 'b').describe('botname', 'Bot Name')
  .demand('port').alias('port', 'p').describe('port', 'Port number').default('port', '6667')
  .alias('user', 'u').describe('user', 'Username for server')
  .alias('password', 'p').describe('password', 'Password for server')
  .boolean('ssl').describe('ssl', 'Use SSL').default('ssl', false)
  .argv

server = argv.s
channel = argv.c
try if not channel.match(/^#/) then channel = '#' + channel
botName = argv.b

console.log "Connecting to #{channel} on #{server} as #{botName} " +
  (if argv.ssl then "with SSL" else "without SSL")

bot = new irc.Client server, botName,
  channels: [ channel ]
  autoConnect: false
  secure: argv.ssl
  port: argv.port
  userName: argv.u
  password: argv.p
  selfSigned: true
  certExpired: true

bot.on 'error', (error) ->
  unless error.command is 'err_nosuchnick' then console.log 'error:', error

bot.on 'registered', (data) ->
  console.log "Joined #{channel}"

  # has my nick changed? (e.g. if connected >once on same server)
  # - not sure if this is consistent -
  if data.args?.length is 2
    newNick = data.args[0]
    if newNick isnt botName
      console.warn "Bot Name changed to #{newNick}!"
      botName = newNick

# store messages as hash w/ n:msg
msgs = {}

# current range of msgs
msgCount = 0
msgMin = 1

keepOnly = 1000

# msgCount at which people leave
# (in memory for now, @todo move to redis)
usersLastSaw = {}

# track that user saw the last message.
# use global msgCount as counter.
# async response so we can refactor to redis later.
recordUserSaw = (who, callback)->
  # don't care about self
  if who is botName then return

  # don't regress
  if usersLastSaw[who]?
    usersLastSaw[who] = Math.max(usersLastSaw[who], msgCount)
  else
    usersLastSaw[who] = msgCount

  callback?()


# someone else speaks
bot.on 'message' + channel, (who, message)->
  # handle 'catchup' requests
  if matches = message.match /^catchup( [0-9]*)?$/
    catchup who, (matches[1] ? 0)
    return

  # save everything else
  d = Date.create()
  msgs[++msgCount] = d.format('{yyyy}-{MM}-{d}') + ' ' + d.format('{hh}:{mm}:{ss}') + " <#{who}> #{message}"

  # cleanup
  if msgCount - msgMin >= keepOnly
    for n in [msgMin..(msgCount-keepOnly)]
      delete msgs[n]
      msgMin = (n + 1) if n >= msgMin

  # get the list of users in this channel,
  # record that they got the last msg. (caught by event handler.)
  bot.send 'NAMES', channel


quitHandler = (who, type = "left")->
  console.log "#{who} #{type} at msg ##{msgCount}"
  recordUserSaw who


# 3 ways to leave
bot.on 'part' + channel, (who, reason)->
  quitHandler who, 'left'
bot.on 'kick' + channel, (who, byWho, reason)->
  quitHandler who, 'kicked'
bot.on 'quit', (who, reason, channels, message)->
  if channel in channels then quitHandler who, 'quit'


# someone joins
bot.on 'join' + channel, (who, message) ->
  # self? (instead of 'registered' which our new server doesn't like, pre-join)
  if who is botName and msgCount is 0
    bot.say channel, "#{botName} is watching. When you leave this channel and return, " +
      "you can 'catchup' on what you missed, or at any time, 'catchup N' # of lines."
    return

  console.log "#{who} joined at msg ##{msgCount}"

  # auto-catchup, if something new or unknown user.
  catchup who


bot.on 'end', ()->
  console.log "Connection ended"
  # @todo try to reconnect?

bot.on 'close', ()->
  console.log "Connection closed"


# names are requested whenever a message is posted.
# track that everyone in the room has seen the last message.
bot.on 'names', (forChannel, names)->
  if forChannel isnt channel then return
  try
    names = Object.keys(names)
    # (exclude self)
    console.log "updating #{names.length - 1} users (" + names.join(',') + ") to msg ##{msgCount}"
    recordUserSaw who for who in names
  catch error
    console.error "Unable to parse names", error


# (async so we can refactor to redis)
countMissed = (who, callback)->
  # differentiate 0 (nothing new) from false (don't know the user)
  if usersLastSaw[who]?
    callback (msgCount - usersLastSaw[who])
  else callback false


# (async so we can refactor to redis)
catchup = (who, lastN = 0, callback)->
  async.waterfall [
    (next)->
      # actual # of missed lines. may be > when initially mentioned on re-join.
      if lastN is 0 then countMissed who, (lastN)-> next null, lastN
      else next null, lastN
    
    (lastN, next)->
      # countMissed returned 0, means the user is known but hasn't missed anything.
      if lastN is 0
        console.log "Nothing new to send #{who}"
        next true
      
      # user isn't recognized, send a bunch
      else if lastN is false then next null, 100
      else next null, lastN
    
    (lastN, next)->
      # @todo refactor {msgs}.length to redis lookup

      # don't try to send more than we have
      lastN = Math.min lastN, Object.keys(msgs).length
      next null, lastN

    (lastN, next)->
      console.log "Sending #{who} the last #{lastN} messages"

      # private
      bot.say who, "Catchup on the last #{lastN} messages:"
      for n in [(msgCount-lastN+1)..msgCount]
        if msgs[n]? then bot.say who, msgs[n]
      next()
  ],
  (error)->
    # don't pass back errors
    if error instanceof Error then console.error error
    callback?()
  


bot.connect()
