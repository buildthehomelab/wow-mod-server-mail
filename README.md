# Blizzard Mail

Lets GMs on an [AzerothCore](https://www.azerothcore.org/) (WotLK 3.3.5a) server mail items and
gold to players from **Blizzard Services** instead of from their own character, the way pet store
pets, store mounts and TCG loot used to show up.

It comes in two parts:

- **The ServerMail addon** (`addon/ServerMail`): a window for GMs. Type a name, drag in items
  or pick a rare mount or pet from the menu, write a letter, press Send.
- **The mod-server-mail server module** (everything else here): does the actual sending. A WoW
  addon can only send mail as the character you're logged in as, and the name players see on a
  mail comes from the server, so the "Blizzard Services" part has to happen server-side.

The player gets a letter on the Blizzard stationery, from "Blizzard Services", with the items
attached. The GM's name appears nowhere. Players can't reply to it or return it, the same as any
other NPC mail.

## Who can use it

Only GMs. The server checks this on every command: the account needs GM level 2 or higher
(`account_access`). A player who installs the addon gets "There is no such command" back and
nothing is sent. The addon talks to the server over AzerothCore's hidden addon channel, not normal
chat, so the attempt doesn't show up in anyone's chat either.

## The addon

Open it with `/bmail` (or `/blizzmail`). `/bmail Arthas` opens it with the name filled in.

- **To**: the character's name, online or offline. **Target** fills in your target's name, or your
  own if no player is targeted, which is handy for a test.
- **Subject** and **Letter**: optional. Leave them empty and the server's defaults from the config
  are used. Letters can be up to 1000 characters, with line breaks.
- **Attachments**: up to 12. Add items by:
  - dragging them from your bags onto a slot (your own copy isn't used up),
  - typing an id, `id:count` or `idxcount` into **Add item** and pressing Enter,
  - clicking in **Add item** and shift-clicking an item link from anywhere,
  - picking one from **Mounts & Pets** (promo, TCG and rare-drop mounts and pets).
  Left-click an attachment to change its count, right-click to remove it. Hover it to see what
  the item really is.
- **Gold**: gold, silver and copper.

**Send** asks you to confirm, then shows the server's reply at the bottom of the window and in
chat. After a successful send the attachments and gold are cleared (the letter stays, so you can
send the same gift to the next person by changing the name and adding the items again).

The Mounts & Pets list is in `Presets.lua`. Edit it to add your own favorites. The names there
are only labels; hover an attachment to see the item the server has under that id.

## Commands

The addon uses these. You can also type them in chat or on the worldserver console.

```
.blizzmail send <player> [item ...] [gold]
.blizzmail send <player> "subject" ["body"] [item ...] [gold]
.blizzmail subject <text>     set the subject for the next send
.blizzmail body <text>        add text to the letter for the next send
.blizzmail clear              forget the staged subject and letter
```

| Part | Examples | Notes |
|------|----------|-------|
| player | `Arthas` | Online or offline. Always typed out, so a gift can't go to whoever you have targeted by mistake. |
| subject / body | `"Happy birthday!"` `"Line one\nLine two"` | Optional. Order of preference: typed in `send`, then staged with `subject`/`body`, then the config defaults. `\n` is a line break, `\"` a quote. |
| item | `49284` `33447:20` `33447x20` or a shift-clicked link | Up to 12 stacks per mail. Big counts are split into stacks. Unique items (most mounts and pets) can only be sent once per mail. |
| gold | `100g` `50s` `1g50s` `150000c` | Can be combined with items. |

`subject` and `body` exist because a chat or addon message can only be 255 characters long, which
isn't enough for a letter. They're kept per GM account until the next successful `send` or
`clear`.

Examples:

```
.blizzmail send Jaina 49693
.blizzmail send Jaina "Your Celestial Steed has arrived!" 54811
.blizzmail send Thrall "Welcome back" "Thanks for coming back!\n\nHere's something for the road." 49665 500g
```

(49693 Lil' K.T., 54811 Celestial Steed, 49665 Pandaren Monk.)

Every send is logged to the `module` logger with who sent what to whom.

## Installation

### Server

1. Clone it into your AzerothCore `modules/` directory as `mod-server-mail` (without the
   repo's `wow-` prefix):

   ```bash
   cd modules
   git clone https://github.com/buildthehomelab/wow-mod-server-mail.git mod-server-mail
   ```

   The folder name matters: AzerothCore finds the module's loader (`Addmod_server_mailScripts`)
   from it. A folder with any other name, including the default `wow-mod-server-mail`, builds
   but never loads unless you rename that function in `src/mod_server_mail_loader.cpp` to match.
2. Re-run CMake and rebuild the worldserver.
3. The SQL in `data/sql/db-world/updates/` is applied by the DB updater on the next start. If
   your setup doesn't auto-apply module SQL, run it against `acore_world` by hand. It adds one
   creature template (entry 9500000, "Blizzard Services") that is never spawned.
4. Copy `conf/mod_server_mail.conf.dist` to `mod_server_mail.conf` next to your other module
   configs and adjust it if needed.

If the SQL is missing, the worldserver logs an error on startup and `.blizzmail send` refuses to
send rather than delivering mail from "Unknown".

### Addon

Copy `addon/ServerMail` into `Interface/AddOns/` in the GM's WoW 3.3.5a client folder, so you
end up with `Interface/AddOns/ServerMail/ServerMail.toc`. Players don't need it. In game it's
listed as "Blizzard Mail".

Don't rename the folder to anything starting with "Blizzard". The client treats those folders as
tampered copies of its own built-in addons and renames them to `.old` at startup. (An older
version of this addon was called `BlizzardMail` and got hit by exactly that: delete any
`BlizzardMail.old` folder.)

## Configuration

| Key | Default | |
|-----|---------|---|
| `BlizzardMail.Enable` | `1` | Master switch. |
| `BlizzardMail.SenderEntry` | `9500000` | Creature the mail comes from. Change it only if 9500000 clashes with another module, and change the SQL to match. |
| `BlizzardMail.Stationery` | `61` | Letter background: 61 Blizzard/GM, 41 plain, 64 Love is in the Air, 65 Winter Veil, 67 Children's Week. |
| `BlizzardMail.ExpireDays` | `90` | Days before an unopened mail expires. NPC mail is deleted when it expires, not returned, so the items are lost. |
| `BlizzardMail.DefaultSubject` | `A gift for you` | Used when no subject is given. |
| `BlizzardMail.DefaultBody` | (short thank-you letter) | Used when no letter is given. `\n` is a line break. |

### Renaming the sender

The sender's name is the creature's name, so change it in the database:

```sql
UPDATE creature_template SET name = 'The Blizzard Store' WHERE entry = 9500000;
```

Restart the worldserver afterwards. Clients cache creature names, so players who already saw the
old name keep seeing it until they delete their `Cache/WDB` folder.

## How it works

Mail in 3.3.5 has a message type. Player mail (`MAIL_NORMAL`) names the character who sent it.
NPC mail (`MAIL_CREATURE`), the kind quest givers and battlemasters send, carries a creature
entry instead, and the client asks the server for that creature's name to fill in the From line.
The module adds a creature called "Blizzard Services" and sends NPC mail from it with the GM
stationery. The core's `.send items` can't do this: it always sends player mail, from the GM's
character (or from the recipient themself when run from the console).

The items are created and saved in one transaction with the mail, so a player who is online sees
it in their mailbox straight away, and one who is offline finds it on their next login.

The addon sends its commands with `SendAddonMessage("AzerothCore", ...)` whispered to yourself,
which the core runs as GM commands and answers the same way (acknowledged / output / OK /
failed). It sends them one at a time and stops at the first failure: `clear`, then `subject`,
then the letter in pieces of up to 90 bytes, then `send`.
