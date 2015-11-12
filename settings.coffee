for k, v of process.env
    module.exports[k] = v

module.exports.SERVICE_NAME  = process.env.SERVICE_NAME or 'Card mirroring for Trello'
module.exports.SERVICE_URL   = process.env.SERVICE_URL or 'http://mirror.websitesfortrello.com'
module.exports.CONTACT_EMAIL = process.env.CONTACT_EMAIL or 'team@websitesfortrello.com'

module.exports.NEO4J_URL = process.env.NEO4J_URL or process.env.GRAPHSTORY_URL or process.env.GRAPHENEDB_URL
