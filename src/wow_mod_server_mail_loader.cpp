/*
 * wow-mod-server-mail loader.
 *
 * AzerothCore looks up a loader symbol derived from the module's folder name: for folder
 * "wow-mod-server-mail" that symbol is exactly "Addwow_mod_server_mailScripts". If you clone the
 * repo under a different folder name, rename this function to match.
 *
 * Released under GNU GPL v2 or (at your option) any later version.
 */

void AddBlizzardMailScripts();

void Addwow_mod_server_mailScripts()
{
    AddBlizzardMailScripts();
}
