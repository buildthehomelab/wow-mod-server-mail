/*
 * mod-server-mail
 *
 * `.blizzmail send` mails a player items and/or gold that show up in their mailbox as coming
 * from "Blizzard Services" rather than from the GM's character. The ServerMail client addon is
 * a window for it: it talks to these commands over the core's addon command channel.
 *
 * The trick is the message type. Player mail (MAIL_NORMAL) shows the sending character's name;
 * NPC mail (MAIL_CREATURE) makes the client ask for a creature's name instead, so the module's
 * SQL adds a never-spawned creature called "Blizzard Services" and the mail is sent from it.
 * NPC mail also can't be replied to or returned, which is what a store delivery should look like.
 *
 * Released under GNU GPL v2; redistribute/modify under version 2 of the License, or (at your
 * option) any later version.
 */

#include "Chat.h"
#include "CommandScript.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "Log.h"
#include "Mail.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "StringConvert.h"
#include "StringFormat.h"
#include <algorithm>
#include <array>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

using namespace Acore::ChatCommands;

namespace
{
    struct BlizzardMailConfig
    {
        bool enabled = true;
        uint32 senderEntry = 9500000;
        uint8 stationery = MAIL_STATIONERY_GM;
        uint32 expireDays = 90;
        std::string defaultSubject;
        std::string defaultBody;
    };

    BlizzardMailConfig config;

    // Item quality colours, for the confirmation's item links.
    constexpr std::array<uint32, 8> QUALITY_COLORS =
    {
        0xff9d9d9d, 0xffffffff, 0xff1eff00, 0xff0070dd, 0xffa335ee, 0xffff8000, 0xffe6cc80, 0xffe6cc80
    };

    // The config file and the command can't hold real line breaks, so "\n" stands for one.
    std::string ExpandNewlines(std::string_view text)
    {
        std::string out;
        out.reserve(text.size());
        for (std::size_t i = 0; i < text.size(); ++i)
        {
            if (text[i] == '\\' && i + 1 < text.size() && text[i + 1] == 'n')
            {
                out += '\n';
                ++i;
            }
            else
                out += text[i];
        }
        return out;
    }

    void LoadConfig()
    {
        config.enabled        = sConfigMgr->GetOption<bool>("BlizzardMail.Enable", true);
        config.senderEntry    = sConfigMgr->GetOption<uint32>("BlizzardMail.SenderEntry", 9500000);
        config.stationery     = sConfigMgr->GetOption<uint8>("BlizzardMail.Stationery", MAIL_STATIONERY_GM);
        config.expireDays     = sConfigMgr->GetOption<uint32>("BlizzardMail.ExpireDays", 90);
        config.defaultSubject = sConfigMgr->GetOption<std::string>("BlizzardMail.DefaultSubject", "A gift for you");
        config.defaultBody    = ExpandNewlines(sConfigMgr->GetOption<std::string>("BlizzardMail.DefaultBody",
            "Greetings,\\n\\nPlease find your gift attached. Thank you for playing!\\n\\nBlizzard Services"));

        if (!config.expireDays)
            config.expireDays = 90;
    }

    std::string_view TrimLeft(std::string_view text)
    {
        while (!text.empty() && (text.front() == ' ' || text.front() == '\t'))
            text.remove_prefix(1);
        return text;
    }

    // Reads a "double quoted" string off the front of `args`. \" is a literal quote and \n a line
    // break. Returns nullopt, leaving `args` alone, if there is no quoted string there.
    std::optional<std::string> TakeQuoted(std::string_view& args)
    {
        if (args.empty() || args.front() != '"')
            return std::nullopt;

        std::string out;
        for (std::size_t i = 1; i < args.size(); ++i)
        {
            char c = args[i];
            if (c == '"')
            {
                args = TrimLeft(args.substr(i + 1));
                return out;
            }

            if (c == '\\' && i + 1 < args.size())
            {
                char next = args[i + 1];
                if (next == 'n' || next == '"' || next == '\\')
                {
                    out += next == 'n' ? '\n' : next;
                    ++i;
                    continue;
                }
            }

            out += c;
        }

        return std::nullopt; // no closing quote
    }

    // Reads the digits at the front of `text` as a number, if there are any.
    std::optional<uint32> TakeNumber(std::string_view& text)
    {
        std::size_t len = 0;
        while (len < text.size() && text[len] >= '0' && text[len] <= '9')
            ++len;

        if (!len)
            return std::nullopt;

        std::optional<uint32> value = Acore::StringTo<uint32>(text.substr(0, len));
        text.remove_prefix(len);
        return value;
    }

