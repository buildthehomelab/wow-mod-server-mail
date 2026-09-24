-- wow-mod-server-mail: the "creature" the mail comes from.
--
-- The 3.3.5 client shows the sender of an NPC mail (message type MAIL_CREATURE) by asking the
-- server for that creature's name, so the name below is exactly what players see in the From
-- line of their mailbox. It is never spawned anywhere.
--
-- The entry must match BlizzardMail.SenderEntry in mod_blizzard_mail.conf.
--
-- To rename the sender, change `name` here (or in the DB) and restart the worldserver. Clients
-- that already saw the old name keep it in their cache until they delete Cache/WDB.
--
-- Idempotent: safe to run again.

SET @ENTRY := 9500000;

DELETE FROM `creature_template` WHERE `entry` = @ENTRY;
INSERT INTO `creature_template` (`entry`, `name`, `subname`, `minlevel`, `maxlevel`, `faction`, `unit_class`, `type`, `unit_flags`, `flags_extra`, `VerifiedBuild`) VALUES
(@ENTRY, 'Blizzard Services', NULL, 80, 80, 35, 1, 7, 33554434, 128, 0);

-- Invisible stalker model; the core wants every creature_template to have one.
DELETE FROM `creature_template_model` WHERE `CreatureID` = @ENTRY;
INSERT INTO `creature_template_model` (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`, `VerifiedBuild`) VALUES
(@ENTRY, 0, 11686, 1, 1, 0);
