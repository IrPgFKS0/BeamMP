#!/usr/bin/env python3
"""Inject (or re-inject) the LAN fork's settings into the Vue options layout.

The fork ships a VFS override of the game's schema-driven options layout at
ui/ui-vue/src/modules/options/runtime/layout.json (game layout + upstream 4.22's
"multiplayer" category). This script appends the LAN fork's own settings to that
multiplayer category. It is IDEMPOTENT: every item it owns carries
"version": "LAN" and gets stripped before re-inserting, so it can be re-run
after refreshing the base layout from a new game patch + upstream.

Re-sync procedure on a BeamNG game update (and/or upstream BeamMP sync):
  1. copy the game's new layout.json over ours
  2. re-insert upstream's multiplayer category (diff upstream/development's copy) --
     this is what carries NEW upstream settings into the LAN branch
  3. run this script: it re-appends the LAN items AND re-applies the LAN prunes of
     upstream items that are wrong for a LAN build (see LAN_PRUNE_* below)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT = os.path.join(HERE, "..", "ui", "ui-vue", "src", "modules", "options", "runtime", "layout.json")

SEARCH_CB = ["label", "caption", "tooltip", "setting"]


def heading(label):
    return {
        "version": "LAN", "label": label, "tooltip": "", "interactive": False,
        "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "heading", "component": "OptionsHeading", "icon": "_empty",
        "variant": "h4", "search": ["label"],
    }


def checkbox(setting, label, tooltip):
    return {
        "version": "LAN", "label": label, "tooltip": tooltip, "setting": setting,
        "interactive": True, "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "checkbox", "component": "OptionsCheckbox", "separateLabel": True,
        "lua": "", "luaOff": "", "valueOn": True, "valueOff": False, "search": SEARCH_CB,
    }


def dropdown(setting, label, tooltip, options):
    return {
        "version": "LAN", "label": label, "tooltip": tooltip, "setting": setting,
        "interactive": True, "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "options", "component": "BngSmartSelect", "separateLabel": True,
        "optionsSource": "", "options": [{"label": l, "value": v} for l, v in options],
        "lua": "", "basic_interaction": False,
        "search": SEARCH_CB + ["optionsSource", "options"],
    }


def slider(setting, label, tooltip, minv, maxv, step, unit):
    return {
        "version": "LAN", "label": label, "tooltip": tooltip, "setting": setting,
        "interactive": True, "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "slider", "component": "BngSlider", "separateLabel": True,
        "min": float(minv), "max": float(maxv), "step": float(step), "compact": False,
        "valueMultiplier": 1, "unit": unit, "lua": "", "basic_interaction": False,
        "search": SEARCH_CB,
    }


def text_input(setting, label, tooltip):
    return {
        "version": "LAN", "label": label, "tooltip": tooltip, "setting": setting,
        "interactive": True, "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "input", "component": "BngInput", "separateLabel": True,
        "inputType": "text", "unit": "", "search": SEARCH_CB + ["settingValue"],
    }


def button(label, caption, lua, tooltip):
    return {
        "version": "LAN", "label": label, "tooltip": tooltip, "setting": "",
        "interactive": True, "condition_always_off": False, "condition_not_shipping": False,
        "condition_simplemenu": "", "condition_visible": "", "condition_enabled": "",
        "itemType": "button", "component": "BngButton", "variant": "secondary",
        "separateLabel": True, "innerCaption": True, "lua": lua, "caption": caption,
        "search": SEARCH_CB + ["settingValue"],
    }


# Tooltips carried over verbatim from the fork's 0.38 Angular options page
# (ui/modules/options/multiplayer.partial.html, deleted in p13h63).
LAN_ITEMS = [
    heading("LAN fork — gameplay"),
    dropdown("autoSpawnMode", "Auto-spawn car on join (LAN)",
             "Automatically spawn a car when you join a server, so you don't have to pick one each time. \"Last used\" remembers the car you spawned last (across sessions). Set your preferred default via the vehicle menu's \"Set as default\". Default: Off.",
             [("Off", 0), ("Default car", 1), ("Last used car", 2)]),
    checkbox("allowEnvSync", "Allow environment sync from other players (LAN)",
             "When another player pushes their environment (/syncenv or the pause-menu Environment button), adopt it -- time of day, weather, wind and so on, blended over 2 seconds with a toast naming the sender. Turn OFF to ignore incoming pushes (you'll get a short note instead). Your own outgoing pushes are unaffected. Default: on."),
    checkbox("allowRemoteAIChase", "Allow other players' AI cars to chase me (LAN)",
             "Consent toggle. OFF (default): another player's AI/weapon-mod pursuit cars will NOT lock onto you, even when you're their nearest target. ON: you volunteer as a target, so their \"Chase\" cars can come after you when you're nearest. This does NOT affect your OWN cars -- you can always spawn AI/weapon cars and pick \"Chase\" in BeamNG's AI radial; they'll hunt yourself plus any remote player who has turned this on (and \"Stop\"/\"Park\" disengages + stops their guns)."),
    slider("defaultCameraDistance", "Default camera distance (LAN)",
           "How far the orbit camera sits from the car, applied whenever you switch into a vehicle, change camera mode, or reset the vehicle -- this is what the zoom keys actually change on the orbit camera, so it works zoomed OUT as well as in. 0 = off (each vehicle's own default, typically ~5 m). The zoom keys still adjust live afterward. Default: 0.",
           0, 30, 0.5, "m"),
    checkbox("remoteFullProjectiles", "Full weapon projectiles on remote cars (LAN)",
             "A weapon car another player is DRIVING already fires full physics projectiles on your screen. This also makes SPAWNED / AI weapon cars fire full physics projectiles instead of just a muzzle flash + sound -- accurate, but CPU-heavy when lots of guns fire at once. Enable only if every machine has CPU headroom. Default: off."),
    heading("LAN fork — position sync & performance"),
    checkbox("physicsRateSend", "EXPERIMENTAL: Physics-rate position send (LAN)",
             "Sends your own car's position from the physics step (at the Position send rate below) instead of once per render frame, so a low-FPS machine still emits fresh data to others. Helps remote-car accuracy when your FPS is below that rate; slightly more outbound traffic. On by default for LAN -- toggle off here if needed."),
    dropdown("physRateSendHz", "Position send rate (LAN)",
             "How often your car broadcasts its position (when Physics-rate send is on). The server relays every player's stream through one path that caps near ~150 packets/sec total, so ~60 Hz is the practical ceiling with 2 players (less with more) -- 100 Hz oversubscribes it and was removed. The remote predictor interpolates between updates, so 30 Hz already looks smooth; 10 Hz is stock BeamMP. Applies live; raise it only if cars look choppy AND no drift creeps in. Default: 30 Hz.",
             [("60 Hz (2-player max)", 60), ("30 Hz (LAN default)", 30), ("10 Hz (stock BeamMP)", 10)]),
    checkbox("mailboxApplyPos", "EXPERIMENTAL: Mailbox position apply (LAN)",
             "Delivers incoming positions from the game engine to each vehicle via the engine mailbox instead of compiling a Lua command per packet -- lower CPU/GC on the receive side. On by default for LAN (A/B verified ~25-40% cheaper apply); toggle off here if needed."),
    checkbox("optimizeMapMarkers", "Optimize map markers (LAN)",
             "Disables BeamNG's per-frame mission/POI marker processing while in a multiplayer session -- a known FPS sink that's useless for LAN driving (you can't start singleplayer missions in MP anyway). Restored automatically when you leave. Applied on join, so toggle it then rejoin to compare. Leave on unless you specifically want vanilla freeroam markers. Default: on."),
    checkbox("directVehicleSocket", "EXPERIMENTAL: Direct vehicle socket (LAN)",
             "Your own vehicles send position + driver inputs straight to the launcher over a dedicated UDP socket, bypassing the per-vehicle Lua queue through the game-engine VM -- the send-side bottleneck as vehicle counts climb. Safe to enable anywhere: the mod only trusts the socket after the launcher acknowledges it (p13h34+ combined/launcher build), and automatically stays on the normal path otherwise. Verify with the position profiler (\"GE sendVehiclePosRot\" drops toward zero when active). Default: off."),
    heading("LAN fork — diagnostics & debug"),
    checkbox("showSyncStats", "DEBUG: Show sync stats overlay (LAN)",
             "Tiny on-screen overlay showing the number of synced (remote) vehicles and live network packet/byte rates in and out. Handy for spotting sync load while testing. Default: off."),
    checkbox("applyStallDiag", "DIAGNOSTIC: Log position apply-stalls (LAN)",
             "When a remote vehicle's ghost freezes (stops applying received positions), write one line to the log naming the cause -- packets not reaching the vehicle, rejected as out-of-order (a sender clock reset), the sim-speed-scaled timer racing past the timeout, or packets genuinely stopped. After a freeze use /savelogs and grep \"posApplyStall\". Off = zero overhead. Applies live (no rejoin needed)."),
    checkbox("profilePosSync", "DEBUG: Profile position sync (LAN)",
             "Logs avg/max/rate timing of the position hot path (applyPos on GE; setVehiclePosRot/updateGFX on VE) to beamng.log every ~5s. For performance debugging -- grep the log for \"posProf\". Turning this OFF auto-zips the logs. Default: off."),
    checkbox("logSyncStats", "DEBUG: Log sync health to file",
             "Writes one sync-health line (synced vehicles, ghost drift + self-heals, in/out packet & KB rates, applied/s, FPS) to beamng.log every ~15s, even with the on-screen overlay hidden -- so a /savelogs after an intermittent drift episode captures what happened over time. Same toggle as the /synclog chat command. Default: off."),
    text_input("profLogFolder", "DEBUG: Log-bundle folder",
               "Folder name (under your BeamNG user folder) where the zipped log bundle is written. The game can only write inside the user folder, so this is a subfolder there; the success toast shows the full real path so you know exactly where to grab it. Default: BeamMP_logs."),
    button("Save all logs (zip)", "Save all logs (zip)",
           "if MPConfig and MPConfig.saveLogs then MPConfig.saveLogs() end",
           "Same as the in-game /savelogs command: bundles BeamNG + BeamMP + launcher logs (and the server log/state if the server runs on this PC) into one zip in your BeamMP Launcher folder. Also writes a local beamng.log zip in the folder above as a fallback."),
]


# Upstream items that are WRONG for a LAN build (same trims the fork's 0.38 options
# page carried):
#  - refreshIngame: DANGEROUS on LAN. It makes an in-session server-list refresh send
#    the 'B' request, and the launcher's 'B' handler NetReset/Terminates the session
#    (stock back-to-server-list semantics). There is also no public list to refresh.
LAN_PRUNE_SETTINGS = {"refreshIngame"}
#  - playerlistLeftclick "Open player profile" (value 2): opens the online BeamMP
#    forum, which this fork does not use.
LAN_PRUNE_DROPDOWN_VALUES = {"playerlistLeftclick": {2}}


# Upstream #926 split the single "multiplayer" category into a beammp category family:
# one main category (categoryId "beammp") plus subcategory:true children (beammpeventqueue,
# beammpblobs, ..., beammpadvanced). The LAN items now live in their OWN subcategory at the
# end of that family, and the prunes recurse into nested "group" items (playerlistLeftclick
# moved inside one).
LAN_CATEGORY_ID = "beammplan"


def lan_category():
    return {
        "version": "LAN",  # strip marker: the whole subcategory is LAN-owned
        "label": "LAN fork",
        "icon": "settings",
        "categoryId": LAN_CATEGORY_ID,
        "subcategory": True,
        "persistent": False,
        "spacer": False,
        "divider": False,
        "reroute": "",
        "categoryInfo": "",
        "condition_always_off": False,
        "condition_not_shipping": False,
        "condition_simplemenu": "",
        "condition_visible": "",
        "items": list(LAN_ITEMS),
    }


def prune_tree(items):
    """Remove LAN-pruned settings / dropdown values anywhere in a category's item tree."""
    pruned = 0
    kept = []
    for i in items:
        s = i.get("setting")
        if s in LAN_PRUNE_SETTINGS:
            pruned += 1
            continue
        if s in LAN_PRUNE_DROPDOWN_VALUES and isinstance(i.get("options"), list):
            drop = LAN_PRUNE_DROPDOWN_VALUES[s]
            n = len(i["options"])
            i["options"] = [o for o in i["options"] if o.get("value") not in drop]
            pruned += n - len(i["options"])
        if isinstance(i.get("items"), list):  # recurse into "group" containers
            i["items"], sub = prune_tree(i["items"])
            pruned += sub
        kept.append(i)
    return kept, pruned