    // "1g50s" -> 15000 copper. The core's MoneyStringToMoney wants each unit as its own word.
    std::optional<uint64> ParseMoney(std::string_view token)
    {
        uint64 total = 0;
        while (!token.empty())
        {
            std::optional<uint32> amount = TakeNumber(token);
            if (!amount || token.empty() || *amount > MAX_MONEY_AMOUNT)
                return std::nullopt;

            switch (token.front())
            {
                case 'g': total += uint64(*amount) * GOLD; break;
                case 's': total += uint64(*amount) * SILVER; break;
                case 'c': total += *amount; break;
                default: return std::nullopt;
            }
            token.remove_prefix(1);
        }
        return total;
    }

    struct Attachments
    {
        std::vector<std::pair<uint32 /*entry*/, uint32 /*count*/>> items; // one entry per stack
        uint32 money = 0;
    };

    bool ParseAttachments(ChatHandler* handler, std::string_view args, Attachments& out)
    {
        uint64 money = 0;

        for (args = TrimLeft(args); !args.empty(); args = TrimLeft(args))
        {
            uint32 entry = 0;
            uint32 count = 1;

            if (args.front() == '|')
            {
                // Shift-clicked link: |cffa335ee|Hitem:49284:0:...|h[Name With Spaces]|h|r
                std::size_t linkStart = args.find("|Hitem:");
                std::size_t linkEnd = linkStart == std::string_view::npos ? linkStart : args.find("]|h", linkStart);
                if (linkEnd == std::string_view::npos)
                {
                    handler->SendErrorMessage("Couldn't read that link, only item links can be attached.");
                    return false;
                }

                std::string_view idText = args.substr(linkStart + 7);
                std::optional<uint32> id = TakeNumber(idText);
                if (!id)
                {
                    handler->SendErrorMessage("Couldn't read the item id out of that link.");
                    return false;
                }

                entry = *id;
                args.remove_prefix(linkEnd + 3);
                if (args.starts_with("|r"))
                    args.remove_prefix(2);
            }
            else
            {
                std::string_view token = args.substr(0, args.find_first_of(" \t"));

                // Gold: 100g, 50s, 25c, 1g50s
                if (token.find_first_of("gsc") != std::string_view::npos)
                {
                    std::optional<uint64> amount = ParseMoney(token);
                    if (!amount || !*amount)
                    {
                        handler->SendErrorMessage("'{}' isn't an amount of gold (try 100g, 50s or 1g50s).", token);
                        return false;
                    }

                    money += *amount;
                    args.remove_prefix(token.size());
                    continue;
                }

                std::optional<uint32> id = TakeNumber(args);
                if (!id)
                {
                    handler->SendErrorMessage("'{}' isn't an item id, item link or amount of gold.", token);
                    return false;
                }

                entry = *id;
            }

            // Optional count straight after the item: 33447:20 or 33447x20
            if (!args.empty() && (args.front() == ':' || args.front() == 'x'))
            {
                args.remove_prefix(1);
                std::optional<uint32> parsed = TakeNumber(args);
                if (!parsed)
                {
                    handler->SendErrorMessage("Item {}: expected a count after ':' or 'x'.", entry);
                    return false;
                }
                count = *parsed;
            }

            if (!args.empty() && args.front() != ' ' && args.front() != '\t')
            {
                handler->SendErrorMessage("Couldn't read '{}' (items look like 49284, 33447:20 or a link).",
                    args.substr(0, args.find_first_of(" \t")));
                return false;
            }

            ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
            if (!proto)
            {
                handler->SendErrorMessage(LANG_COMMAND_ITEMIDINVALID, entry);
                return false;
            }

            if (!count || (proto->MaxCount > 0 && count > uint32(proto->MaxCount)))
            {
                handler->SendErrorMessage(LANG_COMMAND_INVALID_ITEM_COUNT, count, entry);
                return false;
            }

            uint32 stackSize = std::max<uint32>(1, proto->GetMaxStackSize());
            while (count)
            {
                uint32 stack = std::min(count, stackSize);
                out.items.emplace_back(entry, stack);
                count -= stack;
            }

            if (out.items.size() > MAX_MAIL_ITEMS)
            {
                handler->SendErrorMessage(LANG_COMMAND_MAIL_ITEMS_LIMIT, MAX_MAIL_ITEMS);
                return false;
            }
        }

        if (money > MAX_MONEY_AMOUNT)
        {
            handler->SendErrorMessage("That's more gold than a character can hold.");
            return false;
        }

        out.money = uint32(money);
        return true;
    }

