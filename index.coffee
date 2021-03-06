settings   = require './settings'

Promise    = require 'bluebird'
Neo4j      = require 'rainbird-neo4j'
NodeTrello = require 'node-trello'
raygun     = require 'raygun'
moment     = require 'moment'
express    = require 'express'
bodyParser = require 'body-parser'
Redis      = require 'then-redis'
url        = require 'url'
zipObject  = require 'lodash.zipobject'
values     = require 'lodash.values'


refbot     = require './refbot'

Trello = Promise.promisifyAll new NodeTrello settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
Neo = new Neo4j settings.NEO4J_URL
Neo.queryAsync = Promise.promisify Neo.query
Neo.execute = -> Neo.queryAsync.apply(Neo, arguments).then((res) -> res[0][0])
raygunClient = new raygun.Client().init(apiKey: settings.RAYGUN_APIKEY)

app = express()
app.use '/static', express.static('static')
app.use bodyParser.json()

app.get '/', (req, res) ->
  res.status(200).json({status:"ok"})

matchCheckItem = (sourceCheckItem, targetCheckItems) ->
  for checkItem in targetCheckItems
    if checkItem.name == sourceCheckItem.name
      return checkItem
  return null


sendOk = (request, response) ->
  console.log 'trello checks this endpoint when creating a webhook'
  response.send 'ok'
app.get '/webhooks/trello-bot', sendOk    # global
app.get '/webhooks/mirrored-card', sendOk # cardsync
app.get '/webhooks/tracked-board', sendOk # refbot

