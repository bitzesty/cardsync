settings   = require './settings'

Promise    = require 'bluebird'
Redis      = require 'then-redis'
NodeTrello = require 'node-trello'
url        = require 'url'
moment     = require 'moment'
express    = require 'express'
bodyParser = require 'body-parser'
zipObject  = require 'lodash.zipobject'
values     = require 'lodash.values'

trello = Promise.promisifyAll new NodeTrello settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN

rurl = url.parse settings.REDIS_URL
redis = Redis.createClient
  host: rurl.hostname
  port: rurl.port
  password: rurl.auth.split(':')[1]


this.addRefbotHooks = (app) ->

  app.post '/webhooks/tracked-board', (request, response) ->
    payload = request.body
    action = payload.action
    data = action.data

    console.log 'card ' + payload.model.shortUrl + ': ' + payload.action.type
    # console.log JSON.stringify payload.action, null, 2
    response.send 'ok'

    if action.memberCreator.id == settings.TRELLO_BOT_ID # @refbot
      return

    if action.memberCreator.id == '557976153d63ef846e16a992' # @cardsync
      return

    try
      commentDate = moment(action.date).format('MMM D, YYYY')
      refText = """
  >   :paperclip: [#{action.memberCreator.username}](https://trello.com/#{action.memberCreator.username}) referenced this card from #{if action.type.indexOf('omment') != -1 then 'a comment at ' else if action.type.indexOf('heck') != -1 then 'a checkItem from' else 'the description of'} https://trello.com/c/#{data.card.shortLink} on #{commentDate}[.](http://websitesfortrello.com/)
      """
      notHere = (match) -> match not in [data.card.id, data.card.shortLink]
    catch e
      return

    handle = switch action.type
      when 'commentCard'
        matches = (require './match')(data.text).filter(notHere)
        Promise.resolve().then(->
          Promise.all matches.map((m) -> trello.postAsync "/1/cards/#{m}/actions/comments", text: refText)
        ).then((comments) ->
          if comments.length
            # add newly created ids to redis
            redis.hmset 'comment:' + action.id, zipObject(matches, comments.map((c) -> c.id))
        )
      when 'updateComment'
        newmatches = (require './match')(data.action.text).filter(notHere)
        oldmatches = (require './match')(data.old.text).filter(notHere)
        removedmatches = oldmatches.filter((x) -> x not in newmatches)
        addedmatches = newmatches.filter((x) -> x not in oldmatches)

        Promise.resolve().then(->
          redis.hgetall 'comment:' + data.action.id
        ).then((targets) ->
          removedids = removedmatches.map((m) -> targets[m])

          # remove old and create new
          Promise.all [
            Promise.all addedmatches.map((m) -> trello.postAsync "/1/cards/#{m}/actions/comments", text: refText)
            redis.hdel 'comment:' + data.action.id, removedmatches if removedmatches.length
            Promise.all removedids.map((id) -> trello.delAsync("/1/actions/#{id}").catch(console.log.bind console))
          ]
        ).spread((addedcomments) ->
          if addedcomments.length
            # add newly created ids to redis
            addedids = addedcomments.map((c) -> c.id)
            redis.hmset 'comment:' + data.action.id, zipObject(addedmatches, addedids)
        )
      when 'deleteComment'
        Promise.resolve().then(->
          redis.hgetall 'comment:' + data.action.id
        ).then((targets) ->
          # just remove everything
          Promise.all [
            Promise.all (values targets).map((id) -> trello.delAsync("/1/actions/#{id}").catch(console.log.bind console))
            redis.del 'comment:' + data.action.id
          ]
        )
      when 'updateCard'
        if 'desc' of data.old
          newmatches = (require './match')(data.card.desc).filter(notHere)
          oldmatches = (require './match')(data.old.desc).filter(notHere)
          removedmatches = oldmatches.filter((x) -> x not in newmatches)
          addedmatches = newmatches.filter((x) -> x not in oldmatches)

          Promise.resolve().then(->
            redis.hgetall 'desc:' + data.card.id
          ).then((targets) ->
            removedids = removedmatches.map((m) -> targets[m])

            # remove old and create new
            Promise.all [
              Promise.all addedmatches.map((m) -> trello.postAsync "/1/cards/#{m}/actions/comments", text: refText)
              redis.hdel 'desc:' + data.card.id, removedmatches if removedmatches.length
              Promise.all removedids.map((id) -> trello.delAsync("/1/actions/#{id}").catch(console.log.bind console))
            ]
          ).spread((addedcomments) ->
            if addedcomments.length
              # add newly created ids to redis
              addedids = addedcomments.map((c) -> c.id)
              redis.hmset 'desc:' + data.card.id, zipObject(addedmatches, addedids)
          )
        else
          Promise.resolve(null)
      when 'createCheckItem'
        matches = (require './match')(data.checkItem.name).filter(notHere)
        Promise.resolve().then(->
          Promise.all matches.map((m) -> trello.postAsync "/1/cards/#{m}/actions/comments", text: refText)
        ).then((comments) ->
          if comments.length
            # add newly created ids to redis
            redis.hmset 'checkItem:' + data.checkItem.id, zipObject(matches, comments.map((c) -> c.id))
        )
      when 'updateCheckItem'
        if 'name' of data.old
          newmatches = (require './match')(data.checkItem.name).filter(notHere)
          oldmatches = (require './match')(data.old.name).filter(notHere)
          removedmatches = oldmatches.filter((x) -> x not in newmatches)
          addedmatches = newmatches.filter((x) -> x not in oldmatches)

          Promise.resolve().then(->
            redis.hgetall 'checkItem:' + data.checkItem.id
          ).then((targets) ->
            removedids = removedmatches.map((m) -> targets[m])

            # remove old and create new
            Promise.all [
              Promise.all addedmatches.map((m) -> trello.postAsync "/1/cards/#{m}/actions/comments", text: refText)
              redis.hdel 'checkItem:' + data.checkItem.id, removedmatches if removedmatches.length
              Promise.all removedids.map((id) -> trello.delAsync("/1/actions/#{id}").catch(console.log.bind console))
            ]
          ).spread((addedcomments) ->
            if addedcomments.length
              # add newly created ids to redis
              addedids = addedcomments.map((c) -> c.id)
              redis.hmset 'checkItem:' + data.checkItem.id, zipObject(addedmatches, addedids)
          )
        else
          Promise.resolve(null)
      when 'deleteCheckItem'
        Promise.resolve().then(->
          redis.hgetall 'checkItem:' + data.checkItem.id
        ).then((targets) ->
          # just remove everything
          Promise.all [
            Promise.all (values targets).map((id) -> trello.delAsync("/1/actions/#{id}").catch(console.log.bind console))
            redis.del 'checkItem:' + data.checkItem.id
          ]
        )
      else Promise.resolve(null)

    handle.then(console.log.bind console).catch(console.log.bind console)

#  port = process.env.PORT or 5000
#  app.listen port, '0.0.0.0', ->
#    console.log 'running at 0.0.0.0:' + port