    std::string DescribeItem(ChatHandler* handler, uint32 entry, uint32 count)
    {
        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
        std::string text;

        if (handler->GetSession())
            text = Acore::StringFormat("|c{:08x}|Hitem:{}:0:0:0:0:0:0:0:0|h[{}]|h|r",
                QUALITY_COLORS[std::min<uint32>(proto->Quality, QUALITY_COLORS.size() - 1)], entry, proto->Name1);
        else
            text = Acore::StringFormat("[{}] ({})", proto->Name1, entry);

        if (count > 1)
            text += Acore::StringFormat(" x{}", count);

        return text;
    }

    // A chat or addon message is at most 255 characters, too short for a real letter, so a
    // subject and body can be staged first with `.blizzmail subject` / `.blizzmail body` and are
    // used by the next `.blizzmail send`. Kept per account (0 = console).
    struct Draft
    {
        std::optional<std::string> subject;
        std::optional<std::string> body;
    };

    constexpr std::size_t MAX_SUBJECT_LENGTH = 64;   // what the client's own mail window allows
    constexpr std::size_t MAX_BODY_LENGTH = 4000;

    std::mutex draftsLock;
    std::unordered_map<uint32, Draft> drafts;

    uint32 DraftKey(ChatHandler* handler)
    {
        return handler->GetSession() ? handler->GetSession()->GetAccountId() : 0;
    }

    // Text argument: a "quoted string" (keeps leading/trailing spaces, which the addon relies on
    // when it splits a body into pieces) or the rest of the line as typed. \n is a line break
    // either way.
    std::optional<std::string> ReadText(std::string_view args)
    {
        args = TrimLeft(args);
        if (!args.empty() && args.front() == '"')
            return TakeQuoted(args);

        while (!args.empty() && (args.back() == ' ' || args.back() == '\t'))
            args.remove_suffix(1);

        return ExpandNewlines(args);
    }
}

class BlizzardMailCommandScript : public CommandScript
{
public:
    BlizzardMailCommandScript() : CommandScript("BlizzardMailCommandScript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable blizzMailTable =
        {
            { "send",    HandleSendCommand,    SEC_GAMEMASTER, Console::Yes },
            { "subject", HandleSubjectCommand, SEC_GAMEMASTER, Console::Yes },
            { "body",    HandleBodyCommand,    SEC_GAMEMASTER, Console::Yes },
            { "clear",   HandleClearCommand,   SEC_GAMEMASTER, Console::Yes },
        };

        static ChatCommandTable commandTable =
        {
            { "blizzmail", blizzMailTable },
        };

        return commandTable;
    }

    // .blizzmail subject <text> -- sets the staged subject
    static bool HandleSubjectCommand(ChatHandler* handler, Tail rest)
    {
        std::optional<std::string> text = ReadText(rest);
        if (!text || text->empty())
        {
            handler->SendErrorMessage("Usage: .blizzmail subject <text>");
            return false;
        }

        if (text->size() > MAX_SUBJECT_LENGTH)
        {
            handler->SendErrorMessage("The subject can be at most {} characters.", MAX_SUBJECT_LENGTH);
            return false;
        }

        std::lock_guard<std::mutex> guard(draftsLock);
        drafts[DraftKey(handler)].subject = std::move(*text);
        return true;
    }

    // .blizzmail body <text> -- appends to the staged body
    static bool HandleBodyCommand(ChatHandler* handler, Tail rest)
    {
        std::optional<std::string> text = ReadText(rest);
        if (!text || text->empty())
        {
            handler->SendErrorMessage("Usage: .blizzmail body <text>  (adds to the letter; \\n starts a new line)");
            return false;
        }

        std::lock_guard<std::mutex> guard(draftsLock);
        std::optional<std::string>& body = drafts[DraftKey(handler)].body;
        std::string combined = body.value_or("") + *text;
        if (combined.size() > MAX_BODY_LENGTH)
        {
            handler->SendErrorMessage("The letter can be at most {} characters.", MAX_BODY_LENGTH);
            return false;
        }

        body = std::move(combined);
        return true;
    }

    // .blizzmail clear -- forgets the staged subject and body
    static bool HandleClearCommand(ChatHandler* handler)
    {
        std::lock_guard<std::mutex> guard(draftsLock);
        drafts.erase(DraftKey(handler));
        return true;
    }

