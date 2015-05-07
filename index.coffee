settings   = require './settings'

jdp        = require 'jsondiffpatch'
diff       = require 'deep-diff'
xtend      = require 'xtend'
moment     = require 'moment'
express    = require 'express'
superagent = require 'superagent'
bodyParser = require 'body-parser'

trello = new (require 'node-trello') settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
db     = (require 'promised-mongo') settings.MONGO_URI, ['cards']

app = express()
app.use express.static(__dirname + '/static')
app.use bodyParser.json()

cldiff = jdp.create(objectHash: (o) -> o.name)
log = (msg) -> (a, b) ->
  if b then console.log msg, a, b else console.log msg, a
  return a

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
        console.log 'bot webhook:', action
        db.cards.update(
          query: {_id: payload.action.data.card.id }
          update: { $unset: {webhook: '', data: ''} }
        ).then(->
          # remove webhook from this card
          # trello.del '/1/webhooks/' + card.webhook, log 'deleted webhook'
          # do not remove. trello doesn't duplicate webhooks.
          # there's always 1 model-webhook to 1 token

          # return
          response.send 'ok'
        )

app.post '/debounced/apply-mirror/data', (request, response) ->
  console.log 'applying DATA mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      # fetch both cards, updated and mirrored
      db.cards.find(
        {
          $or: [ { _id: cardId }, { mirror: cardId } ]
          webhook: { $exists: true }
        }
      ).toArray().then((cards) ->
        ids = (c._id for c in cards)
        console.log 'found', ids, 'mirroring', cardId

        source = (cards.splice (ids.indexOf cardId), 1)[0]
        console.log 'SOURCE:', source._id
        for target in cards

          # name, due, desc, idAttachmentCover
          for difference in diff.diff(target.data, source.data) or []
            console.log 'applying data diff', difference
            if difference.kind in ['E', 'N'] and difference.path.length == 1
              value = difference.rhs

              # if we are setting idAttachmentCover, get the corresponding attachment id of this card
              # (since the one we have now is an id of an attachment of the source card, which cannot be the cover of this)
              if difference.path[0] == 'idAttachmentCover' and difference.rhs
                console.log source.attachments
                console.log value
                console.log target._id
                try
                  value = source.attachments[value][target._id]
                catch e
                  console.log 'the desired cover image is not available here'
                console.log 'new value:', value

              trello.put "/1/cards/#{target._id}/#{difference.path[0]}", {value: difference.rhs}, (err) ->
                console.log err if err
      )
    )()

  response.send 'ok'

app.post '/debounced/apply-mirror/checklists', (request, response) ->
  console.log 'applying CHECKLISTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      # fetch both cards, updated and mirrored
      db.cards.find({ $or: [ { _id: cardId }, { mirror: cardId } ] }).toArray().then((cards) ->
        ids = (c._id for c in cards)
        console.log 'found', ids, 'mirroring', cardId

        source = (cards.splice (ids.indexOf cardId), 1)[0]
        for target in cards

          # checklists
          d = cldiff.diff target.checklists, source.checklists
          console.log JSON.stringify d, null, 2
          for k, list of d when k isnt '_t'
            if k[0] == '_' # deleted or moved
              if list[2] == 0
                # checklist deleted
                console.log 'will delete checklist', list[0]
                trello.del "/1/checklists/#{list[0].id}", log "checklist deleted:"
            else if Array.isArray list
              # checklist added
              console.log 'will add checklist', list[0]
              (->
                chklist = list
                trello.post '/1/checklists', {
                  name: chklist[0].name
                  pos: chklist[0].pos
                  idCard: target._id
                }, (err, data) ->
                  return console.log err if err
                  for _, item of chklist[0].checkItems
                    console.log 'checklist created'
                    trello.post "/1/checklists/#{data.id}/checkItems", {
                      name: item.name
                      pos: item.pos
                      checked: item.state is 'complete'
                    }, log "checkitem added on newly created checklist"
              )()
            else if (list.pos or list.checkItems)
              # checklist modified
              if Array.isArray list.pos
                trello.put "/1/checklists/#{list.id[0]}/pos", { value: list.pos[1] }, log 'changed checkitem position'
              for ki, item of list.checkItems when ki isnt '_t'
                if ki[0] == '_' # deleted or moved
                  if item[2] == 0
                    # checkitem deleted
                    console.log 'will delete checkitem', item[0]
                    trello.del(
                      "/1/checklists/#{list.id[0]}/checkItems/#{item[0].id}"
                      log 'checkitem deleted'
                    )
                else if Array.isArray item
                  # checkitem added
                  console.log 'will add checkitem'
                  trello.post "/1/checklists/#{list.id[0]}/checkItems", {
                    name: item[0].name
                    pos: item[0].pos
                    state: item[0].state is 'complete'
                  }, log 'checkitem created'
                else if (item.state or item.pos)
                  # checkitem modified
                  update = {}
                  for prop in ['state', 'pos'] when item[prop]
                    update[prop] = item[prop][1]
                  continue if Object.keys(update) == 0

                  console.log 'will update checkitem', item
                  trello.put(
                    "/1/cards/#{target._id}/checklist/#{list.id[0]}/checkItem/#{item.id[0]}"
                    update
                    log 'checkitem updated'
                  )

          # we're doing this for each target
          queueRefetchChecklists target._id, {applyMirror: false}
      )
    )()

  response.send 'ok'

