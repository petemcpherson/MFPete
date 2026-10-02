# App Notes


## gist
Okay, I want to create a very small macOS utility app based around "MFT" or managed file transfer.

What I currently use (plus an example): Hazel (research at https://www.noodlesoft.com/).

Here's a random Reddit user that gives examples of how he uses Hazel (just for reference): 

***
I can't imagine using a computer without it. I use it for so many things. These are my favorite Hazel Actions

Unzip any compressed files in my Downloads folder and trash the zip file - This helps keep my downloads folder cleared of the detritus that occurs because I am a compulsive software addict.

Install apps inside DMGs in my downloads folder via RapiDMG and then trash the DMG - When I download a disk image file with an app in it, I don't have to do anything else to get the app moved to my Applications folder. It happens in seconds with no intervention from me unless I have to approve replacing an existing file.

Import any image file I place in an Images folder into the Photos app (in the background) - I'm constantly copying photos from Facebook and various web sites. I have them to a folder I have designated in Hazel and they automatically get imported into my photos library with me even opening the app.

Change any text file in my Dropbox to a markdown file and move it to my Obsidian vault (useful in sending emails to Obsidian) - I use an IFTTT applet that allows me to forward emails to a specific address. Those emails are save in a specific folder in my Dropbox account that Hazel watches. When a file appears there, Hazel changes the file extension from txt to md and moves the resulting file into my Obsidian vault.

Sort all files in my documents folder into subfolders based on file extension. - I currently have 42 sub-folders in my documents folder of different file types ranging from the usual suspects like txt and docx to the more esoteric like saved HoudahSpot searched and Etrecheck Reports.

Purge old screenshots - between my day job and my blogging past time, I generate a lot of screenshots. Hazel moves any screenshots more than three days old into an archive folder to help give a semblance of order.

Color code any application I haven't opened in three months - I have 416 apps installed on my mac because, well, I just can't help myself. Hazel will color an unused app red after not launching it for 90 days to help me decide whether to keep it or remove it with AppCleaner.

Keep my desktop clean - I do not like to use my desktop as part of my file system. I rarely even see it since I run apps maximized most of the time. This rule moves any file that ends up on my desktop into a folder in my home directory. I exclude aliases from the rule because there are times when I want to make an app shortcut on the desktop, usually temporarily.

***

I only have 1-2 "rules" set up, which cleans my downloads folder, automatically trashes a few items, etc. 

What I want....

* DEAD simple UI
* "rules" are what the user creates
* time-based rules
* action based rules (on file add, on file delete, on file change/update maybe?!)

This should feel easy and clean, starting with the smaller features.

I'd also like the "vibe" to feel a bit like "if this then that" UIs. Perhaps each rule has a trigger, conditions, and actions. i.e. what starts it...maybe some if/then logic, and/or logic, etc, then action (what happens?), etc.

Rules can be run on a time action (every hour, every day at a specific time, etc?). And perhaps events? file added? file updated?

This app's dock icon should be off by default, but will have a menu bar icon.

The main dashboard should just be a list of rules, maybe with some sorting and/or filters, as well as a "enable/disable" toggle.


## tech

* MacOS app
* local-only btw. No cloud anything, everything happens on device (for now. WE MIGHT allow opportunities to transfer files to cloud storage, Google Drive, Dropbox, iCloud (though I think this could qualify as local when working on MacOS? I don't know))

## pricing

* free, 100% open-source (MIT)
* hopefully installable via Homebrew