def main():
    with open(LAYOUT, encoding="utf-8") as f:
        layout = json.load(f)

    family = [i for i, c in enumerate(layout["items"])
              if str(c.get("categoryId", "")).startswith("beammp")]
    if not family:
        print("ERROR: no beammp category family in layout.json -- re-add upstream's first", file=sys.stderr)
        return 1

    # idempotence: drop any previous LAN-owned subcategory, then LAN items inside upstream categories
    before = len(layout["items"])
    layout["items"] = [c for c in layout["items"] if c.get("version") != "LAN"]
    stripped = before - len(layout["items"])
    pruned = 0
    for c in layout["items"]:
        if str(c.get("categoryId", "")).startswith("beammp") and isinstance(c.get("items"), list):
            n = len(c["items"])
            c["items"] = [i for i in c["items"] if i.get("version") != "LAN"]
            stripped += n - len(c["items"])
            c["items"], sub = prune_tree(c["items"])
            pruned += sub

    last = max(i for i, c in enumerate(layout["items"])
               if str(c.get("categoryId", "")).startswith("beammp"))
    layout["items"].insert(last + 1, lan_category())

    with open(LAYOUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(layout, f, indent=1, ensure_ascii=False)
        f.write("\n")

    fam_n = sum(1 for c in layout["items"] if str(c.get("categoryId", "")).startswith("beammp"))
    print(f"ok: stripped {stripped} previous LAN entries, pruned {pruned} LAN-inappropriate "
          f"upstream entries, inserted the LAN subcategory ({len(LAN_ITEMS)} items); "
          f"beammp category family now {fam_n} categories")
    return 0


if __name__ == "__main__":
    sys.exit(main())
