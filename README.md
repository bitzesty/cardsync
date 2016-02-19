# Running your own [@cardsync](https://trello.com/cardsync)

## What you will need

1. a Neo4j database
2. Node.js and npm
3. an email address

## Steps

1. Go to https://trello.com/signup and create a new account, this will be your bot.
2. Logged to that account, visit https://trello.com/app-key to get your API key
3. Replace `https://trello.com/1/authorize?key=REPLACE-WITH-YOUR-KEY&scope=read%2Cwrite&name=My+own+Trello+sync+bot+app&expiration=never&response_type=token` with your API key and visit it to get a token.
4. `curl 'https://api.trello.com/1/members/<your bot username>?fields=id'` to get the bot id.
5. Clone this repository: `git clone https://github.com/websitesfortrello/cardsync`
6. `cd cardsync && npm install`
7. Set up your environment variables (maybe you're using an `.env` file, or a container, a Virtual environment, a PaaS, or I don't know, but you have to set these:
  * `NEO4J_URL` (the URL -- with basic auth credentials -- to your Neo4j database REST endpoint)
  * `RAYGUN_APIKEY` (for error tracking with [Raygun](https://raygun.io/), set to anything if you don't have one)
  * `SERVICE_URL` (the root URL of the app, without the trailing slash -- like `https://trellosyncbot.mycompany.com`)
  * `TRELLO_API_KEY`
  * `TRELLO_API_SECRET`
  * `TRELLO_BOT_ID`
  * `TRELLO_BOT_TOKEN`
8. `coffee index.coffee` to start the app (maybe it's `./node_modules/.bin/coffee` depending on your setup).
9. On another shell, set a webhook to monitor the bot account pointing to your app's address: `curl -X PUT https://api.trello.com/1/webhooks -d '{"description": "bot main webhook", "callbackURL": "$SERVICE_URL/webhooks/trello-bot", "idModel": "$TRELLO_BOT_ID"}'` (ensure these variables are being replaced correctly according to the ones you've set up before, or replace them manually in your call.)

That's it. Your bot is running, you can start adding it to some cards.

## Important

The webhook endpoint, the `SERVICE_URL` up there, is forever. You can't change it. After you start using your bot it will create a lot of webhooks pointing to this endpoint and it will be very complicated to change them all on Trello's side if you somehow decide to change your endpoint address, so don't.