    // .blizzmail send <player> ["subject" ["body"]] [item ...] [gold]
    static bool HandleSendCommand(ChatHandler* handler, PlayerIdentifier target, Tail rest)
    {
        if (!config.enabled)
        {
            handler->SendErrorMessage("mod-server-mail is disabled (BlizzardMail.Enable = 0).");
            return false;
        }

        // Without the creature row the client would show the sender as "Unknown".
        if (!sObjectMgr->GetCreatureTemplate(config.senderEntry))
        {
            handler->SendErrorMessage("Sender creature {} doesn't exist. Apply the mod-server-mail SQL "
                "or fix BlizzardMail.SenderEntry.", config.senderEntry);
            return false;
        }

        // Subject and body: typed in this command, else staged earlier, else the config defaults.
        std::string subject = config.defaultSubject;
        std::string body = config.defaultBody;
        {
            std::lock_guard<std::mutex> guard(draftsLock);
            auto itr = drafts.find(DraftKey(handler));
            if (itr != drafts.end())
            {
                subject = itr->second.subject.value_or(subject);
                body = itr->second.body.value_or(body);
            }
        }

        std::string_view args = TrimLeft(rest);
        if (std::optional<std::string> quoted = TakeQuoted(args))
        {
            subject = *quoted;
            if (std::optional<std::string> quotedBody = TakeQuoted(args))
                body = *quotedBody;
        }
        else if (!args.empty() && args.front() == '"')
        {
            handler->SendErrorMessage("The subject is missing its closing quote.");
            return false;
        }

        if (subject.empty() || subject.size() > MAX_SUBJECT_LENGTH)
        {
            handler->SendErrorMessage("The subject must be 1 to {} characters.", MAX_SUBJECT_LENGTH);
            return false;
        }

        Attachments attachments;
        if (!ParseAttachments(handler, args, attachments))
            return false;

        Player* receiver = target.GetConnectedPlayer();
        ObjectGuid::LowType receiverLow = target.GetGUID().GetCounter();

        // Create everything first so a failure part-way doesn't send half a gift.
        std::vector<Item*> items;
        for (auto const& [entry, count] : attachments.items)
        {
            Item* item = Item::CreateItem(entry, count, receiver);
            if (!item)
            {
                for (Item* created : items)
                    delete created;

                handler->SendErrorMessage("Couldn't create item {}; nothing was sent.", entry);
                return false;
            }

            item->SetOwnerGUID(target.GetGUID());
            items.push_back(item);
        }

        MailDraft draft(subject, body);
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();

        for (Item* item : items)
        {
            item->SaveToDB(trans); // must be in the DB before the mail references it
            draft.AddItem(item);
        }

        if (attachments.money)
            draft.AddMoney(attachments.money);

        MailSender sender(MAIL_CREATURE, config.senderEntry, MailStationery(config.stationery));
        draft.SendMailTo(trans, MailReceiver(receiver, receiverLow), sender, MAIL_CHECK_MASK_NONE, 0, config.expireDays);
        CharacterDatabase.CommitTransaction(trans);

        {
            std::lock_guard<std::mutex> guard(draftsLock);
            drafts.erase(DraftKey(handler));
        }

        // Confirmation, with repeated stacks of the same item folded back together.
        std::string contents;
        for (std::size_t i = 0; i < attachments.items.size();)
        {
            uint32 entry = attachments.items[i].first;
            uint32 total = 0;
            for (; i < attachments.items.size() && attachments.items[i].first == entry; ++i)
                total += attachments.items[i].second;

            contents += (contents.empty() ? "" : ", ") + DescribeItem(handler, entry, total);
        }

        if (attachments.money)
            contents += (contents.empty() ? "" : ", ") + Acore::StringFormat("{}g {}s {}c",
                attachments.money / GOLD, (attachments.money % GOLD) / SILVER, attachments.money % SILVER);

        if (contents.empty())
            contents = "letter only";

        handler->PSendSysMessage("Blizzard mail sent to {} ({}): {}", handler->playerLink(target.GetName()),
            receiver ? "online" : "offline", contents);

        LOG_INFO("module", "mod-server-mail: {} mailed {} (guid {}) \"{}\": {}",
            handler->GetSession() ? handler->GetSession()->GetPlayerName() : "Console",
            target.GetName(), receiverLow, subject, contents);

        return true;
    }
};

class BlizzardMailWorldScript : public WorldScript
{
public:
    BlizzardMailWorldScript() : WorldScript("BlizzardMailWorldScript",
        { WORLDHOOK_ON_AFTER_CONFIG_LOAD, WORLDHOOK_ON_STARTUP }) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        LoadConfig();
    }

    void OnStartup() override
    {
        if (config.enabled && !sObjectMgr->GetCreatureTemplate(config.senderEntry))
            LOG_ERROR("module", "mod-server-mail: sender creature {} (BlizzardMail.SenderEntry) is missing from "
                "creature_template; .blizzmail will refuse to send until the module SQL is applied.", config.senderEntry);
    }
};

void AddBlizzardMailScripts()
{
    new BlizzardMailCommandScript();
    new BlizzardMailWorldScript();
}
