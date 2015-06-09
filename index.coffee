settings   = require './settings'

Promise    = require 'bluebird'
Neo4j      = require 'neo4j'
NodeTrello = require 'node-trello'
express    = require 'express'
bodyParser = require 'body-parser'

Trello = Promise.promisifyAll new NodeTrello settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
Neo = Promise.promisifyAll new Neo4j.GraphDatabase settings.NEO4J_URL

app = express()
app.use '/static', express.static('static')
app.use bodyParser.json()

sendOk = (request, response) ->
  console.log 'trello checks this endpoint when creating a webhook'
  response.send 'ok'
app.get '/webhooks/trello-bot', sendOk
app.get '/webhooks/mirrored-card', sendOk

app.post '/webhooks/trello-bot', (request, response) ->
  payload = request.body

  console.log 'bot: ' + payload.action.type
  console.log JSON.stringify payload.action, null, 2
  response.send 'ok'

  switch payload.action.type
    when 'addMemberToCard'
      # add webhook to this card
      Trello.putAsync('/1/webhooks',
        callbackURL: settings.SERVICE_URL + '/webhooks/mirrored-card'
        idModel: payload.action.data.card.id
      ).then((data) ->
        console.log 'webhook created'

        Neo.queryAsync '''
          MERGE (card:Card {shortLink: {SL}})
          SET card.webhook = {WH}
          MERGE (user:User {id: {USERID}})
          MERGE (user)-[controls:CONTROLS]->(card)
        ''',
          SL: payload.action.data.card.shortLink
          WH: data.id
          USERID: payload.action.memberCreator.id
      ).then(->
        console.log 'card added to db'
      ).catch(console.log.bind console)

    when 'removeMemberFromCard'
      # remove webhook from this card
      Neo.queryAsync('''
        MATCH (card:Card {id: {SL}})
        RETURN card
      ''',
        SL: payload.action.data.card.shortLink
      ).then((res) ->
        card = res[0]['card']
        Trello.delAsync '/1/webhooks/' + card.webhook
      ).then(->
        console.log 'webhook deleted'

        Neo.queryAsync '''
          MATCH (card:Card {id: {ID}})
          DELETE card
        ''',
          ID: payload.action.data.card.shortLink
      ).then(->
        console.log 'card deleted from db'
      ).catch(console.log.bind console)

app.post '/webhooks/mirrored-card', (request, response) ->
  payload = request.body
  action = payload.action.type

  console.log 'card ' + payload.model.shortUrl + ': ' + action
  console.log JSON.stringify payload.action, null, 2
  response.send 'ok'

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port
