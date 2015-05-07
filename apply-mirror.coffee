jdp        = require 'jsondiffpatch'
diff       = require 'deep-diff'
moment     = require 'moment'
express    = require 'express'
bodyParser = require 'body-parser'

{trello, db,
 queueApplyMirror,
 queueRefetchChecklists,
 mirroredCommentText,
 log} = require './setup'

cldiff = jdp.create(objectHash: (o) -> o.name)

app = express()
app.use bodyParser.json()

app.post '/data', (request, response) ->
  console.log 'applying DATA mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      eachTargetForSource cardId, (source, target) ->
        # name, due, desc, idAttachmentCover
        for difference in diff.diff(target.data, source.data) or []
          console.log 'applying data diff', difference
          if difference.kind in ['E', 'N'] and difference.path.length == 1
            value = difference.rhs

            # if we are setting idAttachmentCover, get the corresponding attachment id of this card
            # (since the one we have now is an id of an attachment of the source card, which cannot be the cover of this)
            if difference.path[0] == 'idAttachmentCover' and difference.rhs
              try
                value = source.attachments[value][target._id]
              catch e
                console.log 'the desired cover image is not available here'
              console.log 'new idAttachmentCover value:', value

            trello.put "/1/cards/#{target._id}/#{difference.path[0]}", {value: value}, (err) ->
              console.log err if err
    )()

  response.send 'ok'

app.post '/checklists', (request, response) ->
  console.log 'applying CHECKLISTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      eachTargetForSource cardId, (source, target) ->
        d = cldiff.diff target.checklists, source.checklists
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
  )()

  response.send 'ok'

app.post '/comments', (request, response) ->
  console.log 'applying COMMENTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload

      eachTargetForSource cardId, (source, target) ->
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
    )()

  response.send 'ok'

app.post '/attachments', (request, response) ->
  console.log 'applying ATTACHMENTS mirror for changes in', Object.keys request.body.merge

  cards = request.body.merge
  for id, payload of cards
    (->
      cardId = id
      changes = payload
      console.dir changes

      eachTargetForSource cardId, (source, target) ->
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
            return

          console.log 'deleting attachment', targetAttachmentId
          trello.del "/1/cards/#{target._id}/attachments/#{targetAttachmentId}", (err, data) ->
            console.log err if err
            console.log 'attachment deleted successfully:', data
            db.cards.update(
              query: { _id: source._id }
              update: { $unset: { "attachment.#{attachment.sourceAttachmentId}.#{target._id}": '' } }
            )
    )()

  response.send 'ok'

module.exports = app

# utils
eachTargetForSource = (sourceId, callback) ->
  db.cards.find(
    {
      $or: [ { _id: sourceId }, { mirror: sourceId } ]
      webhook: { $exists: true }
    }
  ).toArray().then((cards) ->
    # fetch both cards, updated and mirrored
    ids = (c._id for c in cards)

    source = (cards.splice (ids.indexOf sourceId), 1)[0]
    console.log ':: MIRROR', (x._id for x in cards)
    for target in cards
      console.log ":: MIRROR [#{source._id}]=>[#{target._id}]"
      callback source, target
  )
