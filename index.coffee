settings   = require './settings'

swig       = require 'swig'
express    = require 'express'
bodyParser = require 'body-parser'

{trello, db,
 queueApplyMirror,
 queueRefetchChecklists,
 log} = require './setup'

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
    action = payload.action.type

    switch action
      when 'addMemberToCard'
        console.log 'bot webhook:', action
        # fetch/create this card
        card = {
          _id: payload.action.data.card.id
          start: payload.action.date
          board: {id: payload.action.data.board.id}
          user: {id: payload.action.memberCreator.id}
          mirror: []
          data: {
            name: payload.action.data.card.name
            desc: null
            due: null
            idAttachmentCover: null
          }
          checklists: []
          comments: {} # this is where we store the id of the target comments
                       # when the source comments are in this card.
          attachments: {} # same as above
        }

        db.cards.update(
          { _id: card._id }
          card
          { upsert: true }
        ).catch(log 'couldnt create card').then((r) ->
          # return
          response.send 'ok'
          
          # add webhook to this card
          trello.put '/1/webhooks', {
            callbackURL: settings.SERVICE_URL + '/webhooks/mirrored-card'
            idModel: card._id
          }, (err, data) ->
            console.log err if err
            db.cards.update(
              {_id: card._id}
              {$set: {webhook: data.id}}
            )
            console.log 'webhook created'

          # initial fetch ~
          console.log 'initial fetch'
          # basic data (name, desc, due, idAttachmentCover)
          # (don't fetch comments -- we only want comments from now on)
          # (same for attachments)
          trello.get "/1/cards/#{card._id}", {
            fields: 'name,desc,due,idAttachmentCover'
            checkItemStates: 'true'
            checkItemState_fields: 'idCheckItem,state'
            checklists: 'all'
            checklist_fields: 'name,pos'
          }, (err, data) ->
            checklists = data.checklists
            delete data.id
            delete data.checkItemStates
            delete data.checklists
            db.cards.update(
              { _id: card._id }
              { $set: { data: data }, $set: { checklists: checklists } }
            )
            .then(->
              # get the first card of the mirror process (the master)       
              db.cards.find(
                {
                  $or: [ { _id: card._id }, { mirror: card._id } ]
                  webhook: { $exists: true }
                }
                { id: 1 }
              ).sort(
                { start: 1 }
              ).limit(1).toArray()
            )
            .then((cards) -> cards[0])
            .then(log 'found the master:')
            .then((master) ->
              queueApplyMirror('data', master._id)
              queueApplyMirror('checklists', master._id)
            )
          # ~

          # search for mirrorable cards in the db (equal name, same user)
          console.log 'searching for cards to mirror'
          db.cards.find(
            {
              'data.name': card.data.name
              'user.id': card.user.id
              '_id': { $ne: card._id }
              'webhook': { $exists: true }
            }
            { _id: 1 }
          ).toArray().then((mrs) -> return (m._id for m in mrs)).then((mids) ->
            console.log card._id, 'found cards to mirror:', mids

            db.cards.update(
              { _id: { $in: mids } }
              { $addToSet: { mirror: card._id } }
              { multi: true }
            )

            db.cards.update(
              { _id: card._id}
              { $addToSet: { mirror: { $each: mids } } }
            )
          )
        )

      when 'removeMemberFromCard'
        console.log 'bot webhook:', action
        # remove webhook from this card
        db.cards.findAndModify(
          query: {_id: payload.action.data.card.id }
          update: { $unset: {webhook: '', data: ''} }
          fields: { webhook: 1 }
          new: false
        ).then(->
          # delete webhook from trello
          trello.del '/1/webhooks/' + card.webhook, log 'deleted webhook'

          # remove this card from others which may be mirroring it
          db.cards.update(
            { mirror: payload.action.data.card.id }
            { $pull: { mirror: payload.action.data.card.id } }
            { multi: true }
          )

          # return
          response.send 'ok'
        )

      else response.send 'no, thank you'

app.post '/webhooks/mirrored-card', (request, response) ->
  payload = request.body
  action = payload.action.type
  console.log 'webhook:', action

  cardId = payload.action.data.card.id

  if action == 'updateCard'
    updated = payload.action.data.card
    delete updated.id
    delete updated.listId
    delete updated.idShort
    delete updated.shortLink
    set = {}
    for k, v of updated
      set['data.' + k] = v
    db.cards.update(
      { _id: cardId }
      { $set: set }
    )
    if payload.action.memberCreator.id == settings.TRELLO_BOT_ID
      console.log 'webhook triggered by a bot action, don\'t apply mirror.'
    else
      queueApplyMirror 'data', cardId

  else if action in ['addChecklistToCard', 'removeChecklistFromCard', 'updateChecklist', 'createCheckItem', 'deleteCheckItem', 'updateCheckItem', 'updateCheckItemStateOnCard']
    if payload.action.memberCreator.id != settings.TRELLO_BOT_ID # ignore if updated by the bot
      queueRefetchChecklists cardId, {applyMirror: true}

  else if action in ['commentCard', 'updateComment', 'deleteComment']
    comments = {}
    switch action
      when 'commentCard'
        comments['create'] = [
          sourceCommentId: payload.action.id
          text: payload.action.data.text
          author:
            id: payload.action.memberCreator.id
            name: payload.action.memberCreator.username
          date: payload.action.date
        ]
      when 'updateComment'
        comments['update'] = [
          sourceCommentId: payload.action.data.action.id
          text: payload.action.data.action.text
          author:
            id: payload.action.memberCreator.id
            name: payload.action.memberCreator.username
          date: payload.action.date
        ]
      when 'deleteComment'
        comments['delete'] = [
          sourceCommentId: payload.action.data.action.id
        ]
    if payload.action.memberCreator.id == settings.TRELLO_BOT_ID
      console.log 'webhook triggered by a bot action, don\'t apply mirror.'
    else
      queueApplyMirror 'comments', cardId, {comments: comments}

  else if action in ['addAttachmentToCard', 'deleteAttachmentFromCard']
    attachments = {}
    switch action
      when 'addAttachmentToCard'
        attachments['add'] = [
          sourceAttachmentId: payload.action.data.attachment.id
          url: payload.action.data.attachment.url
          name: payload.action.data.attachment.name
        ]
      when 'deleteAttachmentFromCard'
        attachments['delete'] = [
          sourceAttachmentId: payload.action.data.attachment.id
        ]
    if payload.action.memberCreator.id == settings.TRELLO_BOT_ID
      console.log 'webhook triggered by a bot action, don\'t apply mirror.'
    else
      queueApplyMirror 'attachments', cardId, {attachments: attachments}

  response.send 'ok'

app.use '/debounced', require './debounced'
app.use '/debounced/apply-mirror', require './apply-mirror'

index = swig.compileFile __dirname + '/templates/index.html'
app.get '/', (request, response) ->
  response.send index {config: settings, request: request}

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port
