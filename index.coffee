settings   = require './settings'

Promise    = require 'bluebird'
Neo4j      = require 'rainbird-neo4j'
NodeTrello = require 'node-trello'
moment     = require 'moment'
express    = require 'express'
bodyParser = require 'body-parser'

Trello = Promise.promisifyAll new NodeTrello settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
Neo = new Neo4j settings.NEO4J_URL
Neo.queryAsync = Promise.promisify Neo.query
Neo.execute = -> Neo.queryAsync.apply(Neo, arguments).then((res) -> res[0][0])

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

  console.log '- bot: ' + payload.action.type
  response.send 'ok'

  switch payload.action.type
    when 'addMemberToCard'
      # add webhook to this card
      Trello.putAsync('/1/webhooks',
        callbackURL: settings.SERVICE_URL + '/webhooks/mirrored-card'
        idModel: payload.action.data.card.id
      ).then((data) ->
        console.log 'webhook created'

        Neo.execute '''
          MERGE (card:Card {shortLink: {SL}})
          SET card.webhook = {WH}
          SET card.name = {NAME}
          MERGE (user:User {id: {USERID}})
          MERGE (user)-[:CONTROLS]->(card)
          WITH user, card
          MATCH (user)-[:CONTROLS]->(others:Card)
            WHERE NOT others.shortLink = {SL} AND
                  others.name = card.name
          MERGE (card)-[:MIRRORS]->(others)
        ''',
          SL: payload.action.data.card.shortLink
          NAME: payload.action.data.card.name
          WH: data.id
          USERID: payload.action.memberCreator.id
      ).then( ->
        console.log 'card added to db'
      ).catch(console.log.bind console)

    when 'removeMemberFromCard', 'deleteCard'
      Promise.resolve().then(->
        Trello.getAsync '/1/cards/' + payload.action.data.card.id
        , fields: 'shortLink'
      ).then((card) ->
        Neo.execute '''
          MATCH (card:Card {shortLink: {SL}})
          RETURN card
        '''
        , SL: card.shortLink
      ).then((res) ->
        card = res[0]['card']
        Trello.delAsync '/1/webhooks/' + card.webhook
      ).then(->
        console.log 'webhook deleted'

        Neo.execute '''
          MATCH (card:Card {shortLink: {ID}})-[rel]-()
          DELETE rel, card
        ''',
          ID: payload.action.data.card.shortLink
      ).then(->
        console.log 'card deleted from db'
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

  Promise.resolve().then(->
    Neo.execute '''
      MATCH (source:Card {shortLink: {SL}})
      MATCH (source)-[:MIRRORS]-(target:Card)
      RETURN target, source
    ''',
      SL: data.card.shortLink
  ).then((res) ->
    targets = (row['target'].shortLink for row in res)
    console.log '> will update', targets
    return targets
  ).map((target) ->
    switch action.type
      when "updateCard"
        changed = Object.keys(data.old)[0]
        if changed in ['name', 'due', 'desc']
          Trello.putAsync("/1/cards/#{target}/#{changed}"
          , value: data.card[changed]
          ).then(->
            if changed == 'name'
              Neo.execute '''
                MATCH (card:Card {shortLink: {SL}})
                SET card.name = {NAME}
              ''',
                SL: data.card.shortLink
                NAME: data.card[changed]
          )
        else if changed =='idAttachmentCover'
          Promise.resolve().then(->
            if not data.card.idAttachmentCover
              return ''

            return Neo.execute('''
              MATCH (target:Card {shortLink: {TGT}})
              MATCH (sa:Attachment {id: {SAID}})
              MATCH (sa)-[:LINKED_TO]-(ta:Attachment)<-[:HAS]-(target)
              RETURN ta
            ''',
              TGT: target
              SAID: data.card.idAttachmentCover
            ).then((res) ->
              console.log res
              return res[0]['ta'].id
            )
          ).then((targetAttachmentId) ->
            console.log 'taid', targetAttachmentId
            Trello.putAsync "1/cards/#{target}/idAttachmentCover"
            , value: targetAttachmentId
          )
      when "commentCard"
        Promise.resolve().then(->
          date = moment(action.date).format('MMMM Do YYYY, h:mm:ssa UTC')
          text = '>' + data.text.replace /\n/g, '\n>'
          Trello.postAsync "/1/cards/#{target}/actions/comments"
          , text: """
            [#{action.memberCreator.username}](https://trello.com/#{action.memberCreator.username}) at [#{date}](https://trello.com/c/#{data.card.shortLink}):

            #{text}
            """
        ).then((newComment) ->
          Neo.execute '''
            MATCH (source:Card {shortLink: {SRC}})
            MATCH (target:Card {shortLink: {TGT}})
            MERGE (source)-[:HAS]->(sc:Comment {id: {SCID}})
            MERGE (target)-[:HAS]->(tc:Comment {id: {TCID}})
            MERGE (sc)-[:LINKED_TO]->(tc)
          ''',
            SRC: data.card.shortLink
            TGT: target
            SCID: action.id
            TCID: newComment.id
        )
      when "updateComment"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (sc:Comment {id: {SCID}})
            MATCH (target)-[:HAS]->(ta:Comment)-[:LINKED_TO]-(sc)
            RETURN ta
          ''',
            TGT: target
            SCID: data.action.id
        ).then((res) ->
          return res[0]['ta'].id
        ).then((targetCommentId) ->
          date = moment(action.date).format('MMMM Do YYYY, h:mm:ssa UTC')
          text = '>' + data.action.text.replace /\n/g, '\n>'
          Trello.putAsync "/1/cards/#{target}/actions/#{targetCommentId}/comments"
          , text: """
            [#{action.memberCreator.username}](https://trello.com/#{action.memberCreator.username}) at [#{date}](https://trello.com/c/#{data.card.shortLink}):

            #{text}
            """
        )
      when "deleteComment"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (sc:Comment {id: {SCID}})
            MATCH (target)-[:HAS]->(ta:Comment)-[:LINKED_TO]-(sc)
            RETURN ta
          ''',
            TGT: target
            SCID: data.action.id
        ).then((res) ->
          return res[0]['ta'].id
        ).then((targetCommentId) ->
          Trello.delAsync "/1/cards/#{target}/actions/#{targetCommentId}/comments"
          Neo.execute '''
            MATCH (sc {id: {SCID}})-[srel]-()
            MATCH (tc {id: {TCID}})-[trel]-()
            DELETE srel, trel, sc, tc
          ''',
            SCID: data.action.id
            TCID: targetCommentId
        )
      when "addAttachmentToCard"
        Promise.resolve().then(->
          Trello.postAsync "/1/cards/#{target}/attachments"
          , {url: data.attachment.url, name: data.attachment.name}
        ).then((newAttachment) ->
          Neo.execute '''
            MATCH (source:Card {shortLink: {SRC}})
            MATCH (target:Card {shortLink: {TGT}})
            MERGE (source)-[:HAS]->(sa:Attachment {id: {SAID}})
            MERGE (target)-[:HAS]->(ta:Attachment {id: {TAID}})
            MERGE (sa)-[:LINKED_TO]->(ta)
          ''',
            SRC: data.card.shortLink
            TGT: target
            SAID: data.attachment.id
            TAID: newAttachment.id
        )
      when "deleteAttachmentFromCard"
        Promise.resolve().then(->
          Neo.execute '''
            MATCH (target:Card {shortLink: {TGT}})
            MATCH (sa:Attachment {id: {SAID}})
            MATCH (sa)-[:LINKED_TO]-(ta:Attachment)<-[:HAS]-(target)
            RETURN ta
          ''',
            SRC: data.card.shortLink
            TGT: target
            SAID: data.attachment.id
        ).then((res) ->
          return res[0]['ta'].id
        ).then((targetAttachmentId) ->
          Trello.delAsync "/1/cards/#{target}/attachments/#{targetAttachmentId}"
          Neo.execute '''
            MATCH (sa {id: {SAID}})-[srel]-()
            MATCH (ta {id: {TAID}})-[trel]-()
            DELETE srel, trel, sa, ta
          ''',
            SAID: data.attachment.id
            TAID: targetAttachmentId
        )
      #when "addChecklistToCard"
      #when "createCheckItem"
      #when "updateCheckItem"
      #when "updateCheckItemStateOnCard"
      #when "deleteCheckItem"
      #when "removeChecklistFromCard"

  ).then(->
    console.log '> everything done.'
  ).catch(console.log.bind console)

port = process.env.PORT or 5000
app.listen port, '0.0.0.0', ->
  console.log 'running at 0.0.0.0:' + port
