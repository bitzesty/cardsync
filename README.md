Hello, I am a card mirror, which means I can update the content of one Trello card to reflect changes made on other card.

You can use me to create 2 or more _twin cards_ between two boards. So whenever someone updates the **name**, **description**, **due date**, **cover image**, **checklists** and **checkitem** states, add or remove **attachments** or add, delete or edit **comments** in some card, I will perform the same changes in the mirrored cards.

## Quick demo

Go to [this board](https://trello.com/b/d0ZabOQ7/mirror-testing) and post comments anywhere. Since you're not a member of the board you'll only be able to watch me mirroring your comments, but that is better than nothing.

## How to Mirror:

1. Add me to your Boards
1. Find the cards you want to mirror (or create them if they do not exist)
1. Make sure the cards have the same **name**
1. Add me as a member to each of the cards 
1. Wait some seconds while I perform the initial mirror process

The first card to where you added me will be the "master" of the initial mirror. After that, there's no concept of "master" anymore and everything you modify in any card will be synced to all other cards.

## What I will not do

I will not mess with visibility permissions, adding and removing members, powerups, votes and I will not mirror labels or stickers. These things are too Board-specific to be worth the trouble.

Also, I will not mirror comments and attachments made before I am added to the card.

### Observation

If you're changing checklists at one card and at the same time watching a mirrored card reflect the changes, it will probably look like everything is wrong and messy, checkitems being marked wrongly, or added to the wrong checklists etc., but it isn't really, it is just Trello UI syncing that is bad. Close the card, wait a little, open it again and everything will be ok.

### More about me

I am a creation of the people at
http://websitesfortrello.com/.

If you don't trust me, you can make a clone of me by executing the code at http://github.com/fiatjaf/trellomirror. You will only need a MongoDB instance.

### Disclaimer

I'm doing the best I can here but sometimes bad things happen and I may experiment a bug during the sync process that will cause me to delete an attachment I shouldn't delete, or maybe a checklist. If that happens, you agree to not put the blame on me.
