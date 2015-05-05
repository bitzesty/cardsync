settings   = require './settings'

util       = require 'util'
diff       = require 'deep-diff'
moment     = require 'moment'
express    = require 'express'
superagent = require 'superagent'
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
    console.log 'bot webhook:', action

    switch action
      when 'addMemberToCard'
        # fetch/create this card
        card = {
          _id: payload.action.data.card.id
          start: payload.action.date
          board: {id: payload.action.data.board.id}
          user: {id: payload.action.memberCreator.id}
          mirror: []
          data: {
            name: payload.action.data.card.name
          }
          comments: {} # this is where we store the id of the target comments
                       # when the source comments are in this card.
        }

        db.cards.update(
          {_id: card._id}
          card
          {upsert: true}
        ).then((r) ->
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
          # basic data (name, desc, due)
          trello.get "/1/cards/#{card._id}", { fields: 'name,desc,due' }, (err, data) ->
            delete data.id
            db.cards.update(
              {_id: card._id}
              {$set: { data: data }}
            ).then(-> return cardId).then(queueApplyMirror)
          # comments (don't fetch anything -- we only want comments from now on)
          # ~

          # search for mirrored cards in the db (equal name, same user)
          console.log 'searching cards to mirror'
          db.cards.find(
            {
              'data.name': card.data.name
              'user.id': card.user.id
              '_id': { $ne: card._id }
              'webhook': { $exists: true }
            }
            {_id: 1}
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

app.post '/debounced/apply-mirror', (request, response) ->
  console.log 'applying mirror for changes in', Object.keys request.body.merge
  for cardId, comments of request.body.merge
    # fetch both cards, updated and mirrored
    db.cards.find({ $or: [ { _id: cardId }, { mirror: cardId } ] }).toArray().then((cards) ->
      ids = (c._id for c in cards)
      console.log 'found', ids, 'mirroring', cardId

      source = (cards.splice (ids.indexOf cardId), 1)[0]
      for target in cards

        # name, due, desc
        for difference in diff.diff(target.data, source.data) or []
          console.log 'applying data diff', difference
          if difference.kind == 'E' and difference.path.length == 1
            trello.put "/1/cards/#{target._id}/#{difference.path[0]}", {value: difference.rhs}, (err) ->
              console.log err if err

        # comments
        for comment in comments['create']
          trello.post "/1/cards/#{target._id}/actions/comments",
            { text: mirroredCommentText comment, source._id }
          , (err, data) ->
            console.log err if err
            console.log 'comment created successfully:', data
            # update source model
            db.cards.update(
              { _id: source._id }
              { $set: { "comments.#{comment.sourceCommentId}.#{target._id}": data.id } }
            ).catch((x) -> console.log x)

        for comment in comments['update']
          console.log 'updating comment'
          db.cards.findOne(
            { _id: source._id }
            { "comments.#{comment.sourceCommentId}.#{target._id}": 1 }
          ).then((c) ->
            try
              c.comments[comment.sourceCommentId][target._id]
            catch e
              console.log 'no comment found on source'
              throw e
          ).then((targetCommentId) ->
            trello.put "/1/actions/#{targetCommentId}/text",
              { value: mirroredCommentText comment, source._id }
            , (err, data) ->
              console.log err if err
              console.log 'comment updated successfully:', data
          )

        for comment in comments['delete']
          db.cards.findAndModify(
            query: { _id: source._id }
            fields: { "comments.#{comment.sourceCommentId}.#{target._id}": 1 }
            update: { $unset: { "comments.#{comment.sourceCommentId}.#{target._id}": '' } }
          ).then((c) ->
            try
              c.comments[comment.sourceCommentId][target._id]
            catch e
              console.log 'no comment found on source'
              throw e
          ).then((targetCommentId) ->
            trello.delete "/1/actions/#{targetCommentId}", (err, data) ->
              console.log err if err
              console.log 'comment deleted successfully:', data
          )
    )
  response.send 'ok'

app.post '/webhooks/mirrored-card', (request, response) ->
  payload = request.body
  action = payload.action.type
  console.log 'webhook:', action

  cardId = payload.action.data.card.id

  comments = {}

  switch action # update the card model
    when 'updateCard'
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
      comments['create'] = [
        sourceCommentId: payload.action.data.action.id
      ]

  if payload.action.memberCreator.id == settings.TRELLO_BOT_ID
    return console.log 'webhook triggered by a bot action, don\'t apply mirror.'

  console.log JSON.stringify payload, null, 2

  # apply the update to its mirrored card
  queueApplyMirror cardId, comments

  response.send 'ok'

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port

# utils ~
queueApplyMirror = (cardId, comments={}) ->
  applyMirrorURL = settings.SERVICE_URL + '/debounced/apply-mirror'
  data = {}
  data[cardId] = comments
  superagent.post('http://debouncer.websitesfortrello.com/debounce/15/' + applyMirrorURL)
            .set('Content-Type': 'application/json')
            .send(data)
            .end()

mirroredCommentText = (comment, sourceCardId) ->
  date = moment(comment.date).format('MMMM Do YYYY, h:mm:ssa UTC')
  text = '>' + comment.text.replace /\n/, '\n>'
  "[#{comment.author.name}](https://trello.com/#{comment.author.id}) at [#{date}](https://trello.com/c/#{sourceCardId}):\n\n#{text}"
