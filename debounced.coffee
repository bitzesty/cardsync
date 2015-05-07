express    = require 'express'
bodyParser = require 'body-parser'

{trello, db,
 queueApplyMirror} = require './setup'

app = express()
app.use bodyParser.json()

app.post '/refetch-checklists', (request, response) ->
  options = request.body.merge.options
  delete request.body.merge.options

  for id of request.body.merge
    (->
      cardId = id
      if options and options[cardId]
        applyMirror = options[cardId].applyMirror
      else
        applyMirror = false

      console.log 'refetching checklists for', cardId

      trello.get "/1/cards/#{cardId}", {
        fields: 'id'
        checkItemStates: 'true'
        checkItemState_fields: 'idCheckItem,state'
        checklists: 'all'
        checklist_fields: 'name,pos'
      }, (err, data) ->
        db.cards.update(
          { _id: cardId }
          { $set: { checklists: data.checklists } }
        ).then(->
          if applyMirror
            queueApplyMirror 'checklists', cardId
        )
    )()

module.exports = app
