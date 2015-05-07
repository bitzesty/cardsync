settings   = require './settings'

superagent = require 'superagent'
extend     = require 'deep-extend'
moment     = require 'moment'
NodeTrello = require 'node-trello'
PMongo     = require 'promised-mongo'

module.exports.trello = new NodeTrello settings.TRELLO_API_KEY, settings.TRELLO_BOT_TOKEN
module.exports.db     = PMongo settings.MONGO_URI, ['cards']

# utils ~
module.exports.log = (msg) -> (a, b) ->
  if b then console.log msg, a, b else console.log msg, a
  return a

module.exports.queueApplyMirror = (kind, cardId, changes={}) ->
  changes = extend(
    {
      comments: {create: [], update: [], delete: []},
      attachments: {add: [], delete: []}
    }
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

module.exports.queueRefetchChecklists = (cardId, options={applyMirror: false}) ->
  refetchChecklistsURL = settings.SERVICE_URL + '/debounced/refetch-checklists'
  data = {}
  data[cardId] = true
  data.options = {}
  data.options[cardId] = options
  superagent.post('http://debouncer.websitesfortrello.com/debounce/6/' + refetchChecklistsURL)
            .set('Content-Type': 'application/json')
            .send(data)
            .end()

module.exports.mirroredCommentText = (comment, sourceCardId) ->
  date = moment(comment.date).format('MMMM Do YYYY, h:mm:ssa UTC')
  text = '>' + comment.text.replace /\n/, '\n>'
  "[#{comment.author.name}](https://trello.com/#{comment.author.id}) at [#{date}](https://trello.com/c/#{sourceCardId}):\n\n#{text}"