app.post '/webhooks/trello-bot', (request, response) ->
  payload = request.body

  console.log '- bot: ' + payload.action.type
  response.send 'ok'

  switch payload.action.type
    #cardsync hook
    when 'addMemberToCard'
      # add webhook to this card
      Trello.putAsync('/1/webhooks',
        callbackURL: settings.SERVICE_URL + '/webhooks/mirrored-card'
        idModel: payload.action.data.card.id
        description: 'cardsync webhook for card https://trello.com/c/' + payload.action.data.card.id
      ).then((data) ->
        console.log 'webhook created'

        Neo.execute '''
          MERGE (card:Card {shortLink: {SL}})
            SET card.webhook = {WH}
          MERGE (user:User {id: {USERID}})
          MERGE (user)-[:OWNS]->(card)
          WITH user, card
          MERGE (user)-[:OWNS]->(i)-[:MIRRORS]->(source:Source {name: {NAME}})
          MERGE (card)-[:MIRRORS]->(source)
          WITH i WHERE i.shortLink IS NULL
            MATCH (i)-[r]-()
            DELETE i, r
        ''',
          SL: payload.action.data.card.shortLink
          NAME: payload.action.data.card.name
          WH: data.id
          USERID: payload.action.memberCreator.id
      ).then( ->
        sourceShortLink = payload.action.data.card.shortLink;
        sourceCardName  = payload.action.data.card.name;
        console.log "card '#{sourceShortLink}' added to db"
        Trello.getAsync("/1/cards/#{sourceShortLink}/checklists").then((sourceChecklists) ->
          console.log JSON.stringify("sourceChecklists = #{JSON.stringify(sourceChecklists)}")

          Promise.resolve().then(->
            Neo.execute '''
              MATCH (original:Card {shortLink: {SL}})-[:MIRRORS]->(source:Source)
              SET source.name = {NAME}
              WITH source, original
                MATCH (source)<-[:MIRRORS]-(target:Card)
                  WHERE target <> original
                RETURN target, source
            ''',
              SL: sourceShortLink
              NAME: sourceCardName
          ).then((res) ->
            targets = (row['target'].shortLink for row in res)
            console.log '> will sync', targets
            return targets
          ).map((target) ->
            console.log "Syncing #{JSON.stringify(target)}"

            Trello.getAsync("/1/cards/#{target}/checklists").then((targetChecklists) ->
              console.log JSON.stringify("targetChecklists = #{JSON.stringify(targetChecklists)}")

              updateChecklists = Promise.resolve().then( ->
                [0...sourceChecklists.length ]
              ).map((i) ->
                sourceChecklist = sourceChecklists[i]
                targetChecklist = targetChecklists[i]
                if !targetChecklist?
                  console.log  "Skyped checklist! the list does not exist in target card."
                  updateChecklists.cancel
                else
                  console.log  "SYNCING CHECKLISTS #{sourceChecklist.id} to #{targetChecklist.id}"

                  Promise.resolve().then(->
                    Neo.execute '''
                      MATCH (original:Card {shortLink: {ORIG}})
                      MATCH (target:Card {shortLink: {TGT}})
                      MATCH (original)-[:MIRRORS]->(source:Source)<-[:MIRRORS]-(target)
                      MERGE (source)-[:HAS]->(chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]->(original)
                      MERGE (chl)-[:CORRESPONDS_TO {id: {TCLID}}]->(target)
                    ''',
                      ORIG: sourceShortLink
                      TGT: target
                      OCLID: sourceChecklist.id
                      TCLID: targetChecklist.id
                  ).then(->
                    for j in [0...sourceChecklist.checkItems.length]
                      sourceCheckItem = sourceChecklist.checkItems[j]
                      targetCheckItem = matchCheckItem(sourceCheckItem, targetChecklist.checkItems);

                      if targetCheckItem?
                        console.log  "Syncing checkitems #{sourceCheckItem.id} to #{targetCheckItem.id}"
                        Neo.execute '''
                          MATCH (target:Card {shortLink: {TGT}})
                          MATCH (chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]-(original:Card)
                          MERGE (chl)-[:CONTAINS]->(chi:CheckItem)-[:CORRESPONDS_TO {id: {OCIID}}]->(original)
                          MERGE (chi)-[:CORRESPONDS_TO {id: {TCIID}}]->(target)
                        ''',
                          TGT: target
                          OCLID: sourceChecklist.id
                          OCIID: sourceCheckItem.id
                          TCIID: targetCheckItem.id
                      else
                        console.log  "Skyped checkitem! the item does not exist in target checklist."
                  )
              )
            )
          )
        )
      ).catch(console.log.bind console)

    #cardsync hook
    when 'removeMemberFromCard'
      Promise.resolve().then(->
        Neo.execute '''
          MATCH (card:Card {shortLink: {SL}})
          RETURN card
        '''
        , SL: payload.action.data.card.shortLink
      ).then((res) ->
        card = res[0]['card']
        Trello.delAsync '/1/webhooks/' + card.webhook
      ).then(->
        console.log 'webhook deleted'

        Neo.execute '''
          MATCH (card:Card {shortLink: {SL}})<-[owsh:OWNS]-()
          OPTIONAL MATCH (card)-[drel:HAS]->(direct)
          OPTIONAL MATCH (direct)-[idrel:CONTAINS]-(indirect)
          OPTIONAL MATCH (card)-[cr:MIRRORS]->(source:Source)
          DELETE card, owsh, cr, idrel, drel, direct, indirect

          WITH source
            OPTIONAL MATCH (source)<-[or:MIRRORS]-(others:Card)
            WITH source, others WHERE others IS NULL
              DELETE source
        ''',
          SL: payload.action.data.card.shortLink
      ).then(->
        console.log 'card deleted from db'
      ).catch(console.log.bind console)

    #refbot hook
    when 'addMemberToBoard'
        # add webhook to this board
        Trello.putAsync('/1/webhooks',
          callbackURL: settings.SERVICE_URL + '/webhooks/tracked-board'
          idModel: payload.action.data.board.id
          description: 'refbot webhook for this board'
        ).then((data) ->
          console.log 'added to board', payload.action.data.board.name, 'webhook created'
        ).catch(console.log.bind console)

    #refbot hook
    when 'removeMemberFromBoard'
        Promise.resolve().then(->
          Trello.getAsync '/1/token/' + settings.TRELLO_BOT_TOKEN + '/webhooks'
        ).then((webhooks) ->
          for webhook in webhooks
            if webhook.idModel == payload.action.data.board.id
              Trello.delAsync '/1/webhooks/' + webhook.id
        ).spread(->
          console.log 'webhook deleted'
        ).catch(console.log.bind console)