app.post '/debounced/apply-mirror/comments', (request, response) ->
  console.log 'applying COMMENTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      # fetch both cards, updated and mirrored
      db.cards.find({ $or: [ { _id: cardId }, { mirror: cardId } ] }).toArray().then((cards) ->
        ids = (c._id for c in cards)
        console.log 'found', ids, 'mirroring', cardId

        source = (cards.splice (ids.indexOf cardId), 1)[0]
        for target in cards

          # comments
          console.log '   create', changes.comments['create'].length
          for comment in changes.comments['create']
            trello.post "/1/cards/#{target._id}/actions/comments",
              { text: mirroredCommentText comment, source._id }
            , (err, data) ->
              console.log err if err
              console.log 'comment created successfully:', data
              # update source model
              db.cards.update(
                { _id: source._id }
                { $set: { "comments.#{comment.sourceCommentId}.#{target._id}": data.id } }
              ).then((x) -> console.log 'created comment added to source card on db:', x)

          console.log '   update', changes.comments['update'].length
          for comment in changes.comments['update']
            console.log 'updating comment'
            try
              targetCommentId = source.comments[comment.sourceCommentId][target._id]
            catch e
              console.log 'no comment found on source:', JSON.stringify(source.comments)
              throw e

            trello.put "/1/actions/#{targetCommentId}/text",
              { value: mirroredCommentText comment, source._id }
            , (err, data) ->
              console.log err if err
              console.log 'comment updated successfully:', data

          console.log '   delete', changes.comments['delete'].length
          for comment in changes.comments['delete']
            try
              targetCommentId = source.comments[comment.sourceCommentId][target._id]
            catch e
              console.log 'no comment found on source:', JSON.stringify(source.comments)
              throw e

            console.log 'deleting comment', targetCommentId
            trello.del "/1/actions/#{targetCommentId}", (err, data) ->
              console.log err if err
              console.log 'comment deleted successfully:', data
              db.cards.update(
                query: { _id: source._id }
                update: { $unset: { "comments.#{comment.sourceCommentId}.#{target._id}": '' } }
              )
      )
    )()

  response.send 'ok'

app.post '/debounced/apply-mirror/attachments', (request, response) ->
  console.log 'applying ATTACHMENTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      # fetch both cards, updated and mirrored
      db.cards.find({ $or: [ { _id: cardId }, { mirror: cardId } ] }).toArray().then((cards) ->
        ids = (c._id for c in cards)
        console.log 'found', ids, 'mirroring', cardId

        source = (cards.splice (ids.indexOf cardId), 1)[0]
        for target in cards

          # attachments
          console.log '   add', changes.attachments['add'].length
          for attachment in changes.attachments['add']
            console.log 'adding attachment', attachment.url
            trello.post "/1/cards/#{target._id}/attachments",
              { url: attachment.url, name: attachment.name }
            , (err, data) ->
              console.log err if err
              console.log 'added successfully:', data
              # update source and target model (unlike the case of comments, deleting attachments added by the bot also delete the original attachment)
              db.cards.update(
                { _id: source._id }
                { $set: { "attachments.#{attachment.sourceAttachmentId}.#{target._id}": data.id } }
              ).catch((x) -> console.log x)
              db.cards.update(
                { _id: target._id }
                { $set: { "attachments.#{data.id}.#{source._id}": attachment.sourceAttachmentId } }
              ).catch((x) -> console.log x)
            
          console.log '   delete', changes.attachments['delete'].length
          for attachment in changes.attachments['delete']
            try
              targetAttachmentId = source.attachments[attachment.sourceAttachmentId][target._id]
            catch e
              console.log 'no attachment found on source:', JSON.stringify(source.attachments)
              throw e

            console.log 'deleting attachment', targetAttachmentId
            trello.del "/1/cards/#{target._id}/attachments/#{targetAttachmentId}", (err, data) ->
              console.log err if err
              console.log 'attachment deleted successfully:', data
              db.cards.update(
                query: { _id: source._id }
                update: { $unset: { "attachment.#{attachment.sourceAttachmentId}.#{target._id}": '' } }
              )
      )
    )()

  response.send 'ok'

app.post '/debounced/refetch-checklists', (request, response) ->
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

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port

# utils ~
queueApplyMirror = (kind, cardId, changes={}) ->
  changes = xtend(
    { comments: {create: [], update: [], delete: []}, attachments: {add: [], delete: []} }
    changes
  )

  console.log '... queueing', kind,'mirror process for', cardId, 'with:', JSON.stringify changes

  applyMirrorURL = settings.SERVICE_URL + '/debounced/apply-mirror/' + kind
  data = {}
  data[cardId] = changes
  superagent.post('http://debouncer.websitesfortrello.com/debounce/13/' + applyMirrorURL)
            .set('Content-Type': 'application/json')
            .send(data)
            .end()

queueRefetchChecklists = (cardId, options={applyMirror: false}) ->
  refetchChecklistsURL = settings.SERVICE_URL + '/debounced/refetch-checklists'
  data = {}
  data[cardId] = true
  data.options = {}
  data.options[cardId] = options
  superagent.post('http://debouncer.websitesfortrello.com/debounce/9/' + refetchChecklistsURL)
            .set('Content-Type': 'application/json')
            .send(data)
            .end()

mirroredCommentText = (comment, sourceCardId) ->
  date = moment(comment.date).format('MMMM Do YYYY, h:mm:ssa UTC')
  text = '>' + comment.text.replace /\n/, '\n>'
  "[#{comment.author.name}](https://trello.com/#{comment.author.id}) at [#{date}](https://trello.com/c/#{sourceCardId}):\n\n#{text}"
