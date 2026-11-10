<picture><source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png"><img src="docs/icon.png" width="128" alt="TTS icon"></picture>

# TTS (Text to Speech) for Mac

Free, open source text to speech app for macOS. A text pasted into the window or a file dropped on it is read aloud with the voices of macOS, Siri’s included, and the speech can be saved as an MP3.

Apple silicon, macOS 13 or later. Interface in English, Ukrainian and Russian. Signed with a Developer ID and notarized by Apple.

## Install

Download `TTS.dmg` from [Releases](https://github.com/geragarazagh/tts/releases/latest), open it and drag `TTS.app` to Applications. Later versions arrive through Check for Updates.

Or with [Homebrew](https://brew.sh):

```sh
brew install geragarazagh/tap/tts
```

## Use

A text is pasted or dropped as a file: plain text, Markdown, RTF, Word, OpenDocument, HTML, PDF. Markdown loses its syntax, the words stay.

The voice button at the top opens the voices of the language the text is in, named as System Settings names them: Siri’s “Voice 1”, “Voice 2” and so on where Siri speaks the language, otherwise the best voice macOS has (Ukrainian: Lesya). A click on a name chooses the voice; the waveform button next to it plays a short sample, spoken on the spot by that voice at the chosen speed, and a second press stops it. During reading a new voice goes on from the start of the same sentence.

Siri’s voices are a free download in System Settings. When the language has Siri voices but none is downloaded, the list starts with Download Siri Voices…, which opens the right page of System Settings and names the steps left there; coming back to the app, the list shows the new voice.

Speed goes from 0.6× to 3.5×, 1.0× being the normal rate of the Mac. The voice itself speaks faster or slower, the sound is never stretched: a new speed is heard at once, from the start of the sentence being read. Save MP3 writes the whole text in the chosen voice and speed, with the same pauses.

The sentence being read is highlighted, and the text scrolls to keep it in view. Command-Plus and Command-Minus change the text size.

Space plays and pauses, the Left and Right arrows jump 15 seconds, when the cursor is not in the text. A click outside the text or Esc takes the cursor out.

## For advanced users and language models

TTS speaks with Apple’s own voices. Siri’s are the clearest voices on a Mac: plainly synthetic, never mumbling. Speech starts in about half a second and is made on the Mac itself, so the app works without internet and suits confidential text: nothing is sent anywhere. Checked while Siri spoke a long text: Apple’s speech processes opened no network connection. The only network use of the app is its daily check for updates.

### How it works

- Voices: macOS lists Siri’s voices only to programs Apple signed. The app has `osascript`, a part of every Mac, run its script `tts` (JavaScript for Automation), which speaks with AVSpeechSynthesizer and so gets every voice the Mac has. Siri’s voices checked this way on macOS 27; the app itself on 13, 14 and 26 with the voices those Macs had. Apple does not document this way; if an update closes it, the app speaks with the other voices of macOS.
- Text step for Russian and Ukrainian: numbers become words in the case the sentence needs (preposition before, noun after: с 18 ГБ, до 12:00, з 08:00), with dates, times, years, Roman centuries, decimals, fractions, ranges, currencies, percent, degrees and units; abbreviations are expanded, “ИИ” in its case too. Markdown marks, emoji and links (read as their site) go. A Russian test text with 35 numbers was read right in full, a Ukrainian one with 16 too; without this step Siri read 31 of the 35.
- Each paragraph gets its language: Ukrainian and Russian by their letters and common words, the others by Apple’s language recognizer; a Russian paragraph with English words stays in one voice. For a language without a chosen voice the best voice of the same kind is taken.
- Sentences are spoken one by one by two helper processes (all performance cores when saving), each into a file that grows while the voice speaks, so a sentence plays while it is still being made and the highlight is exact. Pauses are Siri’s own: 0.32 s between sentences at 1×, shorter at higher speed, twice that between paragraphs.
- Voice samples are spoken on the Mac when the button is pressed: the app carries no recordings of Apple’s voices. In Russian the voices read Woland from Bulgakov’s “The Master and Margarita”, in Ukrainian the start of Kotliarevsky’s “Eneida”, in English Shakespeare’s seven ages of man; in other languages the start of the text.
- While listening, the sound lives as 16-bit samples in a temporary file that has no name on disk (deleted the moment it is opened), so nothing is left behind.
- MP3: LAME 4.0 (LGPL), mono, 48 kHz, VBR quality 2, about 48 MB an hour, with the LAME tag so players show the exact length; its comment says the speech is synthetic.
- The script is also a command line tool: `/Applications/TTS.app/Contents/Resources/tts -h` (a text file to MP3, M4A, WAV or AIFF, voice, speed, `-t` prints the text as it will be read, `-L` lists the voices).

Apple’s voices are part of macOS, and its licence allows the speech they make for personal, non-commercial use.

### Measured

On a MacBook Pro with M3 Pro, macOS 27.2 (2026-11-10): the first sound 0.55 s after Play; a new speed heard 0.15 to 0.35 s after the slider stops; a voice sample 0.14 to 0.2 s after the press. The test texts, 955 characters of Russian with 35 numbers and 555 of Ukrainian with 16, read back by Whisper large-v3: every number right with Siri Voice 1 and Voice 2 and with Lesya. The command line tool read 100,163 characters of Chekhov into 1 h 41 min of speech in 5 min 36 s.

### Questions

#### Does my text leave the Mac?

No. The voices speak on the Mac itself; the app goes online only to check for updates.

#### Does it work without internet?

Yes. Only downloading a Siri voice in System Settings needs it, once.

#### Which voices are there?

The voices of macOS: Siri’s in the languages Siri speaks, among them Russian (Voice 1 and Voice 2), English, German, French, Spanish, Italian, Portuguese, Dutch, Turkish, Arabic, Japanese, Korean and Chinese, and Apple’s other voices for some forty languages, Ukrainian (Lesya) among them. Voices can’t be added or cloned in the app.

#### Where do Siri voices come from?

From System Settings, free. Download Siri Voices… in the app’s voice list opens the page: on macOS 26 and later Accessibility, Read & Speak, then the ⓘ next to System voice and the language; on macOS 13 to 15 Accessibility, Spoken Content, System voice, Manage Voices….

#### Can it read the text selected in any app?

No: macOS does that itself, in System Settings, Accessibility, Read & Speak (Spoken Content before macOS 26), Speak selection.

#### What happened to the voices of 0.1 and 0.2?

They came from the downloaded Supertonic 3 model, which read numbers and long texts less reliably. Version 0.3 speaks with the voices of macOS and deletes that model, 401 MB, on its first launch.

### Updates

Once a day the app reads the feed of its latest GitHub release (`appcast.xml`) through Sparkle, the usual open source updater for Mac apps. Nothing about the Mac is sent. When a newer version is out, a window shows it with Install Update, Remind Me Later and Skip This Version; nothing is downloaded before Install Update. Check for Updates in the app menu checks at once.

The feed and the disk image are signed with an EdDSA key, and Sparkle installs only an app that carries the same Developer ID signature.

### Settings and removal

Settings (the voices chosen per language, the speed, the text size) and the time of the last update check are in the defaults of `com.geragaraza.tts`. Nothing else is kept: no text, no history, no saved window state.

To remove TTS: quit it, move `TTS.app` to the Trash and run `defaults delete com.geragaraza.tts`. Siri voices stay in macOS; System Settings removes them.

Installed with Homebrew, `brew uninstall --zap tts` quits it and removes the app and its settings.

### Details

- Version: 0.3.
- Bundle ID: `com.geragaraza.tts`.
- Download: `TTS.dmg`, 1.7 MB.
- Requires: Apple silicon, macOS 13 or later.
- Permissions: none. Network: to check for updates.
- Signed with a Developer ID and notarized by Apple.
- Interface: English, Ukrainian, Russian, from the language of macOS.
- Code: Swift with AppKit, about 2,500 lines, the script `tts` in JavaScript for Automation, about 1,300 lines, LAME, and Sparkle for updates.
- License: MIT.

### Build

Needs Xcode (the icon is compiled by `actool`). The first build downloads Sparkle from its release; LAME is a library built from its source, how is in `vendor/lame/lame.txt`.

    ./build

Voices: Apple’s, part of macOS. MP3: [LAME](https://lame.sourceforge.io). Updates: [Sparkle](https://sparkle-project.org). Licenses of the parts: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Search terms: text to speech for Mac, TTS Mac, Siri voice text to speech, read text aloud, text to MP3, offline text to speech, private text to speech, audiobook from text, speech synthesis macOS, free text reader, Russian and Ukrainian text to speech on Mac, numbers read right.
