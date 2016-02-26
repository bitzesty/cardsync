dedupe = require 'dedupe'

regexmulti = /https?:\/\/trello.com\/c\/([\d\w]+)/g
regexsingle = /https?:\/\/trello.com\/c\/([\d\w]+)/

module.exports = (text) ->
  matches = text.match(regexmulti) or []
  dedupe matches.map (match) ->
    regexsingle.exec(match)[1]
