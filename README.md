=========================================
   Garden Buddy — Turtle WoW Addon
   A FishingBuddy-style Planter Tracker
   Version 1.1
=========================================

INSTALLATION
------------
1. Unzip the GardenBuddy folder into your AddOns directory:
   World of Warcraft\Interface\AddOns\GardenBuddy\

2. Log in and the addon will load automatically.
   You will see: [GardenBuddy] v1.1 loaded.

3. The window appears in the top-left area of your screen (draggable).


WHAT IT DOES
------------
Garden Buddy opens a compact tracker window (similar to FishingBuddy) that
lets you monitor all your garden planters at once.

For each tracked planter it shows:
  • The planter name you gave it
  • The current growth phase  (Seedling / Sprouting / Growing / Maturing / Harvest Ready)
  • Time remaining in the current phase  (MM:SS countdown)
  • How many phases are still left  (e.g. "3 / 4")

When a planter advances to a new phase, a configurable chime / sound plays
and a message is printed to your chat frame.


PHASE DURATION SETTING
----------------------
The phase timer is based on the Turtle WoW server's gardening phase length.
By default it is set to 30 minutes per phase.

If your planters use a different timing, click the "Phase Duration" button at
the bottom of the window to cycle through:  10 / 15 / 20 / 30 / 40 / 60 min
Or use:  /gb duration 25   (for 25 minutes, for example)


SOUND OPTIONS
-------------
Click the "Snd: ..." button to cycle through notification sounds:
  • Chime       (Quest Complete sound)
  • Level Up
  • Raid Ping
  • Loot Click
  • Coin Drop
  • None / Off

A preview plays when you cycle to each option.


SLASH COMMANDS
--------------
/gb                      — Shows help
/gb add [name]           — Add a planter (opens dialog if no name given)
/gb remove <number>      — Remove planter #N from the list
/gb clear                — Remove all planters
/gb list                 — Print all planters and status to chat
/gb show / /gb hide      — Show or hide the window
/gb toggle               — Toggle window visibility
/gb sound                — Cycle sound options
/gb duration [minutes]   — Set phase duration (e.g. /gb duration 20)
/gb reset                — Reset settings to default (keeps planters)
/gb resetall             — Full reset (clears all planters and settings)

Aliases:  /gardenbuddy  /garden


AUTO DETECTION
--------------
Garden Buddy attempts to auto-detect when you place a planter by watching
for related messages in the system chat. If it detects one, it automatically
adds a new planter entry. You can rename or remove it as needed.

If auto-detection doesn't trigger, simply use:  /gb add My Herb Planter


WINDOW CONTROLS
---------------
  [−] button  → Minimize/restore the window to just the title bar
  [X] button  → Close the window  (reopen with /gb show)
  Drag title  → Move the window anywhere on screen
  [+ Add Planter] → Opens the Add Planter dialog
  [Snd: ...]      → Cycles the notification sound
  [Phase Duration: X min] → Cycles phase timer length


COLORS
------
  Green text   → Phase timer is healthy / planter is ready to harvest
  Orange text  → Warning — less than 5 minutes left in current phase
  White text   → Normal timer display


NOTES
-----
• Timer data is saved between sessions (GardenBuddyDB saved variable).
• If you log out and log back in, planted timers resume from where they
  were — as long as you haven't reloaded so much time that the plant would
  have advanced phases while offline (the addon calculates based on real
  clock time vs. when you planted).
• Up to 20 planters can be tracked simultaneously.
• Scroll arrows appear when you have more than 8 active planters.


SUPPORT / FEEDBACK
------------------
If phase durations for Turtle WoW's gardening system differ from the
defaults in this addon, use /gb duration <minutes> to correct them.
=========================================