app.post '/webhooks/mirrored-card', (request, response) ->
  payload = request.body
  action = payload.action
  data = action.data

  console.log 'card ' + payload.model.shortUrl + ': ' + payload.action.type
  console.log JSON.stringify payload.action, null, 2
  response.send 'ok'

  if action.memberCreator.id == settings.TRELLO_BOT_ID
    return

  if action.type not in [
    "addAttachmentToCard"
    "addChecklistToCard"
    "commentCard"
    "createCheckItem"
    "deleteAttachmentFromCard"
    "deleteCard"
    "deleteCheckItem"
    "deleteComment"
    "removeChecklistFromCard"
    "updateCard"
    "updateCheckItem"
    "updateCheckItemStateOnCard"
    "updateComment"
  ]
    return

  if action.type == "deleteCard"
    Neo.execute '''
      MATCH (card:Card {shortLink: {SL}})<-[owsh:OWNS]-()
      OPTIONAL MATCH (card)-[drel:HAS]->(direct)
      OPTIONAL MATCH (direct)-[idrel:CONTAINS]-(indirect)
      OPTIONAL MATCH (card)-[cr:MIRRORS]->(source:Source)
      DELETE card, owsh, cr, idrel, drel, direct, indirect

      WITH source
        OPTIONAL MATCH (source)<-[or:MIRRORS]-(others:Card)
        WITH source, others WHERE others IS NULL
          DELETE source
    ''',
      SL: payload.model.shortUrl.split('/')[4]
    return

  Promise.resolve().then(->
    Neo.execute '''
      MATCH (original:Card {shortLink: {SL}})-[:MIRRORS]->(source:Source)
      SET source.name = {NAME}
      WITH source, original
        MATCH (source)<-[:MIRRORS]-(target:Card)
          WHERE target <> original
        RETURN target, source
    ''',
      SL: data.card.shortLink
      NAME: data.card.name
  ).then((res) ->
    targets = (row['target'].shortLink for row in res)
    console.log '> will update', targets
    return targets
  ).map((target) ->
    switch action.type
      when "updateCard"
        changed = Object.keys(data.old)[0]
        if changed in ['name', 'due', 'desc']
          Trello.putAsync "/1/cards/#{target}/#{changed}"
          , value: data.card[changed]
        else if changed =='idAttachmentCover'
          Promise.resolve().then(->
            if not data.card.idAttachmentCover
              return ''

            return Neo.execute('''
              MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
              MATCH (source)-[:HAS]->(att:Attachment)-[:CORRESPONDS_TO {id: {OAID}}]-()
              MATCH (att)-[c:CORRESPONDS_TO]-(target)
              RETURN c.id AS taid
            ''',
              TGT: target
              OAID: data.card.idAttachmentCover
            ).then((res) ->
              return res[0]['taid']
            )
          ).then((targetAttachmentId) ->
            console.log 'taid', targetAttachmentId
            Trello.putAsync "1/cards/#{target}/idAttachmentCover"
            , value: targetAttachmentId
          )
        else if changed == "idList"
          console.log "update list!"
          newListName = data.listAfter.name
          console.log "newListName = '#{newListName}'"
          Trello.getAsync("1/cards/#{target}").then((card) ->
            idBoard = card.idBoard
            console.log "idBoard = #{idBoard}"

            currentListId = card.idList
            console.log "currentListId = #{currentListId}"

            Trello.getAsync("1/boards/#{idBoard}/lists").then((lists) ->
              newListId = null
              console.log "lists = #{JSON.stringify(lists)}"
              for index, list of lists
                if list.name == newListName
                  newListId = list.id
              console.log "newListId = #{newListId}"
              if (newListId != null) && (newListId != currentListId)
                console.log "Moving card from #{currentListId} to #{newListId}"
                Trello.putAsync "/1/cards/#{target}/#{changed}", value: newListId
            )
          )
      when "commentCard"
        Promise.resolve().then(->
          date = moment(action.date).format('MMMM Do YYYY, h:mm:ssa UTC')
          text = '>' + data.text.replace /\n/g, '\n>'
          Trello.postAsync "/1/cards/#{target}/actions/comments"
          , text: """
            [#{action.memberCreator.username}](https://trello.com/#{action.memberCreator.username}) on [#{date}](https://trello.com/c/#{data.card.shortLink})

            #{text}
            """
        ).then((newComment) ->
          Neo.execute '''
            MATCH (original:Card {shortLink: {ORIG}})
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (original)-[:MIRRORS]->(source:Source)<-[:MIRRORS]-(target)
            MERGE (source)-[:HAS]->(comm:Comment)-[:CORRESPONDS_TO {id: {OCID}}]->(original)
            MERGE (comm)-[:CORRESPONDS_TO {id: {TCID}}]->(target)
          ''',
            ORIG: data.card.shortLink
            TGT: target
            OCID: action.id
            TCID: newComment.id
        )
      when "updateComment"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
            MATCH (source)-[:HAS]->(comm:Comment)-[:CORRESPONDS_TO {id: {OCID}}]-()
            MATCH (comm)-[c:CORRESPONDS_TO]-(target)
            RETURN c.id AS tcid
          ''',
            TGT: target
            OCID: data.action.id
        ).then((res) ->
          return res[0]['tcid']
        ).then((targetCommentId) ->
          date = moment(action.date).format('MMMM Do YYYY, h:mm:ssa UTC')
          text = '>' + data.action.text.replace /\n/g, '\n>'
          Trello.putAsync "/1/cards/#{target}/actions/#{targetCommentId}/comments"
          , text: """
            [#{action.memberCreator.username}](https://trello.com/#{action.memberCreator.username}) on [#{date}](https://trello.com/c/#{data.card.shortLink})

            #{text}
            """
        )
      when "deleteComment"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
            MATCH (source)-[:HAS]->(comm:Comment)-[:CORRESPONDS_TO {id: {OCID}}]-()
            MATCH (comm)-[c:CORRESPONDS_TO]-(target)
            RETURN c.id AS tcid
          ''',
            TGT: target
            OCID: data.action.id
        ).then((res) ->
          return res[0]['tcid']
        ).then((targetCommentId) ->
          Trello.delAsync "/1/cards/#{target}/actions/#{targetCommentId}/comments"
          Neo.execute '''
            MATCH (comm:Comment)-[c:CORRESPONDS_TO {id: {TCID}}]-(target)
            DELETE c
            WITH comm, target
              OPTIONAL MATCH (comm)-[cr:CORRESPONDS_TO]-(cards:Card)
                WHERE cr.id <> {OCID}
              WITH cards, comm WHERE cards IS NULL
                MATCH (comm)-[r]-()
                DELETE comm, r
          ''',
            OCID: data.action.id
            TCID: targetCommentId
        )
      when "addAttachmentToCard"
        Promise.resolve().then(->
          Trello.postAsync "/1/cards/#{target}/attachments"
          , {url: data.attachment.url, name: data.attachment.name}
        ).then((newAttachment) ->
          Neo.execute '''
            MATCH (original:Card {shortLink: {ORIG}})
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (original)-[:MIRRORS]->(source:Source)<-[:MIRRORS]-(target)
            MERGE (source)-[:HAS]->(att:Attachment)-[:CORRESPONDS_TO {id: {OAID}}]->(original)
            MERGE (att)-[:CORRESPONDS_TO {id: {TAID}}]->(target)
          ''',
            ORIG: data.card.shortLink
            TGT: target
            OAID: data.attachment.id
            TAID: newAttachment.id
        )
      when "deleteAttachmentFromCard"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
            MATCH (source)-[:HAS]->(att:Attachment)-[:CORRESPONDS_TO {id: {OAID}}]-()
            MATCH (att)-[c:CORRESPONDS_TO]-(target)
            RETURN c.id AS taid
          ''',
            TGT: target
            OAID: data.attachment.id
        ).then((res) ->
          return res[0]['taid']
        ).then((targetAttachmentId) ->
          Trello.delAsync "/1/cards/#{target}/attachments/#{targetAttachmentId}"
          Neo.execute '''
            MATCH (att:Attachment)-[c:CORRESPONDS_TO {id: {TAID}}]-(target)
            DELETE c
            WITH att, target
              OPTIONAL MATCH (att)-[cr:CORRESPONDS_TO]-(cards:Card)
                WHERE cr.id <> {OAID}
              WITH cards, att WHERE cards IS NULL
                MATCH (att)-[r]-()
                DELETE att, r
          ''',
            OAID: data.attachment.id
            TAID: targetAttachmentId
        )
      when "addChecklistToCard"
        Promise.resolve().then(->
          Trello.postAsync "/1/cards/#{target}/checklists"
          , name: data.checklist.name
        ).then((newChecklist) ->
          Neo.execute '''
            MATCH (original:Card {shortLink: {ORIG}})
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (original)-[:MIRRORS]->(source:Source)<-[:MIRRORS]-(target)
            MERGE (source)-[:HAS]->(chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]->(original)
            MERGE (chl)-[:CORRESPONDS_TO {id: {TCLID}}]->(target)
          ''',
            ORIG: data.card.shortLink
            TGT: target
            OCLID: data.checklist.id
            TCLID: newChecklist.id
        )
      when "removeChecklistFromCard"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
            MATCH (source)-[:HAS]->(chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]-()
            MATCH (chl)-[c:CORRESPONDS_TO]-(target)
            RETURN c.id AS tclid
          ''',
            TGT: target
            OCLID: data.checklist.id
        ).then((res) ->
          return res[0]['tclid']
        ).then((targetChecklistId) ->
          Trello.delAsync "/1/cards/#{target}/checklists/#{targetChecklistId}"
          Neo.execute '''
            MATCH (chl:Checklist)-[c:CORRESPONDS_TO {id: {TCLID}}]-(target)
            DELETE c
            WITH chl, target
              OPTIONAL MATCH (chl)-[cr:CORRESPONDS_TO]-(cards:Card)
                WHERE cr.id <> {OCLID}
              WITH cards, chl WHERE cards IS NULL
                MATCH (chl)-[r]-()
                MATCH (chl)-[cir]-(chi:CheckItem)-[cisr]-()
                DELETE chl, r, cir, chi, cisr
          ''',
            OCLID: data.checklist.id
            TCLID: targetChecklistId
        )
      when "createCheckItem"
        checkids = Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})-->(source:Source)
            MATCH (source)-[:HAS]->(chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]-()
            MATCH (chl)-[c:CORRESPONDS_TO]-(target)
            RETURN c.id AS tclid
          ''',
            TGT: target
            OCLID: data.checklist.id
        ).then((res) ->
          if res.length == 0
            console.log "Checklist was not updated because it is not under sync"
            return checkids.cancel();
          else
            return res[0]['tclid']
        ).then((targetChecklistId) ->
          Trello.postAsync "/1/cards/#{target}/checklist/#{targetChecklistId}/checkItem"
          , name: data.checkItem.name
        ).then((newCheckItem) ->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (chl:Checklist)-[:CORRESPONDS_TO {id: {OCLID}}]-(original:Card)
            MERGE (chl)-[:CONTAINS]->(chi:CheckItem)-[:CORRESPONDS_TO {id: {OCIID}}]->(original)
            MERGE (chi)-[:CORRESPONDS_TO {id: {TCIID}}]->(target)
          ''',
            TGT: target
            OCLID: data.checklist.id
            OCIID: data.checkItem.id
            TCIID: newCheckItem.id
        )
      when "updateCheckItem", "updateCheckItemStateOnCard", "deleteCheckItem"
        checkids = Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (chi:CheckItem)-[:CORRESPONDS_TO {id: {OCIID}}]-(original:Card)
            MATCH (chl:Checklist)-[:CONTAINS]->(chi)-[ctci:CORRESPONDS_TO]-(target)
            MATCH (chl)-[ctcl:CORRESPONDS_TO]-(target)
            RETURN ctcl.id AS tclid, ctci.id AS tciid
          ''',
            OCIID: data.checkItem.id
            TGT: target
        ).then((res) ->
          if res.length == 0
            console.log "Checklist was not updated because it is not under sync"
            return checkids.cancel();
          else
            return [res[0]['tclid'], res[0]['tciid']]
        )

        switch payload.action.type
          when "updateCheckItem"
            checkids = checkids.spread((targetChecklistId, targetCheckItemId) ->
              Trello.putAsync "/1/cards/#{target}/checklist/#{targetChecklistId}/checkItem/#{targetCheckItemId}/name"
              , value: data.checkItem.name
            )
          when "updateCheckItemStateOnCard"
            checkids = checkids.spread((targetChecklistId, targetCheckItemId) ->
              Trello.putAsync "/1/cards/#{target}/checklist/#{targetChecklistId}/checkItem/#{targetCheckItemId}/state"
              , value: data.checkItem.state
            )
          when "deleteCheckItem"
            checkids = checkids.spread((targetChecklistId, targetCheckItemId) ->
              Trello.delAsync "/1/cards/#{target}/checklist/#{targetChecklistId}/checkItem/#{targetCheckItemId}"
              Neo.execute '''
                MATCH (chi:CheckItem)-[c:CORRESPONDS_TO {id: {TCIID}}]-(target:Card)
                DELETE c
                WITH chi, target
                  OPTIONAL MATCH (chi)-[cr:CORRESPONDS_TO]-(cards:Card)
                    WHERE cr.id <> {OCIID}
                  WITH cards, chi WHERE cards IS NULL
                    MATCH (chi)-[r]-()
                    DELETE chi, r
              ''',
                OCIID: data.checkItem.id
                TCIID: targetCheckItemId
            )
  ).then(->
    console.log '> everything done.'
  ).catch((e) ->
    raygunClient.send e, {'message': 'error catched in the .catch handler'}, (->), request
  )

app.use raygunClient.expressHandler

port = process.env.PORT or 5000

refbot.addRefbotHooks app
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port
