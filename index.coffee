settings   = require './settings'

util       = require 'util'
diff       = require 'deep-diff'
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
          comments: {}
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
            throw err if err
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
            {$unset: {webhook: '', data: '', comments: ''}}
          )
        )

app.post '/debounced/apply-mirror', (request, response) ->
  console.log 'applying mirror for changes in', Object.keys request.body.merge
  for cardId of request.body.merge
    # fetch both cards, updated and mirrored
    db.cards.find({ $or: [ { _id: cardId }, { mirror: cardId } ] }).toArray().then((cards) ->
      ids = (c._id for c in cards)
      console.log 'found', ids, 'mirroring', cardId

      source = (cards.splice (ids.indexOf cardId), 1)[0]
      console.log 'SOURCE:', source
      for target in cards
        console.log 'TARGET:', target

        # name, due, desc
        for difference in diff.diff target.data, source.data
          console.log 'applying data diff', difference
          if difference.kind == 'E' and difference.path.length == 1
            trello.put "/1/cards/#{target._id}/#{difference.path[0]}", {value: difference.rhs}, (err) ->
              console.log err if err
        console.log 'finished applying data diff'

        # comments
        cdiff = diff.diff target.comments, source.comments
        console.log 'cdiff:', typeof cdiff, 'length:', cdiff.length
        for difference in diff
          console.log 'applying comment diff', difference
          if difference.path.length == 1
            comment = difference.rhs
            if difference.kind == 'N' # add
              console.log 'creating comment'
              trello.post "/1/cards/#{cardId}/actions/comments",
                { text: "[#{comment.author.name}](https://trello.com/#{comment.author.id}) at [#{comment.date}](https://trello.com/c/#{source._id})\n\n---\n\n#{comment.text}" }
              , (err, data) ->
                throw err if err
                console.log 'comment created successfully:', data
                # TODO update target model
            else if difference.kind == 'D' # delete
              console.log 'deleting comment'
              commentId = difference.path[0]
              trello.delete "/1/actions/#{commentId}", (err, data) ->
                throw err if err
                console.log 'comment deleted successfully:', data
                # TODO update target model
          else if difference.path.length == 2 and difference.kind == 'E' # edit
            console.log 'updating comment'
            commentId = difference.path[0]
            text = o.split('---')
            switch difference.path[1]
              when 'text' then text = [text[0], difference.rhs]
              when 'date' then text[0] = text[0].replace /at \[[^]]*\]/, "at [#{difference.rhs}]"
            trello.put "/1/actions/#{commentId}/text",
              { text: '---'.join(text) }
            , (err, data) ->
              throw err if err
              console.log 'comment updated successfully:', data
              # TODO update target model

        console.log 'all diffs applied'
      console.log 'end of targets'
    )
  response.send 'ok'

app.post '/webhooks/mirrored-card', (request, response) ->
  payload = request.body
  action = payload.action.type
  console.log 'webhook:', action

  console.log JSON.stringify payload, null, 2
  cardId = payload.action.data.card.id

  if payload.action.memberCreator.id == settings.TRELLO_BOT_ID
    console.log 'webhook triggered by a bot action, ignore.'

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
      comment =
        id: payload.action.id
        text: payload.action.data.text
        author:
          id: payload.action.memberCreator.id
          name: payload.action.memberCreator.username
        date: payload.action.date

      set = {}
      set['comments.' + comment.id] = comment

      db.cards.update(
        { _id: cardId }
        { $set: set }
      )
    when 'updateComment', 'deleteComment'
      console.log 'x'

  # apply the update to its mirrored card
  queueApplyMirror cardId

  response.send 'ok'

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port

# utils ~
queueApplyMirror = (cardId) ->
  applyMirrorURL = settings.SERVICE_URL + '/debounced/apply-mirror'
  data = {}
  data[cardId] = true
  superagent.post('http://debouncer.websitesfortrello.com/debounce/15/' + applyMirrorURL)
            .set('Content-Type': 'application/json')
            .send(data)
            .end()
