settings   = require './settings'

util       = require 'util'
express    = require 'express'
bodyParser = require 'body-parser'

trello = new (require 'node-trello') settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
db     = (require 'promised-mongo') settings.MONGO_URI, ['cards']

app = express()
app.use express.static(__dirname + '/static')
app.use bodyParser.json()

sendOk = (request, response) ->
  console.log 'trello checks this endpoint when creating a webhook'
  response.send 'ok'
app.get '/webhooks/trello-bot', sendOk
app.get '/webhooks/mirrored-card', sendOk

app.post '/webhooks/trello-bot', (request, response) ->
    payload = request.body
    action = payload.action.type
    console.log 'webhook:', action

    switch action
      when 'addMemberToCard'
        # fetch/create this card
        db.cards.update(
          {_id: payload.action.data.card.id}
          {
            _id: payload.action.data.card.id
            board: {id: payload.action.data.board.id}
            user: {id: payload.action.memberCreator.id}
            data: {
              name: payload.action.data.card.name
            }
          }
          {upsert: true}
        )

        # return
        response.send 'ok'
        
        # add webhook to this card
        trello.put '/1/webhooks', {
          callbackURL: settings.SERVICE_URL + '/webhooks/mirrored-card'
          idModel: payload.action.data.card.id
        }, (err, data) ->
          throw err if err
          db.cards.update(
            {_id: payload.action.data.card.id}
            {webhook: data.id}
          )
          console.log 'webhook created'

        # perform an initial fetch
        #superagent.post

      when 'removeMemberFromCard'
        db.cards.findOne(
          {_id: payload.action.data.card.id}
          {webhook: 1}
        ).then((wh) ->
          # remove webhook from this card
          trello.delete '/1/webhooks/' + wh, (err) -> console.log err

          # return
          response.send 'ok'

          # update db removing webhook id and card data (desc, name, comments, attachments, checklists)
          db.cards.update(
            {_id: payload.action.data.card.id}
            {$unset: {webhook: '', data: ''}}
          )
        )

app.post '/webhooks/initial-parse', (request, response) ->
    db.cards.findOne({_id: request.body.id}).then((card) ->
      trello.get '/1/cards/' + card._id, {
        fields: []
      }, (err, data) ->

        response.send 'ok'
    )

app.post '/webhooks/mirrored-card', (request, response) ->
    payload = request.body
    action = payload.action.type
    console.log 'webhook:', action

    switch action
      when 'addAttachmentToCard', 'deleteAttachmentFromCard', 'addChecklistToCard', 'removeChecklistFromCard', 'createCheckItem', 'updateCheckItem', 'deleteCheckItem', 'updateCheckItemStateOnCard', 'updateChecklist', 'commentCard', 'updateComment', 'updateCard'
        console.log JSON.stringify payload, null, 2

    response.send 'ok'

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port
