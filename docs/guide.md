# Dirigible user guide

This guide shows how to record, edit, and export a podcast episode with Dirigible on macOS 14 or later.

## Before you start

- Install Dirigible. The steps are in the [Install section of the README](../README.md#install).
- The first time that you monitor or record, macOS asks for access to the microphone. If you do not allow the access, Dirigible cannot record. The window then shows the button **Open Privacy Settings**, which opens the setting.
- A session is one item in Finder, with the name that you give it. Close the session in Dirigible before you copy or move it. Do not change the files inside it.
- Only one window can open a session at a time.

### What Dirigible does not do yet

- No MP3 export. Export AAC (.m4a) or WAV, and check which formats your podcast host accepts.
- The export does not write the chapters into the file. The chapters stay in the session.
- No recording of calls or other apps, for example Zoom or Teams. Dirigible records only input devices, such as microphones and audio interfaces.
- No loudness setting. The export does not change the level of the audio.
- Delete leaves silence. The clips after the deleted part do not move to close the gap. To close the gap, see [Remove a mistake and close the gap](#remove-a-mistake-and-close-the-gap).

## Record your first episode

In this tutorial, you record an interview with two microphones, remove a mistake, add a chapter, and export an AAC file. You need the built-in microphone of your Mac and one USB microphone.

### Make the session

1. Connect the USB microphone, then open Dirigible.
2. Choose **File > New Session** (Command-N).
3. Type a name for the episode, select a folder, and click **Save**. A window opens. It shows **No Tracks** and an **Add Track** button.

There is no Save command. Dirigible saves each change to the session.

### Set up the tracks

1. Choose **Track > Add Track** (Option-Command-N) two times. The window shows **Track 1** and **Track 2**.
2. Click the name field of **Track 1**, type `Host`, and press Return.
3. Click the name field of **Track 2**, type `Guest`, and press Return.
4. On the **Host** track, click **Choose Input** (**Elegir entrada** in Spanish). Under the name of the built-in microphone, choose **Channel 1**.
5. On the **Guest** track, click **Choose Input**. Under the name of the USB microphone, choose **Channel 1**.
6. Make sure that the **Arm** check box (**Armar** in Spanish) is on for each track.

A track records only when its **Arm** check box is on. Dirigible turns on **Arm** when you choose an input. On a short track, the input menu is a microphone symbol. One channel gives a mono track. A pair of channels, for example **Channels 1 and 2**, gives a stereo track. Two tracks cannot use the same input channel.

### Check the levels

1. Choose **Record > Monitor Inputs** (Shift-Command-M).
2. If macOS asks for access to the microphone, click **Allow**.
3. Speak into each microphone. The meter in the header of its track moves.

**Monitor Inputs** shows the level of each armed track. It does not send the sound to your headphones.

### Record a take

1. Choose **Record > Record** (Command-R). The window shows **Recording take 1** and the time.
2. Record the interview.
3. Choose **Transport > Stop** (Command-Period). The window shows **Finishing take 1**, then **Take 1 is finished.**

A take is one recording, from Record to Stop. After Stop, Dirigible finalizes the take: it writes the audio of each track into clips. A clip is one piece of audio on a track. The playhead is the vertical line that shows the play position. After a take, the playhead is at the end of the take.

### Play the take

1. Choose **Transport > Go to Start** (Home).
2. Press Space to play. The playhead moves.
3. Press Space again to stop. The playhead stays where it stopped.

> [!WARNING]
> Record replaces the audio of the armed tracks from the playhead on. Before you record again, choose **Transport > Go to End** (End, or Fn-Right Arrow on a laptop). Or turn off **Arm** on the tracks that you want to keep.
>
> If Record replaced audio by mistake, choose **Edit > Undo** (Command-Z). The old audio comes back. The new take stays in the session as unplaced audio (see [Put unplaced audio on a track](#put-unplaced-audio-on-a-track)).
>
> Undo works only while the session window is open. When you close the window, you cannot undo.

### Remove a mistake

1. Choose **Edit > Deselect All** (Shift-Command-A).
2. Click the time ruler above the tracks at the start of the mistake. The playhead moves there.
3. Press I to set the in point.
4. Click the time ruler at the end of the mistake, then press O to set the out point.
5. Choose **Edit > Delete** (Delete). The mistake goes, and silence stays in its place.

The in point is the start of the selection, and the out point is the end. With no track selected, I and O select all tracks.

### Add a chapter

1. Click the time ruler where a new topic starts.
2. Choose **Markers > Add Chapter** (Shift-Command-Return). A flag with the name **Chapter 1** shows in the time ruler.
3. To change the name, choose **Markers > Rename Marker**, type the name, and click **OK**.

### Export an AAC file

1. Choose **File > Export** (Command-E).
2. Set **Format** to **AAC (.m4a)**.
3. Set **Sample rate** to **44.1 kHz** or **48 kHz**.
4. Type a file name, select a folder, and click **Save**. The window shows **Exporting**, then the file is in the folder.

## Find your way in a long session

### Play and move the playhead

- To move the playhead, click the time ruler. A click in an empty part of a track also moves the playhead.
- The **Transport** menu has the play commands. **Play Forward** plays faster each time that you choose it again: 1x, 2x, then 4x. If you hold its key, the play pauses when you release the key.
- **Go to Start**, **Go to End**, **Previous Clip Edge**, and **Next Clip Edge** move the playhead.
- When **View > Automatic Scroll** is on, the view follows the playhead during play.

### Zoom

- Choose **View > Zoom In**, **View > Zoom Out**, or **View > Zoom to Session**.
- On a trackpad, pinch to zoom. With a mouse, hold Command and turn the scroll wheel.
- Choose **View > Zoom to Selection or Session** to show the selection. With no selection, it shows the whole session. Choose it again to go back to the view before.
- Choose **View > Zoom Back** and **View > Zoom Forward** to go through the zoom history of the window.
- Double-tap with two fingers on a trackpad for smart zoom. When the whole session is in view, smart zoom zooms in at the pointer. In other views, it shows the whole session.

### Use the Session overview

The **Session overview** is the strip above the time ruler. It shows the whole session and a frame around the part in view.

- Click the Session overview to show that part of the session.
- Drag the frame to scroll.
- Drag an edge of the frame to zoom. Press Esc during the drag to go back to the view before.
- Double-click the Session overview to show the whole session. Double-click again to go back.

### Scroll by page and change the track height

- Choose **View > Previous Page** or **View > Next Page** to scroll by most of the width of the view.
- Choose **View > Taller Tracks** or **View > Shorter Tracks** to change the height of all tracks.
- Choose **View > Fit Tracks to Window** to go back to the automatic track height.

## Select and edit

A selection has an in point, an out point, and one or more tracks. Two triangles in the time ruler show the in point and the out point.

### Make a selection

- Choose **Edit > Set In Point** and **Edit > Set Out Point** to set the points at the playhead. With no track selected, they select all tracks.
- Drag in the lower part of a clip, or in an empty part of a track, to select a range on the tracks that you drag across.
- Click the upper part of a clip to select that clip.
- Shift-click a track to select from the playhead to the click. Shift-drag to make the selection larger.
- Command-click a track to add it to the selection or remove it from the selection.
- Drag a triangle in the time ruler to move the in point or the out point.
- Choose **Edit > Select All** to select the whole session. Choose **Edit > Deselect All**, or press Esc, to clear the selection.

### Change the audio

- **Cut** copies the selection and leaves silence.
- **Copy** copies the selection. You can paste it only in the same window.
- **Paste** puts the copy at the playhead on the selected tracks. With no track selected, it uses the tracks that you copied from. The copy replaces the audio under it.
- **Delete** removes the selection and leaves silence.
- **Split** cuts the clips at the in point and the out point. With no selection, it cuts the clips at the playhead.
- **Nudge Left** and **Nudge Right** move the clips that are fully in the selection by 10 ms.
- Drag the upper part of a clip to move it. You can drag it to another track of the same type, mono or stereo. The clip replaces the audio under it.
- Drag the edge of a clip to make it shorter or longer.
- Press Esc during a drag to cancel it.

Each edit is one step in the undo history. Choose **Edit > Undo** to reverse the last edit.

### Remove a mistake and close the gap

To remove a part and move the audio after it to the left, delete the mistake first. Then cut the audio after the mistake, and paste it at the start of the mistake. Because of the delete, no part of the mistake stays, also when the mistake is longer than the audio after it.

Paste right after the cut. The cut audio and the undo history stay only while the session window is open. When you close the window, you cannot paste the cut audio or undo the cut.

Markers and chapters do not move with the audio. Remove the mistakes before you add markers. If markers are after the mistake, move each one after the paste. Move it to the left by the length of the mistake. Drag its flag, or click the flag, move the playhead to the new position, and choose **Markers > Move Marker to Playhead**.

1. Choose **Edit > Deselect All**.
2. Move the playhead to the start of the mistake. Then choose **Edit > Set In Point**.
3. Move the playhead to the end of the mistake. Then choose **Edit > Set Out Point**. The selection is on all tracks.
4. Choose **Edit > Delete**. The mistake becomes silence on all tracks. If the mistake goes to the end of the session, stop here.
5. Choose **View > Zoom to Selection or Session**. Click the time ruler in the silence. Then choose **Transport > Next Clip Edge**. The playhead goes to the end of the silence.
6. Choose **Edit > Set In Point**.
7. Choose **Transport > Go to End**, then choose **Edit > Set Out Point**. The selection goes from the end of the silence to the end of the session.
8. Choose **Edit > Cut**. The session now ends at the start of the silence.
9. Choose **Transport > Go to End**. The playhead goes to the start of the silence.
10. Choose **Edit > Paste** right after the cut. The audio after the mistake now starts at the playhead, and the gap is closed.
11. Play the result before you close the session. If the result is wrong, choose **Edit > Undo** three times to undo the paste, the cut, and the delete.

If no track has audio just before the mistake, step 9 moves the playhead to the end of the audio before the mistake. The paste then also removes the silence before the mistake.

## Add markers and chapters

A marker is a flag in the time ruler. A chapter is a marker for a new part of the episode.

- Choose **Markers > Add Marker** or **Markers > Add Chapter** to add a flag at the playhead. The number in the name counts the markers and the chapters together, for example **Marker 1**, then **Chapter 2**.
- Control-click the time ruler and choose **Add Marker** or **Add Chapter** to add a flag at that point.
- Control-click a flag and choose **Delete Marker** to delete it.
- Click a flag to move the playhead to it. The flag becomes the current marker.
- Drag a flag to move it.
- **Edit > Cut**, **Edit > Paste**, and **Edit > Delete** do not move the flags. See [Remove a mistake and close the gap](#remove-a-mistake-and-close-the-gap).
- **Rename Marker**, **Move Marker to Playhead**, and **Delete Marker** change the current marker.
- **Previous Marker** and **Next Marker** move the playhead to a flag and make it the current marker.

## Work with tracks

- Choose **Track > Add Track** to add a mono track with no input.
- Type in the name field of a track to change its name. Press Return to keep the name.
- Use the input menu of a track to choose a device and its channels. One channel gives a mono track, and a pair of channels gives a stereo track. **No Input** removes the input.
- To remove tracks, select them and choose **Track > Remove Track**. You can also Control-click the header of a track and choose **Remove Track**.
- To change the width of the track headers, drag their right edge. Double-click the edge to go back to the standard width.

## Export the episode

- **File > Export** exports all tracks, from the start to the end of the session.
- **File > Export Selection** exports the selection only: the time from the in point to the out point, on the selected tracks.

The export panel has these settings. It keeps the last settings that you used.

| Setting | Values |
|---|---|
| **Format** | **WAV**, **AAC (.m4a)**, or **FLAC** |
| **Bit depth** (WAV and FLAC) | 16 or 24 |
| **Bit rate** (AAC) | 64, 96, 128, 160, 192, or 256 kbit/s |
| **Channels** | **Stereo** or **Mono** |
| **Sample rate** | The session rate, **44.1 kHz**, or **48 kHz** |

If an audio file of the session is missing or cannot be read, Dirigible shows its name before the export. Its clips export as silence. Click **Export** to go on, or click **Cancel**.

## Recover after a crash, an unplug, or a full disk

Dirigible writes each take to disk while it records. After a crash, an unplug, or a full disk, the recorded audio stays in the session.

### After a crash

Open the session again. The window shows **Recovering the last take**, then **Take 1 was recovered.** (with the number of the take). The take is on its tracks.

### After an unplug

If a device goes away during a take, its tracks show **Device lost**. The other tracks continue to record. Connect the device again to the same port. Its tracks then record again. After Stop, the window names each track that has a gap. If a track still shows **Device lost**, choose **Transport > Stop**, then choose **Record > Record**. After Stop, the playhead is at the end of the take, and the new take starts there. If Record shows that the input device of the track is not connected, choose the device again in the input menu of the track. **Write error** on a track means that Dirigible could not write its audio to the disk.

### When the disk is almost full

- The window shows a banner when less than 60 minutes of record time is left on the disk. During a take, the banner shows at less than 10 minutes.
- Record does not start when less than 1 GB is free on the disk of the session.
- If the disk becomes almost full during a take, Dirigible stops the take and keeps the audio.

### When a take is not finished

If Dirigible cannot finalize a take, the window shows **Take 1 is not finished.** (with the number of the take). You cannot record until the take is finished.

1. Remove the cause. For example, free disk space or connect the disk again.
2. Click **Retry Finalize**.

If the disk cannot read a part of the audio, the window also shows **Finish Without Unreadable Audio**. Click it to finish the take without that part. The file stays in the session, and you can place it later.

### Put unplaced audio on a track

Unplaced audio is recorded audio that is on no track. The window lists it under **Audio that is on no track:**.

- Click **Place** to put the audio on its track, at the time when it was recorded.
- To put the audio at the playhead, select one track. Then click the arrow next to **Place** and choose **Place at Playhead on Selected Track**.

If Redo is available, **Place** is off, and the window shows **Redo brings this audio back.**

### Find the audio files

Choose **File > Show Clips in Finder** to show the audio files of the clips in Finder. With a selection, Finder shows only the files of the selected clips.

If an audio file is missing or damaged, its clips play as silence, and the window names the file. Connect the disk that has the file. Dirigible checks again when you come back to the window.

## Menu commands and keys

Each table lists the commands of one menu, in the order of the menu. The Spanish name is the name in the app when macOS is in Spanish.

On a laptop keyboard, press Fn with an arrow key for these keys: Page Up is Fn-Up Arrow, Page Down is Fn-Down Arrow, Home is Fn-Left Arrow, and End is Fn-Right Arrow.

### File

| Command | Spanish name | Key |
|---|---|---|
| **New Session** | **Nueva sesión** | Command-N |
| **Open** | **Abrir** | Command-O |
| **Open Recent** | **Abrir recientes** | None |
| **Show Clips in Finder** | **Mostrar clips en el Finder** | Shift-Command-R |
| **Export** | **Exportar** | Command-E |
| **Export Selection** | **Exportar selección** | Shift-Command-E |

### Edit

macOS adds **Undo** (Command-Z) and **Redo** (Shift-Command-Z) at the top of the Edit menu.

| Command | Spanish name | Key |
|---|---|---|
| **Cut** | **Cortar** | Command-X |
| **Copy** | **Copiar** | Command-C |
| **Paste** | **Pegar** | Command-V |
| **Delete** | **Eliminar** | Delete |
| **Select All** | **Seleccionar todo** | Command-A |
| **Set In Point** | **Marcar entrada** | I |
| **Set Out Point** | **Marcar salida** | O |
| **Deselect All** | **Anular selección** | Shift-Command-A |
| **Split** | **Dividir** | Command-B |
| **Nudge Left** | **Desplazar a la izquierda** | Command-Left Arrow |
| **Nudge Right** | **Desplazar a la derecha** | Command-Right Arrow |

### View

| Command | Spanish name | Key |
|---|---|---|
| **Zoom In** | **Acercar** | Command-+ (or Command-=) |
| **Zoom Out** | **Alejar** | Command-Minus |
| **Zoom to Session** | **Ajustar a la sesión** | Command-0 |
| **Zoom to Selection or Session** | **Ajustar a la selección o a la sesión** | H |
| **Zoom Back** | **Vista anterior** | Option-Command-Left Arrow |
| **Zoom Forward** | **Vista siguiente** | Option-Command-Right Arrow |
| **Previous Page** | **Página anterior** | Option-Page Up |
| **Next Page** | **Página siguiente** | Option-Page Down |
| **Taller Tracks** | **Pistas más altas** | Command-Down Arrow |
| **Shorter Tracks** | **Pistas más bajas** | Command-Up Arrow |
| **Fit Tracks to Window** | **Ajustar pistas a la ventana** | None |
| **Automatic Scroll** | **Desplazamiento automático** | Option-Command-F |

### Markers

The **Markers** menu (**Marcadores**).

| Command | Spanish name | Key |
|---|---|---|
| **Add Marker** | **Añadir marcador** | Command-Return |
| **Add Chapter** | **Añadir capítulo** | Shift-Command-Return |
| **Rename Marker** | **Renombrar marcador** | Shift-Return |
| **Move Marker to Playhead** | **Mover marcador al cursor** | Option-Command-Return |
| **Delete Marker** | **Eliminar marcador** | Command-Delete |
| **Previous Marker** | **Marcador anterior** | Page Up |
| **Next Marker** | **Marcador siguiente** | Page Down |

### Track

The **Track** menu (**Pista**).

| Command | Spanish name | Key |
|---|---|---|
| **Add Track** | **Añadir pista** | Option-Command-N |
| **Remove Track** | **Eliminar pista** | Option-Command-Delete |

### Record

The **Record** menu (**Grabación**).

| Command | Spanish name | Key |
|---|---|---|
| **Record** | **Grabar** | Command-R |
| **Retry Finalize** | **Reintentar la finalización** | Option-Command-R |
| **Monitor Inputs** | **Monitorizar entradas** | Shift-Command-M |

### Transport

The **Transport** menu (**Transporte**).

| Command | Spanish name | Key |
|---|---|---|
| **Play or Stop** | **Reproducir o detener** | Space |
| **Stop and Return** | **Detener y volver** | Shift-Space |
| **Stop** | **Detener** | Command-Period |
| **Play Backward** | **Reproducir hacia atrás** | J |
| **Pause** | **Pausa** | K |
| **Play Forward** | **Reproducir hacia delante** | L |
| **Play Backward Slowly** | **Reproducir hacia atrás despacio** | Shift-J |
| **Play Forward Slowly** | **Reproducir hacia delante despacio** | Shift-L |
| **Go to Start** | **Ir al inicio** | Home |
| **Go to End** | **Ir al final** | End |
| **Previous Clip Edge** | **Borde de clip anterior** | Shift-Left Arrow |
| **Next Clip Edge** | **Borde de clip siguiente** | Shift-Right Arrow |

### Commands in the banners

These commands are buttons in the banners of the window, not items of the menu bar. **Retry Finalize** and **Finish Without Unreadable Audio** show in the banner of a take that is not finished. **Place** shows in each row of unplaced audio, and **Place at Playhead on Selected Track** is in its menu.

| Command | Spanish name | Key |
|---|---|---|
| **Retry Finalize** | **Reintentar la finalización** | None |
| **Finish Without Unreadable Audio** | **Terminar sin el audio ilegible** | None |
| **Place** | **Colocar** | None |
| **Place at Playhead on Selected Track** | **Colocar en el cursor en la pista seleccionada** | None |

## For contributors

This section is for people who build Dirigible from source or write scripts.

### The session files

A session is a macOS package: a folder with the extension `.dirigible` that Finder shows as one item.

- `session.xml` holds the tracks, the clips, the markers, and the chapters.
- `Clips/` holds the audio of the clips as WAV files.
- `Capture/` holds the audio of a take while it records, in files that survive a crash.

### The dirigible tool

`dirigible` is a command-line tool that makes, changes, and reads session packages. The DMG does not contain it. Build and run it from a clone of the repository:

```sh
swift run dirigible --help
swift run dirigible create Demo.dirigible --sample-rate 48000
swift run dirigible info Demo.dirigible
```

The text of the tool is English only.

### Keep this guide true

Each run that changes what a user sees or does updates this guide. `make check-docs` fails when a `menu.*` name of `Support/Resources/en.lproj/Localizable.strings` or `es.lproj/Localizable.strings` is not in bold in this guide. It also fails when a relative link of this guide or of `README.md` names no file, or no heading of the .md file that it names.
